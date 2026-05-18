//! Persistent cache for the app index and launch-frequency counters.
//!
//! Layout on disk (under `$XDG_CACHE_HOME/ramiel-launcher/`):
//!   index.txt   – tab-separated text dump of all discovered apps
//!   freq.txt    – "exec_name\tcount\n" launch frequency table
//!   stamp       – last-scan wall-clock timestamp (unix seconds, text)

const std = @import("std");
const app_index = @import("app_index.zig");

const cache_dir_name = "ramiel-launcher";

pub const FrequencyTable = struct {
    map: std.StringHashMap(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FrequencyTable {
        return .{ .map = std.StringHashMap(u32).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *FrequencyTable) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.map.deinit();
    }

    pub fn bump(self: *FrequencyTable, name: []const u8) !void {
        if (self.map.getPtr(name)) |count| {
            count.* += 1;
        } else {
            const owned = try self.allocator.dupe(u8, name);
            try self.map.put(owned, 1);
        }
    }

    pub fn get(self: *const FrequencyTable, name: []const u8) u32 {
        return self.map.get(name) orelse 0;
    }
};

/// Resolve the cache directory path.
pub fn cacheDir(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CACHE_HOME")) |base| {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, cache_dir_name });
    }
    if (env.get("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.cache/{s}", .{ home, cache_dir_name });
    }
    return std.fmt.allocPrint(allocator, "/tmp/{s}", .{cache_dir_name});
}

fn writeToFile(io: std.Io, dir_path: []const u8, filename: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    ensureDir(io, dir_path);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename });
    defer allocator.free(path);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = path, .data = data });
}

fn readFromFile(io: std.Io, dir_path: []const u8, filename: []const u8, allocator: std.mem.Allocator, limit: usize) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename });
    defer allocator.free(path);
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(limit));
}

/// Write the index to cache as a simple text format.
pub fn writeIndex(io: std.Io, dir_path: []const u8, index: *const app_index.Index) !void {
    const allocator = index.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    for (index.apps.items) |app| {
        try buf.writer.writeAll(app.name);
        try buf.writer.writeByte('\t');
        try buf.writer.writeAll(app.generic_name);
        try buf.writer.writeByte('\t');
        try buf.writer.writeAll(app.exec);
        try buf.writer.writeByte('\t');
        try buf.writer.writeAll(app.icon);
        try buf.writer.writeByte('\t');
        try buf.writer.writeAll(app.categories);
        try buf.writer.writeByte('\t');
        try buf.writer.writeAll(if (app.terminal) "1" else "0");
        try buf.writer.writeByte('\n');
    }

    try writeToFile(io, dir_path, "index.txt", buf.written(), allocator);
}

/// Read the index back from cache.
pub fn readIndex(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !?app_index.Index {
    const contents = readFromFile(io, dir_path, "index.txt", allocator, 64 * 1024 * 1024) catch return null;
    defer allocator.free(contents);

    var index = app_index.Index.init(allocator);
    errdefer index.deinit();

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        const generic_name = cols.next() orelse "";
        const exec = cols.next() orelse continue;
        const icon = cols.next() orelse "";
        const categories = cols.next() orelse "";
        const terminal_str = cols.next() orelse "0";

        try index.apps.append(allocator, .{
            .id = try allocator.dupe(u8, name),
            .name = try allocator.dupe(u8, name),
            .generic_name = try allocator.dupe(u8, generic_name),
            .exec = try allocator.dupe(u8, exec),
            .icon = try allocator.dupe(u8, icon),
            .categories = try allocator.dupe(u8, categories),
            .terminal = std.mem.eql(u8, terminal_str, "1"),
        });
    }

    if (index.apps.items.len == 0) return null;
    return index;
}

/// Write the frequency table.
pub fn writeFrequency(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, freq: *const FrequencyTable) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    var it = freq.map.iterator();
    while (it.next()) |entry| {
        try buf.writer.writeAll(entry.key_ptr.*);
        try buf.writer.writeByte('\t');
        try buf.writer.print("{d}", .{entry.value_ptr.*});
        try buf.writer.writeByte('\n');
    }

    try writeToFile(io, dir_path, "freq.txt", buf.written(), allocator);
}

/// Read the frequency table.
pub fn readFrequency(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !FrequencyTable {
    var freq = FrequencyTable.init(allocator);
    errdefer freq.deinit();

    const contents = readFromFile(io, dir_path, "freq.txt", allocator, 4 * 1024 * 1024) catch return freq;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        const count_str = cols.next() orelse continue;
        const count = std.fmt.parseInt(u32, count_str, 10) catch continue;
        const owned = try allocator.dupe(u8, name);
        try freq.map.put(owned, count);
    }

    return freq;
}

fn nowSeconds(io: std.Io) i96 {
    const ts = std.Io.Clock.real.now(io);
    return @divTrunc(ts.nanoseconds, std.time.ns_per_s);
}

/// Write current unix timestamp as the scan stamp.
pub fn writeStamp(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const now = nowSeconds(io);
    const text = try std.fmt.allocPrint(allocator, "{d}", .{now});
    defer allocator.free(text);
    try writeToFile(io, dir_path, "stamp", text, allocator);
}

/// Read the scan stamp.  Returns null if missing.
pub fn readStamp(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !?i96 {
    const text = readFromFile(io, dir_path, "stamp", allocator, 64) catch return null;
    defer allocator.free(text);
    return std.fmt.parseInt(i96, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

/// Returns true if cache is fresh enough (less than `max_age_s` seconds old).
pub fn isFresh(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, max_age_s: i96) !bool {
    const stamp = try readStamp(io, allocator, dir_path) orelse return false;
    const now = nowSeconds(io);
    return (now - stamp) < max_age_s;
}

fn ensureDir(io: std.Io, dir_path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
}
