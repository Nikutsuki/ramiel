const std = @import("std");

pub const State = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    day: u8 = 0,
    month: u8 = 0,
    weekday: []const u8 = "---",
};

pub fn poll(io: std.Io) State {
    // Use `date` to get local time (handles timezone correctly)
    const child = std.process.spawn(io, .{
        .argv = &.{ "date", "+%H %M %S %d %m %u" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return pollUtc();
    var mutable_child = child;

    var buf: [64]u8 = undefined;
    var reader = mutable_child.stdout.?.reader(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch null;
    _ = mutable_child.wait(io) catch {};

    if (line) |l| {
        return parseDate(l);
    }
    return pollUtc();
}

fn parseDate(line: []const u8) State {
    // "HH MM SS DD MM DOW"
    var it = std.mem.splitScalar(u8, line, ' ');
    const hour_s = it.next() orelse return .{};
    const min_s = it.next() orelse return .{};
    const sec_s = it.next() orelse return .{};
    const day_s = it.next() orelse return .{};
    const mon_s = it.next() orelse return .{};
    const dow_s = it.next() orelse return .{};

    const hour = std.fmt.parseInt(u8, hour_s, 10) catch return .{};
    const minute = std.fmt.parseInt(u8, min_s, 10) catch return .{};
    const second = std.fmt.parseInt(u8, sec_s, 10) catch return .{};
    const day = std.fmt.parseInt(u8, day_s, 10) catch return .{};
    const month = std.fmt.parseInt(u8, mon_s, 10) catch return .{};
    const dow = std.fmt.parseInt(u8, dow_s, 10) catch return .{}; // 1=Mon..7=Sun

    const weekdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const weekday = if (dow >= 1 and dow <= 7) weekdays[dow - 1] else "???";

    return .{ .hour = hour, .minute = minute, .second = second, .day = day, .month = month, .weekday = weekday };
}

fn pollUtc() State {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return .{};

    const epoch_secs: u64 = @intCast(ts.sec);
    const day_secs = epoch_secs % 86400;
    const total_days = epoch_secs / 86400;

    const hour: u8 = @intCast(day_secs / 3600);
    const minute: u8 = @intCast((day_secs % 3600) / 60);
    const second: u8 = @intCast(day_secs % 60);

    // Day of week (1970-01-01 was Thursday = 4)
    const dow = (total_days + 4) % 7;
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

    // Approximate date from epoch days
    const date = epochToDate(total_days);

    return .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .day = date.day,
        .month = date.month,
        .weekday = weekdays[dow],
    };
}

const Date = struct { day: u8, month: u8 };

fn epochToDate(total_days: u64) Date {
    // Civil calendar from epoch days (simplified)
    var days = total_days;
    var year: u64 = 1970;
    while (true) {
        const yd: u64 = if (isLeap(year)) 366 else 365;
        if (days < yd) break;
        days -= yd;
        year += 1;
    }
    const leap = isLeap(year);
    const month_days = if (leap)
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 0;
    while (month < 12) : (month += 1) {
        if (days < month_days[month]) break;
        days -= month_days[month];
    }
    return .{ .day = @intCast(days + 1), .month = month + 1 };
}

fn isLeap(year: u64) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

