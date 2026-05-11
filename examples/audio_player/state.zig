//! App-wide state for the music player example.
//! - `AppGlobal`: serializable. Library + theme + visualizer defaults + EQ/crossfade/gapless.
//! - `AppRuntime`: non-serializable. Playback handles, FFT buffers, transient UI flags.

const std = @import("std");
const lib = @import("ramiel");

pub const SongId = u64;
pub const GroupId = u64;
pub const TagId = u64;

pub const Song = struct {
    id: SongId,
    abs_path: []const u8,
    display_name: []const u8,
    group_ids: []GroupId = &.{},
    tag_ids: []TagId = &.{},
};

pub const Group = struct {
    id: GroupId,
    name: []const u8,
    song_ids: []SongId = &.{},
};

pub const Tag = struct {
    id: TagId,
    name: []const u8,
    hue: f32 = 200.0,
};

pub const ThemeMode = enum { dark, light };

pub const MirrorMode = enum { none, x_axis, y_axis };

pub const VisualizerConfig = struct {
    enabled: bool = true,
    mirror: MirrorMode = .y_axis,
    smoothing: f32 = 0.85,
    n_bands: usize = 64,
    sensitivity: f32 = 1.0,
    bar_gap: f32 = 0.0,
};

pub const EQBandCfg = struct {
    freq_hz: f32 = 1000.0,
    gain_db: f32 = 0.0,
    q: f32 = 0.707,
};

pub const EQConfig = struct {
    enabled: bool = false,
    low: EQBandCfg = .{ .freq_hz = 80.0 },
    mid: EQBandCfg = .{ .freq_hz = 1000.0 },
    high: EQBandCfg = .{ .freq_hz = 8000.0 },
};

pub const PlaybackConfig = struct {
    eq: EQConfig = .{},
    crossfade_ms: u32 = 0,
    gapless_in_group: bool = true,
    volume: f32 = 1.0,
};

pub const Library = struct {
    songs: []Song = &.{},
    groups: []Group = &.{},
    tags: []Tag = &.{},
    next_id: u64 = 1,
    last_folder: ?[]const u8 = null,
};

