const std = @import("std");

pub const Status = enum { unknown, charging, discharging, not_charging, full };

pub const Battery = struct {
    name_buf: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    capacity: u8 = 0,
    status: Status = .unknown,
    /// Wh / Ws raw values from sysfs (energy_*); 0 if unavailable.
    energy_now: u64 = 0,
    energy_full: u64 = 0,
    /// Charge / discharge power in microwatts; 0 if unavailable.
    power_now: u64 = 0,

    pub fn nameSlice(self: *const Battery) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn isCharging(self: Battery) bool {
        return self.status == .charging;
    }

    pub fn isPluggedNotCharging(self: Battery) bool {
        return self.status == .full or self.status == .not_charging;
    }

    /// Seconds until full when charging, or null. Returns null if power_now is 0.
    pub fn secondsToFull(self: Battery) ?u32 {
        if (self.status != .charging) return null;
        if (self.power_now == 0 or self.energy_full <= self.energy_now) return null;
        const remaining: u64 = self.energy_full - self.energy_now;
        return @intCast((remaining * 3600) / self.power_now);
    }

    /// Seconds until empty when discharging, or null. Returns null if power_now is 0.
    pub fn secondsToEmpty(self: Battery) ?u32 {
        if (self.status != .discharging) return null;
        if (self.power_now == 0 or self.energy_now == 0) return null;
        return @intCast((self.energy_now * 3600) / self.power_now);
    }
};

pub const MAX_BATTERIES = 4;

pub const State = struct {
    batteries: [MAX_BATTERIES]Battery = [_]Battery{.{}} ** MAX_BATTERIES,
    count: u8 = 0,
    /// True when at least one battery is present.
    present: bool = false,
    /// Weighted aggregate capacity across all batteries (by energy_full when
    /// available, otherwise simple mean of capacity).
    capacity: u8 = 0,
    /// True if any battery is currently charging.
    charging: bool = false,

    pub fn slice(self: *const State) []const Battery {
        return self.batteries[0..self.count];
    }
};

pub fn poll() State {
    const io = std.Options.debug_io;
    var state: State = .{};

    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/power_supply", .{ .iterate = true }) catch return state;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (state.count >= MAX_BATTERIES) break;
        if (!std.mem.startsWith(u8, entry.name, "BAT")) continue;

        var bat: Battery = .{};
        const copy_len = @min(entry.name.len, bat.name_buf.len);
        @memcpy(bat.name_buf[0..copy_len], entry.name[0..copy_len]);
        bat.name_len = @intCast(copy_len);

        var path_buf: [128]u8 = undefined;

        const present_path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/present", .{entry.name}) catch continue;
        const present_text = readField(present_path) orelse "0";
        if (std.mem.startsWith(u8, present_text, "0")) continue;

        const capacity_path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/capacity", .{entry.name}) catch continue;
        const capacity_val = readU64(capacity_path) orelse 0;
        bat.capacity = @intCast(std.math.clamp(capacity_val, 0, 100));

        const status_path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/status", .{entry.name}) catch continue;
        const status_text = readField(status_path) orelse "Unknown";
        bat.status = parseStatus(status_text);

        const energy_now_path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/energy_now", .{entry.name}) catch continue;
        bat.energy_now = readU64(energy_now_path) orelse 0;

        const energy_full_path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/energy_full", .{entry.name}) catch continue;
        bat.energy_full = readU64(energy_full_path) orelse 0;

        const power_now_path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/power_now", .{entry.name}) catch continue;
        bat.power_now = readU64(power_now_path) orelse 0;

        state.batteries[state.count] = bat;
        state.count += 1;
    }

    if (state.count == 0) return state;
    state.present = true;

    // Aggregate: prefer energy-weighted capacity when energy_full is known.
    var total_now: u128 = 0;
    var total_full: u128 = 0;
    var capacity_sum: u32 = 0;
    var any_charging = false;
    for (state.batteries[0..state.count]) |b| {
        total_now += b.energy_now;
        total_full += b.energy_full;
        capacity_sum += b.capacity;
        if (b.status == .charging) any_charging = true;
    }
    state.charging = any_charging;
    if (total_full > 0) {
        state.capacity = @intCast(std.math.clamp(@divFloor(total_now * 100, total_full), 0, 100));
    } else {
        state.capacity = @intCast(capacity_sum / state.count);
    }
    return state;
}

fn parseStatus(text: []const u8) Status {
    if (std.mem.startsWith(u8, text, "Charging")) return .charging;
    if (std.mem.startsWith(u8, text, "Discharging")) return .discharging;
    if (std.mem.startsWith(u8, text, "Not charging")) return .not_charging;
    if (std.mem.startsWith(u8, text, "Full")) return .full;
    return .unknown;
}

fn readU64(path: []const u8) ?u64 {
    const text = readField(path) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

var file_buf: [256]u8 = undefined;

fn readField(path: []const u8) ?[]const u8 {
    const io = std.Options.debug_io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(256)) catch return null;
    defer std.heap.page_allocator.free(text);
    if (text.len == 0) return null;
    const len = @min(text.len, file_buf.len);
    @memcpy(file_buf[0..len], text[0..len]);
    return std.mem.trim(u8, file_buf[0..len], " \t\r\n");
}
