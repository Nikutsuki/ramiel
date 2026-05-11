//! JSON persistence for AppGlobal.Snapshot. Auto-save lives next to the executable.

const std = @import("std");
const lib = @import("ramiel");
const state = @import("state.zig");

pub const FILE_NAME = "audio_player_library.json";

pub fn save(allocator: std.mem.Allocator, io: std.Io, snapshot: *const state.AppGlobal.Snapshot) !void {
    const json = try lib.state.stringifyEnvelopeAlloc(
        state.AppGlobal.Snapshot,
        allocator,
        state.AppGlobal.snapshot_version,
        snapshot.*,
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(json);

    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = FILE_NAME,
        .data = json,
    });
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) !?state.AppGlobal.Snapshot {
    const bytes = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        FILE_NAME,
        allocator,
        std.Io.Limit.limited64(8 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try lib.state.parseEnvelope(
        state.AppGlobal.Snapshot,
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try lib.state.expectEnvelopeVersion(state.AppGlobal.Snapshot, &parsed, state.AppGlobal.snapshot_version);

    return try cloneSnapshot(allocator, &parsed.value.data);
}

fn cloneSnapshot(allocator: std.mem.Allocator, src: *const state.AppGlobal.Snapshot) !state.AppGlobal.Snapshot {
    var dst: state.AppGlobal.Snapshot = .{
        .theme_mode = src.theme_mode,
        .accent_hue = src.accent_hue,
        .visualizer_defaults = src.visualizer_defaults,
        .playback = src.playback,
        .last_route = src.last_route,
    };
    dst.library = try cloneLibrary(allocator, &src.library);
    return dst;
}

fn cloneLibrary(allocator: std.mem.Allocator, src: *const state.Library) !state.Library {
    var out: state.Library = .{ .next_id = src.next_id };
    if (src.last_folder) |lf| out.last_folder = try allocator.dupe(u8, lf);

    if (src.songs.len > 0) {
        var songs = try allocator.alloc(state.Song, src.songs.len);
        for (src.songs, 0..) |s, i| {
            songs[i] = .{
                .id = s.id,
                .abs_path = try allocator.dupe(u8, s.abs_path),
                .display_name = try allocator.dupe(u8, s.display_name),
                .group_ids = try allocator.dupe(state.GroupId, s.group_ids),
                .tag_ids = try allocator.dupe(state.TagId, s.tag_ids),
            };
        }
        out.songs = songs;
    }
    if (src.groups.len > 0) {
        var groups = try allocator.alloc(state.Group, src.groups.len);
        for (src.groups, 0..) |g, i| {
            groups[i] = .{
                .id = g.id,
                .name = try allocator.dupe(u8, g.name),
                .song_ids = try allocator.dupe(state.SongId, g.song_ids),
            };
        }
        out.groups = groups;
    }
    if (src.tags.len > 0) {
        var tags = try allocator.alloc(state.Tag, src.tags.len);
        for (src.tags, 0..) |t, i| {
            tags[i] = .{
                .id = t.id,
                .name = try allocator.dupe(u8, t.name),
                .hue = t.hue,
            };
        }
        out.tags = tags;
    }
    return out;
}

pub fn freeLoadedSnapshot(allocator: std.mem.Allocator, snap: *state.AppGlobal.Snapshot) void {
    for (snap.library.songs) |s| {
        allocator.free(s.abs_path);
        allocator.free(s.display_name);
        if (s.group_ids.len > 0) allocator.free(s.group_ids);
        if (s.tag_ids.len > 0) allocator.free(s.tag_ids);
    }
    if (snap.library.songs.len > 0) allocator.free(snap.library.songs);
    for (snap.library.groups) |g| {
        allocator.free(g.name);
        if (g.song_ids.len > 0) allocator.free(g.song_ids);
    }
    if (snap.library.groups.len > 0) allocator.free(snap.library.groups);
    for (snap.library.tags) |t| allocator.free(t.name);
    if (snap.library.tags.len > 0) allocator.free(snap.library.tags);
    if (snap.library.last_folder) |lf| allocator.free(lf);
}
