//! Scans $PATH directories for executable binaries and merges them with
//! the desktop-entry index.  Binaries that already have a desktop entry
//! (matched by the base name of `Exec`) are skipped so the richer metadata
//! from the `.desktop` file wins.

const std = @import("std");
const app_index = @import("app_index.zig");

/// Scan every directory listed in `$PATH` and add one `App` per executable
/// that does not already appear in `index` (matched by the binary name
/// against the first token of every existing `App.exec`).
pub fn scanPath(
    index: *app_index.Index,
    io: std.Io,
    env: *std.process.Environ.Map,
) !void {
    const path_var = env.get("PATH") orelse return;
    var seen = std.StringHashMap(void).init(index.allocator);
    defer seen.deinit();

    // Pre-populate with binary names already known from desktop entries.
    for (index.apps.items) |app| {
        const bin = baseBinaryName(app.exec);
        if (bin.len > 0) seen.put(bin, {}) catch {};
    }

    var dirs = std.mem.splitScalar(u8, path_var, ':');
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        scanOneDir(index, io, dir_path, &seen) catch continue;
    }
}

fn scanOneDir(
    index: *app_index.Index,
    io: std.Io,
    dir_path: []const u8,
    seen: *std.StringHashMap(void),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        // Skip hidden files and common non-app helpers.
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (seen.contains(entry.name)) continue;

        // Record immediately to avoid duplicates from later PATH dirs.
        const owned_name = try index.allocator.dupe(u8, entry.name);
        seen.put(owned_name, {}) catch {};

        try index.apps.append(index.allocator, .{
            .id = owned_name,
            .name = try index.allocator.dupe(u8, entry.name),
            .generic_name = try index.allocator.dupe(u8, ""),
            .exec = try index.allocator.dupe(u8, entry.name),
            .icon = try index.allocator.dupe(u8, ""),
            .categories = try index.allocator.dupe(u8, ""),
            .terminal = false,
        });
    }
}

/// Return the base binary name from an Exec line (first whitespace-
/// delimited token, with any leading path stripped).
fn baseBinaryName(exec: []const u8) []const u8 {
    const first = blk: {
        const trimmed = std.mem.trim(u8, exec, " \t");
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| break :blk trimmed[0..sp];
        break :blk trimmed;
    };
    if (std.mem.lastIndexOfScalar(u8, first, '/')) |slash| return first[slash + 1 ..];
    return first;
}
