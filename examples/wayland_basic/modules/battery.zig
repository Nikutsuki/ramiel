const std = @import("std");

pub const State = struct {
    capacity: u8 = 0,
    charging: bool = false,
    present: bool = false,
};

pub fn poll() State {
    const capacity = readInt("/sys/class/power_supply/BAT0/capacity") orelse
        return .{};
    const status = readFile("/sys/class/power_supply/BAT0/status") orelse "Unknown";
    return .{
        .capacity = @intCast(std.math.clamp(capacity, 0, 100)),
        .charging = std.mem.startsWith(u8, status, "Charging") or std.mem.startsWith(u8, status, "Full"),
        .present = true,
    };
}


fn readInt(path: []const u8) ?i64 {
    const text = readFile(path) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

var file_buf: [256]u8 = undefined;

fn readFile(path: []const u8) ?[]const u8 {
    const io = std.Options.debug_io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(256)) catch return null;
    if (text.len == 0) {
        std.heap.page_allocator.free(text);
        return null;
    }
    // Copy to static buffer and free
    const len = @min(text.len, file_buf.len);
    @memcpy(file_buf[0..len], text[0..len]);
    std.heap.page_allocator.free(text);
    return file_buf[0..len];
}
