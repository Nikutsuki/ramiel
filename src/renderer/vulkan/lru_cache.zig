const std = @import("std");

pub fn LruCache(comptime V: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            key: []const u8,
            value: V,
            link: std.DoublyLinkedList.Node = .{},
        };

        list: std.DoublyLinkedList,
        map: std.StringHashMap(*Entry),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .list = .{},
                .map = std.StringHashMap(*Entry).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var link = self.list.first;
            while (link) |l| {
                link = l.next;
                const entry: *Entry = @fieldParentPtr("link", l);
                self.allocator.destroy(entry);
            }
            self.map.deinit();
        }

        pub fn put(self: *Self, key: []const u8, value: V) !void {
            if (self.map.fetchRemove(key)) |removed| {
                self.list.remove(&removed.value.link);
                self.allocator.destroy(removed.value);
            }
            const entry = try self.allocator.create(Entry);
            entry.* = .{ .key = key, .value = value };
            self.list.append(&entry.link);
            try self.map.put(key, entry);
        }

        pub fn remove(self: *Self, key: []const u8) ?V {
            const removed = self.map.fetchRemove(key) orelse return null;
            self.list.remove(&removed.value.link);
            const value = removed.value.value;
            self.allocator.destroy(removed.value);
            return value;
        }

        pub fn touch(self: *Self, key: []const u8) void {
            if (self.map.get(key)) |entry| {
                self.list.remove(&entry.link);
                self.list.append(&entry.link);
            }
        }

        pub const PopResult = struct { key: []const u8, value: V };

        pub fn popLeastRecentlyUsed(self: *Self) ?PopResult {
            const first_link = self.list.first orelse return null;
            const entry: *Entry = @fieldParentPtr("link", first_link);
            self.list.remove(&entry.link);
            _ = self.map.remove(entry.key);
            const result = PopResult{ .key = entry.key, .value = entry.value };
            self.allocator.destroy(entry);
            return result;
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.map.contains(key);
        }
    };
}
