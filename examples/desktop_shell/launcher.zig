//! App-launcher logic for the desktop shell: desktop/PATH index, fuzzy match
//! with frequency boost, rescan, persistence, and process launching. The UI and
//! message handling live in main.zig (the launcher renders as an overlay on the
//! bar's surface, reusing its Vulkan device/buffers/font atlas).

const std = @import("std");
pub const app_index = @import("desktop/app_index.zig");
const fuzzy = @import("desktop/fuzzy.zig");
const path_scanner = @import("desktop/path_scanner.zig");
pub const cache = @import("desktop/cache.zig");
pub const ipc = @import("runtime/ipc.zig");
pub const activation = @import("runtime/activation.zig");

pub const max_visible = 64;
const max_tracked_dirs = 128;
pub const default_cache_ttl: i96 = 3600;

pub const Match = struct { index: usize, score: i32 };

pub const State = struct {
    index: app_index.Index,
    freq: cache.FrequencyTable,
    cache_dir_path: []const u8 = "",
    limit: usize = 50,
    selected: usize = 0,
    last_match_count: usize = 0,
    visible_app_indices: [max_visible]usize = [_]usize{0} ** max_visible,
    scan_dirs: []const []const u8 = &.{},
    scan_path_binaries: bool = false,
    dir_mtimes: [max_tracked_dirs]i96 = [_]i96{0} ** max_tracked_dirs,
    ever_scanned: bool = false,
    open: bool = false,
    revealed: bool = false,
};

pub fn runtimeDir(env: *std.process.Environ.Map) []const u8 {
    return env.get("XDG_RUNTIME_DIR") orelse "/tmp";
}

pub fn collectMatches(
    allocator: std.mem.Allocator,
    index: *const app_index.Index,
    freq: *const cache.FrequencyTable,
    query: []const u8,
) ![]Match {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);

    for (index.apps.items, 0..) |desktop_app, app_i| {
        const base_score = if (query.len == 0)
            @as(i32, @intCast(index.apps.items.len - app_i))
        else blk: {
            var s = fuzzy.score(query, desktop_app.name);
            if (desktop_app.generic_name.len > 0)
                s = @max(s, fuzzy.score(query, desktop_app.generic_name) - 4);
            if (desktop_app.categories.len > 0)
                s = @max(s, fuzzy.score(query, desktop_app.categories) - 8);
            break :blk s;
        };
        if (base_score == fuzzy.no_match) continue;

        const freq_bonus: i32 = @as(i32, @intCast(@min(freq.get(desktop_app.name), 100))) * 15;
        try matches.append(allocator, .{ .index = app_i, .score = base_score + freq_bonus });
    }

    std.mem.sort(Match, matches.items, {}, struct {
        fn lessThan(_: void, a: Match, b: Match) bool {
            return a.score > b.score;
        }
    }.lessThan);

    return matches.toOwnedSlice(allocator);
}

fn dirsChanged(state: *State, io: std.Io) bool {
    if (!state.ever_scanned) return true;
    for (state.scan_dirs, 0..) |dir, i| {
        if (i >= max_tracked_dirs) break;
        const stat = std.Io.Dir.cwd().statFile(io, dir, .{}) catch continue;
        if (stat.mtime.nanoseconds != state.dir_mtimes[i]) return true;
    }
    return false;
}

fn recordDirMtimes(state: *State, io: std.Io) void {
    for (state.scan_dirs, 0..) |dir, i| {
        if (i >= max_tracked_dirs) break;
        const stat = std.Io.Dir.cwd().statFile(io, dir, .{}) catch {
            state.dir_mtimes[i] = 0;
            continue;
        };
        state.dir_mtimes[i] = stat.mtime.nanoseconds;
    }
}

/// Rescan the configured dirs if any changed since the last scan. Returns true
/// if a rescan happened.
pub fn rescanIfNeeded(state: *State, io: std.Io, env: *std.process.Environ.Map) bool {
    if (!dirsChanged(state, io)) return false;

    const allocator = state.index.allocator;
    state.index.deinit();
    state.index = app_index.Index.init(allocator);

    for (state.scan_dirs) |dir| {
        state.index.scanDir(io, dir) catch continue;
    }
    if (state.scan_path_binaries) {
        path_scanner.scanPath(&state.index, io, env) catch {};
    }

    recordDirMtimes(state, io);
    state.ever_scanned = true;

    cache.writeIndex(io, state.cache_dir_path, &state.index) catch {};
    cache.writeStamp(io, allocator, state.cache_dir_path) catch {};
    std.log.info("rescanned: {d} apps", .{state.index.apps.items.len});
    return true;
}

