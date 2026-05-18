const std = @import("std");

pub const State = struct {
    volume_pct: u8 = 0,
    muted: bool = false,
    available: bool = false,
};

pub fn poll(io: std.Io) State {
    const child = std.process.spawn(io, .{
        .argv = &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return .{};
    var mutable_child = child;

    var buf: [256]u8 = undefined;
    var reader = mutable_child.stdout.?.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch null;

    _ = mutable_child.wait(io) catch {};

    if (line) |l| {
        return parse(l);
    }
    return .{};
}

fn parse(line: []const u8) State {
    // "Volume: 0.50" or "Volume: 0.50 [MUTED]"
    const prefix = "Volume: ";
    if (!std.mem.startsWith(u8, line, prefix)) return .{};
    const rest = line[prefix.len..];

    const space = std.mem.indexOfScalar(u8, rest, ' ');
    const vol_str = if (space) |s| rest[0..s] else rest;

    const vol = std.fmt.parseFloat(f64, vol_str) catch return .{};
    const pct: u8 = @intFromFloat(std.math.clamp(vol * 100.0, 0.0, 100.0));
    const muted = std.mem.indexOf(u8, line, "[MUTED]") != null;

    return .{ .volume_pct = pct, .muted = muted, .available = true };
}

