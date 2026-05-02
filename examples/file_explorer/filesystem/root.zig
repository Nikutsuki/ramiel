const std = @import("std");
const core = @import("../core.zig");

pub fn loadDirectoryContents(allocator: std.mem.Allocator, io: std.Io, parent_node: *core.FsNode) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, parent_node.id, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        const abs_path = try std.fs.path.join(allocator, &.{ parent_node.id, name });

        try parent_node.children.append(allocator, .{
            .id = abs_path,
            .name = name,
            .is_group = entry.kind == .directory,
            .is_loaded = false,
            .children = std.ArrayList(core.FsNode).empty,
        });
    }

    std.mem.sort(core.FsNode, parent_node.children.items, {}, struct {
        fn lessThan(_: void, a: core.FsNode, b: core.FsNode) bool {
            if (a.is_group and !b.is_group) return true;
            if (!a.is_group and b.is_group) return false;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    parent_node.is_loaded = true;
}

pub fn pickNewFolderName(arena: std.mem.Allocator, parent_dir: []const u8, existing: []const core.FsEntry) ![]const u8 {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const name = if (i == 0)
            try arena.dupe(u8, "New Folder")
        else
            try std.fmt.allocPrint(arena, "New Folder ({d})", .{i + 1});

        var collides = false;
        for (existing) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) {
                collides = true;
                break;
            }
        }
        if (!collides) return std.fs.path.join(arena, &.{ parent_dir, name });
    }
    return error.TooManyNewFolders;
}

pub fn deleteAbsolute(io: std.Io, abs_path: []const u8) !void {
    if (std.Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        dir.close(io);
        const parent = std.fs.path.dirname(abs_path) orelse return error.NoParent;
        const name = std.fs.path.basename(abs_path);
        var parent_dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
        defer parent_dir.close(io);
        try parent_dir.deleteTree(io, name);
    } else |_| {
        try std.Io.Dir.deleteFileAbsolute(io, abs_path);
    }
}

pub fn findFsNode(node: *core.FsNode, target_path: []const u8) ?*core.FsNode {
    if (std.mem.eql(u8, node.id, target_path)) {
        return node;
    }

    for (node.children.items) |*child| {
        if (findFsNode(child, target_path)) |found| {
            return found;
        }
    }

    return null;
}