fn waitChild(io: std.Io, child: std.process.Child) void {
    var mutable_child = child;
    _ = mutable_child.wait(io) catch {};
}

fn launchExec(io: std.Io, exec: []const u8) !void {
    const child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", exec },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const waiter = try std.Thread.spawn(.{}, waitChild, .{ io, child });
    waiter.detach();
}

/// Launch the app at the given visible rank; bumps + persists frequency.
/// Returns true if something was launched.
pub fn activate(state: *State, io: std.Io, allocator: std.mem.Allocator, rank: usize) bool {
    const shown = @min(state.limit, state.last_match_count);
    if (rank >= shown) return false;
    const app_i = state.visible_app_indices[rank];
    if (app_i >= state.index.apps.items.len) return false;
    const desktop_app = state.index.apps.items[app_i];

    state.freq.bump(desktop_app.name) catch {};
    cache.writeFrequency(io, allocator, state.cache_dir_path, &state.freq) catch {};

    std.log.info("launching: {s} (exec: {s})", .{ desktop_app.name, desktop_app.exec });
    launchExec(io, desktop_app.exec) catch |err| {
        std.log.warn("failed to launch {s}: {s}", .{ desktop_app.name, @errorName(err) });
        return false;
    };
    return true;
}

fn appendDir(allocator: std.mem.Allocator, dirs: *std.ArrayList([]const u8), dir: []const u8) !void {
    for (dirs.items) |existing| {
        if (std.mem.eql(u8, existing, dir)) return;
    }
    try dirs.append(allocator, dir);
}

fn appendApplicationDir(
    allocator: std.mem.Allocator,
    dirs: *std.ArrayList([]const u8),
    owned_dirs: *std.ArrayList([]const u8),
    prefix: []const u8,
) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/applications", .{prefix});
    errdefer allocator.free(dir);
    try owned_dirs.append(allocator, dir);
    try appendDir(allocator, dirs, dir);
}

/// Populate the standard XDG + Nix application directories.
pub fn appendDefaultDirs(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    dirs: *std.ArrayList([]const u8),
    owned_dirs: *std.ArrayList([]const u8),
) !void {
    if (env.get("XDG_DATA_HOME")) |xdg_data_home| {
        try appendApplicationDir(allocator, dirs, owned_dirs, xdg_data_home);
    } else if (env.get("HOME")) |home| {
        const prefix = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
        defer allocator.free(prefix);
        try appendApplicationDir(allocator, dirs, owned_dirs, prefix);
    }

    if (env.get("XDG_DATA_DIRS")) |xdg_data_dirs| {
        var it = std.mem.splitScalar(u8, xdg_data_dirs, ':');
        while (it.next()) |prefix| {
            if (prefix.len == 0) continue;
            try appendApplicationDir(allocator, dirs, owned_dirs, prefix);
        }
    } else {
        try appendDir(allocator, dirs, "/usr/local/share/applications");
        try appendDir(allocator, dirs, "/usr/share/applications");
    }

    try appendDir(allocator, dirs, "/run/current-system/sw/share/applications");
    try appendDir(allocator, dirs, "/nix/var/nix/profiles/default/share/applications");
    if (env.get("HOME")) |home| {
        const profile_apps = try std.fmt.allocPrint(allocator, "{s}/.nix-profile/share/applications", .{home});
        errdefer allocator.free(profile_apps);
        try owned_dirs.append(allocator, profile_apps);
        try appendDir(allocator, dirs, profile_apps);

        const hm_apps = try std.fmt.allocPrint(allocator, "{s}/.local/state/nix/profiles/home-manager/share/applications", .{home});
        errdefer allocator.free(hm_apps);
        try owned_dirs.append(allocator, hm_apps);
        try appendDir(allocator, dirs, hm_apps);
    }
    if (env.get("USER")) |user| {
        const user_profile_apps = try std.fmt.allocPrint(allocator, "/etc/profiles/per-user/{s}/share/applications", .{user});
        errdefer allocator.free(user_profile_apps);
        try owned_dirs.append(allocator, user_profile_apps);
        try appendDir(allocator, dirs, user_profile_apps);
    }
}

/// Load the initial index from cache (fast cold start); empty if stale/missing.
pub fn loadInitialIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    use_cache: bool,
    cache_ttl: i96,
) app_index.Index {
    if (use_cache) {
        if (cache.isFresh(io, allocator, cache_path, cache_ttl) catch false) {
            if (cache.readIndex(io, allocator, cache_path) catch null) |cached| {
                std.log.info("loaded {d} apps from cache (rescan on show)", .{cached.apps.items.len});
                return cached;
            }
        }
    }
    return app_index.Index.init(allocator);
}
