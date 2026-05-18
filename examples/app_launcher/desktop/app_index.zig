//! Filesystem scanner for XDG `.desktop` application entries.

const std = @import("std");
const desktop_entry = @import("desktop_entry.zig");
const fuzzy = @import("fuzzy.zig");

pub const App = struct {
    id: []const u8,
    name: []const u8,
    generic_name: []const u8,
    exec: []const u8,
    icon: []const u8,
    categories: []const u8,
    terminal: bool,

    pub fn deinit(self: App, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.generic_name);
        allocator.free(self.exec);
        allocator.free(self.icon);
        allocator.free(self.categories);
    }
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    apps: std.ArrayList(App),

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator, .apps = .empty };
    }

    pub fn deinit(self: *Index) void {
        for (self.apps.items) |app| app.deinit(self.allocator);
        self.apps.deinit(self.allocator);
    }

    pub fn addFromDesktopText(self: *Index, id: []const u8, text: []const u8) !bool {
        const parsed = desktop_entry.parse(id, text);
        if (!parsed.shouldShow()) return false;

        try self.apps.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, parsed.id),
            .name = try self.allocator.dupe(u8, parsed.name),
            .generic_name = try self.allocator.dupe(u8, parsed.generic_name),
            .exec = try desktop_entry.sanitizeExec(self.allocator, parsed.exec),
            .icon = try self.allocator.dupe(u8, parsed.icon),
            .categories = try self.allocator.dupe(u8, parsed.categories),
            .terminal = parsed.terminal,
        });
        return true;
    }

    pub fn scanDir(self: *Index, io: std.Io, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => return,
            else => return err,
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

            const text = dir.readFileAlloc(io, entry.name, self.allocator, .limited(1024 * 1024)) catch continue;
            defer self.allocator.free(text);
            _ = try self.addFromDesktopText(entry.name, text);
        }
    }

    pub fn bestMatch(self: *const Index, query: []const u8) ?usize {
        var best_index: ?usize = null;
        var best_score: i32 = fuzzy.no_match;
        for (self.apps.items, 0..) |app, i| {
            var s = fuzzy.score(query, app.name);
            if (app.generic_name.len > 0) s = @max(s, fuzzy.score(query, app.generic_name) - 4);
            if (s > best_score) {
                best_score = s;
                best_index = i;
            }
        }
        return if (best_score == fuzzy.no_match) null else best_index;
    }
};

pub fn scanXdgDirs(allocator: std.mem.Allocator, io: std.Io, dirs: []const []const u8) !Index {
    var index = Index.init(allocator);
    errdefer index.deinit();

    for (dirs) |dir| try index.scanDir(io, dir);
    return index;
}

test "index adds visible desktop entries and skips hidden ones" {
    const allocator = std.testing.allocator;
    var index = Index.init(allocator);
    defer index.deinit();

    try std.testing.expect(try index.addFromDesktopText("firefox.desktop",
        \\[Desktop Entry]
        \\Name=Firefox
        \\GenericName=Web Browser
        \\Exec=firefox %u
        \\Icon=firefox
    ));
    try std.testing.expect(!try index.addFromDesktopText("hidden.desktop",
        \\[Desktop Entry]
        \\Name=Hidden
        \\Exec=hidden
        \\NoDisplay=true
    ));

    try std.testing.expectEqual(@as(usize, 1), index.apps.items.len);
    try std.testing.expectEqualStrings("firefox", index.apps.items[0].exec);
    try std.testing.expectEqual(@as(?usize, 0), index.bestMatch("ff"));
    try std.testing.expectEqual(@as(?usize, null), index.bestMatch("zzzz"));
}