pub const AppGlobal = struct {
    pub const snapshot_version: lib.state.SnapshotVersion = 1;

    allocator: std.mem.Allocator,
    library: Library = .{},
    theme_mode: ThemeMode = .dark,
    accent_hue: f32 = 250.0,
    accent_chroma: f32 = 0.16,
    accent_lightness: f32 = 0.62,
    visualizer_defaults: VisualizerConfig = .{},
    playback: PlaybackConfig = .{},
    last_route: u8 = 0,
    library_dirty: bool = false,

    pub const Snapshot = struct {
        library: Library = .{},
        theme_mode: ThemeMode = .dark,
        accent_hue: f32 = 250.0,
        accent_chroma: f32 = 0.16,
        accent_lightness: f32 = 0.62,
        visualizer_defaults: VisualizerConfig = .{},
        playback: PlaybackConfig = .{},
        last_route: u8 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) !AppGlobal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppGlobal) void {
        freeLibrary(self.allocator, &self.library);
    }

    pub fn snapshot(self: *const AppGlobal) Snapshot {
        return .{
            .library = self.library,
            .theme_mode = self.theme_mode,
            .accent_hue = self.accent_hue,
            .accent_chroma = self.accent_chroma,
            .accent_lightness = self.accent_lightness,
            .visualizer_defaults = self.visualizer_defaults,
            .playback = self.playback,
            .last_route = self.last_route,
        };
    }

    pub fn restoreSnapshot(self: *AppGlobal, data: *const Snapshot) !void {
        freeLibrary(self.allocator, &self.library);
        self.library = try cloneLibrary(self.allocator, &data.library);
        self.theme_mode = data.theme_mode;
        self.accent_hue = data.accent_hue;
        self.accent_chroma = data.accent_chroma;
        self.accent_lightness = data.accent_lightness;
        self.visualizer_defaults = data.visualizer_defaults;
        self.playback = data.playback;
        self.last_route = data.last_route;
        self.library_dirty = false;
    }

    pub fn nextId(self: *AppGlobal) u64 {
        const id = self.library.next_id;
        self.library.next_id +%= 1;
        if (self.library.next_id == 0) self.library.next_id = 1;
        return id;
    }

    pub fn markDirty(self: *AppGlobal) void {
        self.library_dirty = true;
    }

    /// Add a song; de-dups by abs_path. Returns the song id (existing or new).
    pub fn addSong(self: *AppGlobal, abs_path: []const u8, display_name: []const u8) !SongId {
        for (self.library.songs) |s| {
            if (std.mem.eql(u8, s.abs_path, abs_path)) return s.id;
        }
        const id = self.nextId();
        const new_song: Song = .{
            .id = id,
            .abs_path = try self.allocator.dupe(u8, abs_path),
            .display_name = try self.allocator.dupe(u8, display_name),
        };
        self.library.songs = try appendOwned(Song, self.allocator, self.library.songs, new_song);
        self.markDirty();
        return id;
    }

    pub fn removeSong(self: *AppGlobal, id: SongId) void {
        var idx: usize = 0;
        while (idx < self.library.songs.len) : (idx += 1) {
            if (self.library.songs[idx].id == id) break;
        }
        if (idx >= self.library.songs.len) return;
        const s = self.library.songs[idx];
        self.allocator.free(s.abs_path);
        self.allocator.free(s.display_name);
        self.allocator.free(s.group_ids);
        self.allocator.free(s.tag_ids);
        self.library.songs = removeAt(Song, self.allocator, self.library.songs, idx) catch self.library.songs;

        // Remove from group song_id lists too.
        for (self.library.groups) |*g| {
            g.song_ids = filterOut(SongId, self.allocator, g.song_ids, id) catch g.song_ids;
        }
        self.markDirty();
    }

    pub fn createGroup(self: *AppGlobal, name: []const u8) !GroupId {
        const id = self.nextId();
        const g: Group = .{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
        };
        self.library.groups = try appendOwned(Group, self.allocator, self.library.groups, g);
        self.markDirty();
        return id;
    }

    pub fn renameTag(self: *AppGlobal, id: TagId, new_name: []const u8) !void {
        for (self.library.tags) |*t| {
            if (t.id == id) {
                self.allocator.free(t.name);
                t.name = try self.allocator.dupe(u8, new_name);
                self.markDirty();
                return;
            }
        }
    }

    pub fn renameGroup(self: *AppGlobal, id: GroupId, new_name: []const u8) !void {
        for (self.library.groups) |*g| {
            if (g.id == id) {
                self.allocator.free(g.name);
                g.name = try self.allocator.dupe(u8, new_name);
                self.markDirty();
                return;
            }
        }
    }

    pub fn deleteGroup(self: *AppGlobal, id: GroupId) void {
        var idx: usize = 0;
        while (idx < self.library.groups.len) : (idx += 1) {
            if (self.library.groups[idx].id == id) break;
        }
        if (idx >= self.library.groups.len) return;
        const g = self.library.groups[idx];
        self.allocator.free(g.name);
        self.allocator.free(g.song_ids);
        self.library.groups = removeAt(Group, self.allocator, self.library.groups, idx) catch self.library.groups;

        for (self.library.songs) |*s| {
            s.group_ids = filterOut(GroupId, self.allocator, s.group_ids, id) catch s.group_ids;
        }
        self.markDirty();
    }

    pub fn addSongToGroup(self: *AppGlobal, song_id: SongId, group_id: GroupId) !void {
        for (self.library.groups) |*g| {
            if (g.id != group_id) continue;
            for (g.song_ids) |existing| if (existing == song_id) return;
            g.song_ids = try appendOwned(SongId, self.allocator, g.song_ids, song_id);
            break;
        }
        for (self.library.songs) |*s| {
            if (s.id != song_id) continue;
            for (s.group_ids) |existing| if (existing == group_id) return;
            s.group_ids = try appendOwned(GroupId, self.allocator, s.group_ids, group_id);
            break;
        }
        self.markDirty();
    }

    pub fn removeSongFromGroup(self: *AppGlobal, song_id: SongId, group_id: GroupId) void {
        for (self.library.groups) |*g| {
            if (g.id == group_id) {
                g.song_ids = filterOut(SongId, self.allocator, g.song_ids, song_id) catch g.song_ids;
                break;
            }
        }
        for (self.library.songs) |*s| {
            if (s.id == song_id) {
                s.group_ids = filterOut(GroupId, self.allocator, s.group_ids, group_id) catch s.group_ids;
                break;
            }
        }
        self.markDirty();
    }

    pub fn createTag(self: *AppGlobal, name: []const u8, hue: f32) !TagId {
        const id = self.nextId();
        const t: Tag = .{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .hue = hue,
        };
        self.library.tags = try appendOwned(Tag, self.allocator, self.library.tags, t);
        self.markDirty();
        return id;
    }

    pub fn deleteTag(self: *AppGlobal, id: TagId) void {
        var idx: usize = 0;
        while (idx < self.library.tags.len) : (idx += 1) {
            if (self.library.tags[idx].id == id) break;
        }
        if (idx >= self.library.tags.len) return;
        const t = self.library.tags[idx];
        self.allocator.free(t.name);
        self.library.tags = removeAt(Tag, self.allocator, self.library.tags, idx) catch self.library.tags;

        for (self.library.songs) |*s| {
            s.tag_ids = filterOut(TagId, self.allocator, s.tag_ids, id) catch s.tag_ids;
        }
        self.markDirty();
    }

    pub fn toggleSongTag(self: *AppGlobal, song_id: SongId, tag_id: TagId) !void {
        for (self.library.songs) |*s| {
            if (s.id != song_id) continue;
            for (s.tag_ids, 0..) |t, i| {
                if (t == tag_id) {
                    var new = try self.allocator.alloc(TagId, s.tag_ids.len - 1);
                    @memcpy(new[0..i], s.tag_ids[0..i]);
                    @memcpy(new[i..], s.tag_ids[i + 1 ..]);
                    self.allocator.free(s.tag_ids);
                    s.tag_ids = new;
                    self.markDirty();
                    return;
                }
            }
            s.tag_ids = try appendOwned(TagId, self.allocator, s.tag_ids, tag_id);
            self.markDirty();
            return;
        }
    }

    pub fn songById(self: *const AppGlobal, id: SongId) ?*const Song {
        for (self.library.songs) |*s| if (s.id == id) return s;
        return null;
    }

    pub fn groupById(self: *const AppGlobal, id: GroupId) ?*const Group {
        for (self.library.groups) |*g| if (g.id == id) return g;
        return null;
    }

    pub fn tagById(self: *const AppGlobal, id: TagId) ?*const Tag {
        for (self.library.tags) |*t| if (t.id == id) return t;
        return null;
    }

    pub fn setLastFolder(self: *AppGlobal, path: []const u8) !void {
        if (self.library.last_folder) |old| self.allocator.free(old);
        self.library.last_folder = try self.allocator.dupe(u8, path);
        self.markDirty();
    }

    pub fn clearLibrary(self: *AppGlobal) void {
        freeLibraryContents(self.allocator, &self.library);
        self.library = .{ .next_id = self.library.next_id };
        self.markDirty();
    }
};

