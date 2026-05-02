const std = @import("std");

pub const EnvParser = struct {
    pub fn parse(allocator: std.mem.Allocator, content: []const u8, target_map: *std.StringHashMap([]const u8)) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var parts = std.mem.splitScalar(u8, trimmed, '=');
            const key = parts.next() orelse continue;
            const val = parts.rest();

            const final_key = try allocator.dupe(u8, std.mem.trim(u8, key, " "));
            const final_val = try allocator.dupe(u8, std.mem.trim(u8, val, " "));

            try target_map.put(final_key, final_val);
        }
    }

    pub fn freeMapContents(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
    }
};
