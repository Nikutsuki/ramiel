const std = @import("std");

pub const Kind = enum { none, wifi, ethernet, other };

pub const State = struct {
    available: bool = false,
    connected: bool = false,
    kind: Kind = .none,

    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    ssid_buf: [64]u8 = [_]u8{0} ** 64,
    ssid_len: u8 = 0,
    ip_buf: [48]u8 = [_]u8{0} ** 48,
    ip_len: u8 = 0,
    device_buf: [32]u8 = [_]u8{0} ** 32,
    device_len: u8 = 0,
    signal: u8 = 0,

    pub fn name(self: *const State) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn ssid(self: *const State) []const u8 {
        return self.ssid_buf[0..self.ssid_len];
    }
    pub fn ip(self: *const State) []const u8 {
        return self.ip_buf[0..self.ip_len];
    }
    pub fn device(self: *const State) []const u8 {
        return self.device_buf[0..self.device_len];
    }
};

fn setField(buf: []u8, len: *u8, value: []const u8) void {
    // Copy while stripping ANSI escape sequences (ESC [ ... final-byte) and
    // stray control chars, so colorized command output never reaches the panel.
    var w: usize = 0;
    var i: usize = 0;
    while (i < value.len and w < buf.len) {
        const ch = value[i];
        if (ch == 0x1b) {
            i += 1;
            if (i < value.len and value[i] == '[') {
                i += 1;
                while (i < value.len and !(value[i] >= 0x40 and value[i] <= 0x7e)) : (i += 1) {}
                if (i < value.len) i += 1; // skip the final byte
            }
            continue;
        }
        if (ch < 0x20) {
            i += 1;
            continue;
        }
        buf[w] = ch;
        w += 1;
        i += 1;
    }
    len.* = @intCast(w);
}

pub fn poll(io: std.Io) State {
    var state: State = .{};

    // Active connection: NAME:TYPE:DEVICE:STATE — pick the first wifi/ethernet.
    var conn_buf: [4096]u8 = undefined;
    const conn_out = runCapture(io, &.{ "nmcli", "-t", "-c", "no", "-f", "NAME,TYPE,DEVICE,STATE", "connection", "show", "--active" }, &conn_buf) orelse return state;
    state.available = true;

    var lines = std.mem.splitScalar(u8, conn_out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = TerseFields.init(line);
        const conn_name = fields.next() orelse continue;
        const type_str = fields.next() orelse continue;
        const dev = fields.next() orelse continue;

        const kind: Kind = if (std.mem.indexOf(u8, type_str, "wireless") != null)
            .wifi
        else if (std.mem.indexOf(u8, type_str, "ethernet") != null)
            .ethernet
        else
            .other;

        // Skip loopback / virtual interfaces for the primary summary.
        if (kind == .other) continue;

        state.connected = true;
        state.kind = kind;
        setField(&state.name_buf, &state.name_len, conn_name);
        setField(&state.device_buf, &state.device_len, dev);
        break;
    }

    if (!state.connected) return state;

    // IP4 address for the chosen device.
    var ip_buf: [2048]u8 = undefined;
    if (runCapture(io, &.{ "nmcli", "-t", "-c", "no", "-f", "IP4.ADDRESS", "device", "show", state.device() }, &ip_buf)) |ip_out| {
        var ip_lines = std.mem.splitScalar(u8, ip_out, '\n');
        while (ip_lines.next()) |line| {
            // Format: IP4.ADDRESS[1]:192.168.1.5/24
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const value = line[colon + 1 ..];
            if (value.len == 0) continue;
            const slash = std.mem.indexOfScalar(u8, value, '/');
            const addr = if (slash) |s| value[0..s] else value;
            setField(&state.ip_buf, &state.ip_len, addr);
            break;
        }
    }

    // Wi-Fi SSID + signal: IN-USE:SSID:SIGNAL, in-use line marked with '*'.
    if (state.kind == .wifi) {
        var wifi_buf: [8192]u8 = undefined;
        if (runCapture(io, &.{ "nmcli", "-t", "-c", "no", "-f", "IN-USE,SSID,SIGNAL", "device", "wifi", "list" }, &wifi_buf)) |wifi_out| {
            var wifi_lines = std.mem.splitScalar(u8, wifi_out, '\n');
            while (wifi_lines.next()) |line| {
                if (line.len == 0 or line[0] != '*') continue;
                var fields = TerseFields.init(line);
                _ = fields.next(); // IN-USE
                const ssid = fields.next() orelse continue;
                const signal_str = fields.next() orelse "0";
                setField(&state.ssid_buf, &state.ssid_len, ssid);
                state.signal = @intCast(std.math.clamp(std.fmt.parseInt(u32, signal_str, 10) catch 0, 0, 100));
                break;
            }
        }
    }

    return state;
}

/// Iterator over nmcli terse fields separated by ':' with '\:' escaping.
/// Returns slices into the source line (stable for the lifetime of the line),
/// so multiple fields can be held at once.
const TerseFields = struct {
    rest: []const u8,

    fn init(line: []const u8) TerseFields {
        return .{ .rest = line };
    }

    fn next(self: *TerseFields) ?[]const u8 {
        if (self.rest.len == 0) return null;
        var i: usize = 0;
        while (i < self.rest.len) : (i += 1) {
            if (self.rest[i] == '\\' and i + 1 < self.rest.len) {
                i += 1;
                continue;
            }
            if (self.rest[i] == ':') {
                const field = self.rest[0..i];
                self.rest = self.rest[i + 1 ..];
                return field;
            }
        }
        const field = self.rest;
        self.rest = self.rest[self.rest.len..];
        return field;
    }
};

fn runCapture(io: std.Io, argv: []const []const u8, buf: []u8) ?[]const u8 {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var mutable_child = child;

    var read_buf: [1024]u8 = undefined;
    var reader = mutable_child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(std.heap.page_allocator, .limited(buf.len)) catch {
        _ = mutable_child.wait(io) catch {};
        return null;
    };
    defer std.heap.page_allocator.free(out);
    _ = mutable_child.wait(io) catch {};

    if (out.len == 0) return null;
    const n = @min(out.len, buf.len);
    @memcpy(buf[0..n], out[0..n]);
    return buf[0..n];
}