pub const AppRuntime = struct {
    pub const serializable = false;

    allocator: std.mem.Allocator,
    app: ?*anyopaque = null, // set in setup
    font_data: ?*lib.FontData = null,

    /// Currently playing stream, if any.
    playback_id: ?u64 = null,
    current_song_id: ?SongId = null,
    cursor_seconds: f32 = 0.0,
    duration_seconds: f32 = 0.0,
    last_known_playing: bool = false,

    /// Visualizer buffers (allocated lazily).
    wave_samples: []f32 = &.{},
    wave_xs: []f64 = &.{},
    wave_ys: []f64 = &.{},
    wave_series: [1]lib.components.PlotSeries = undefined,
    wave_state: lib.components.PlotState = undefined,

    spectrum: lib.audio_spectrum.Analyzer = undefined,
    spectrum_xs: []f64 = &.{},
    spectrum_ys_pos: []f64 = &.{},
    spectrum_ys_neg: []f64 = &.{},
    spectrum_series: [2]lib.components.PlotSeries = undefined,
    spectrum_state: lib.components.PlotState = undefined,
    spectrum_sample_rate: f32 = 44100.0,
    spectrum_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) !AppRuntime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppRuntime) void {
        if (self.wave_samples.len > 0) {
            self.allocator.free(self.wave_samples);
            self.allocator.free(self.wave_xs);
            self.allocator.free(self.wave_ys);
            self.wave_state.deinit();
        }
        if (self.spectrum_initialized) {
            self.spectrum.deinit();
            self.allocator.free(self.spectrum_xs);
            self.allocator.free(self.spectrum_ys_pos);
            self.allocator.free(self.spectrum_ys_neg);
            self.spectrum_state.deinit();
        }
    }
};

// ---- helpers ----

fn appendOwned(comptime T: type, allocator: std.mem.Allocator, slice: []T, item: T) ![]T {
    var new = try allocator.alloc(T, slice.len + 1);
    @memcpy(new[0..slice.len], slice);
    new[slice.len] = item;
    if (slice.len > 0) allocator.free(slice);
    return new;
}

fn removeAt(comptime T: type, allocator: std.mem.Allocator, slice: []T, idx: usize) ![]T {
    if (slice.len == 1) {
        allocator.free(slice);
        return &.{};
    }
    var new = try allocator.alloc(T, slice.len - 1);
    @memcpy(new[0..idx], slice[0..idx]);
    @memcpy(new[idx..], slice[idx + 1 ..]);
    allocator.free(slice);
    return new;
}

fn filterOut(comptime T: type, allocator: std.mem.Allocator, slice: []T, target: T) ![]T {
    var count: usize = 0;
    for (slice) |x| {
        if (x != target) count += 1;
    }
    if (count == slice.len) return slice;
    if (count == 0) {
        if (slice.len > 0) allocator.free(slice);
        return &.{};
    }
    var new = try allocator.alloc(T, count);
    var i: usize = 0;
    for (slice) |x| {
        if (x != target) {
            new[i] = x;
            i += 1;
        }
    }
    allocator.free(slice);
    return new;
}

fn cloneLibrary(allocator: std.mem.Allocator, src: *const Library) !Library {
    var lib_out: Library = .{ .next_id = src.next_id };
    if (src.last_folder) |lf| lib_out.last_folder = try allocator.dupe(u8, lf);

    if (src.songs.len > 0) {
        var songs = try allocator.alloc(Song, src.songs.len);
        for (src.songs, 0..) |s, i| {
            songs[i] = .{
                .id = s.id,
                .abs_path = try allocator.dupe(u8, s.abs_path),
                .display_name = try allocator.dupe(u8, s.display_name),
                .group_ids = try allocator.dupe(GroupId, s.group_ids),
                .tag_ids = try allocator.dupe(TagId, s.tag_ids),
            };
        }
        lib_out.songs = songs;
    }
    if (src.groups.len > 0) {
        var groups = try allocator.alloc(Group, src.groups.len);
        for (src.groups, 0..) |g, i| {
            groups[i] = .{
                .id = g.id,
                .name = try allocator.dupe(u8, g.name),
                .song_ids = try allocator.dupe(SongId, g.song_ids),
            };
        }
        lib_out.groups = groups;
    }
    if (src.tags.len > 0) {
        var tags = try allocator.alloc(Tag, src.tags.len);
        for (src.tags, 0..) |t, i| {
            tags[i] = .{
                .id = t.id,
                .name = try allocator.dupe(u8, t.name),
                .hue = t.hue,
            };
        }
        lib_out.tags = tags;
    }
    return lib_out;
}

fn freeLibraryContents(allocator: std.mem.Allocator, l: *Library) void {
    for (l.songs) |s| {
        allocator.free(s.abs_path);
        allocator.free(s.display_name);
        if (s.group_ids.len > 0) allocator.free(s.group_ids);
        if (s.tag_ids.len > 0) allocator.free(s.tag_ids);
    }
    if (l.songs.len > 0) allocator.free(l.songs);
    for (l.groups) |g| {
        allocator.free(g.name);
        if (g.song_ids.len > 0) allocator.free(g.song_ids);
    }
    if (l.groups.len > 0) allocator.free(l.groups);
    for (l.tags) |t| allocator.free(t.name);
    if (l.tags.len > 0) allocator.free(l.tags);
    if (l.last_folder) |lf| allocator.free(lf);
}

fn freeLibrary(allocator: std.mem.Allocator, l: *Library) void {
    freeLibraryContents(allocator, l);
    l.* = .{};
}

/// Stable HSL-from-hash → swatch color for a song id.
pub fn swatchColor(id: SongId) [4]f32 {
    var h: u64 = id;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    const hue: f32 = @as(f32, @floatFromInt(h % 360));
    return hslToRgb(hue, 0.55, 0.55);
}

pub fn hslToRgb(h: f32, s: f32, l: f32) [4]f32 {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const rgb: [3]f32 = if (hp < 1.0)
        .{ c, x, 0 }
    else if (hp < 2.0)
        .{ x, c, 0 }
    else if (hp < 3.0)
        .{ 0, c, x }
    else if (hp < 4.0)
        .{ 0, x, c }
    else if (hp < 5.0)
        .{ x, 0, c }
    else
        .{ c, 0, x };
    const m = l - c * 0.5;
    return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m, 1.0 };
}
