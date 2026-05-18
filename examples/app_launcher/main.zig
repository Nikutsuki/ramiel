const std = @import("std");
const lib = @import("ramiel");
const app_index = @import("desktop/app_index.zig");
const fuzzy = @import("desktop/fuzzy.zig");
const path_scanner = @import("desktop/path_scanner.zig");
const cache = @import("desktop/cache.zig");
const activation = @import("runtime/activation.zig");
const ipc = @import("runtime/ipc.zig");
pub const tracy_impl = @import("tracy_impl");

const layout = lib.layout;
const tw = lib.tw;
const UpdateAction = lib.UpdateAction;

const usage =
    \\Usage: app_launcher [options]
    \\
    \\A fast, cached application launcher with daemon support.
    \\Discovers desktop entries and PATH binaries, caches the index,
    \\and tracks launch frequency to rank results.
    \\
    \\Options:
    \\  --dir PATH          Add an application directory to scan.
    \\  --scan-nix-store   Recursively scan /nix/store for .desktop files.
    \\  --scan-path        Also index all binaries on $PATH.
    \\  --limit N          Max visible results (default: 50).
    \\  --no-cache         Force a fresh scan, ignoring any cached index.
    \\  --cache-ttl N      Cache lifetime in seconds (default: 3600).
    \\  --daemon           Start hidden and listen for IPC activation.
    \\  --toggle           Send toggle to the running daemon and exit.
    \\  --show             Send show to the running daemon and exit.
    \\  --hide             Send hide to the running daemon and exit.
    \\  --invalidate       Delete the cache and exit.
    \\
    \\Hyprland integration (hyprland.conf):
    \\  exec-once = app_launcher --daemon --scan-path
    \\  bind = SUPER, SPACE, exec, app_launcher --toggle
    \\  windowrulev2 = float,class:(app_launcher)
    \\  windowrulev2 = center,class:(app_launcher)
    \\  windowrulev2 = pin,class:(app_launcher)
    \\  windowrulev2 = stayfocused,class:(app_launcher)
    \\  windowrulev2 = noborder,class:(app_launcher)
    \\  windowrulev2 = noshadow,class:(app_launcher)
    \\  windowrulev2 = noanim,class:(app_launcher)
    \\  windowrulev2 = dimaround,class:(app_launcher)
    \\
;

const ActivationCommand = enum { show, hide, toggle, focus_search };

const AppMessage = union(enum) {
    query_changed,
    select: usize,
    key_nav,
    activation: ActivationCommand,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const NodeIds = lib.declareIds("examples.app_launcher", .{
    "search_input",
    "results_list",
}){};

const Match = struct {
    index: usize,
    score: i32,
};

const max_visible = 64;

const max_tracked_dirs = 128;

const AppState = struct {
    font_data: *lib.FontData = undefined,
    index: app_index.Index,
    freq: cache.FrequencyTable,
    cache_dir_path: []const u8,
    limit: usize = 50,
    selected: usize = 0,
    last_match_count: usize = 0,
    /// Maps visible rank -> app index (set during build).
    visible_app_indices: [max_visible]usize = [_]usize{0} ** max_visible,

    // Rescan config
    scan_dirs: []const []const u8 = &.{},
    scan_path_binaries: bool = false,
    env: *std.process.Environ.Map = undefined,
    io: std.Io = undefined,

    // Directory mtime tracking for smart rescan
    dir_mtimes: [max_tracked_dirs]i96 = [_]i96{0} ** max_tracked_dirs,
    ever_scanned: bool = false,
};

/// Check if any scan directory has been modified since last scan.
fn dirsChanged(state: *AppState) bool {
    if (!state.ever_scanned) return true;

    for (state.scan_dirs, 0..) |dir, i| {
        if (i >= max_tracked_dirs) break;
        const stat = std.Io.Dir.cwd().statFile(state.io, dir, .{}) catch continue;
        const mtime_ns = stat.mtime.nanoseconds;
        if (mtime_ns != state.dir_mtimes[i]) return true;
    }
    return false;
}

/// Record current mtimes of all scan directories.
fn recordDirMtimes(state: *AppState) void {
    for (state.scan_dirs, 0..) |dir, i| {
        if (i >= max_tracked_dirs) break;
        const stat = std.Io.Dir.cwd().statFile(state.io, dir, .{}) catch {
            state.dir_mtimes[i] = 0;
            continue;
        };
        state.dir_mtimes[i] = stat.mtime.nanoseconds;
    }
}

/// Rescan only if directories changed. Returns true if a rescan happened.
fn rescanIfNeeded(state: *AppState) bool {
    if (!dirsChanged(state)) return false;

    const allocator = state.index.allocator;
    state.index.deinit();
    state.index = app_index.Index.init(allocator);

    for (state.scan_dirs) |dir| {
        state.index.scanDir(state.io, dir) catch continue;
    }
    if (state.scan_path_binaries) {
        path_scanner.scanPath(&state.index, state.io, state.env) catch {};
    }

    recordDirMtimes(state);
    state.ever_scanned = true;

    // Persist to cache for faster cold start
    cache.writeIndex(state.io, state.cache_dir_path, &state.index) catch {};
    cache.writeStamp(state.io, allocator, state.cache_dir_path) catch {};

    std.log.info("rescanned: {d} apps", .{state.index.apps.items.len});
    return true;
}

const App = lib.Application(AppState, AppMessage);
const app_id = "app-launcher";

// -- Cache TTL: 1 hour default --
const default_cache_ttl: i96 = 3600;

fn runtimeDir(env: *std.process.Environ.Map) []const u8 {
    return env.get("XDG_RUNTIME_DIR") orelse "/tmp";
}

fn activationCommand(request: activation.Request) ActivationCommand {
    return switch (request) {
        .show => .show,
        .hide => .hide,
        .toggle => .toggle,
        .focus_search => .focus_search,
        .custom => .show,
    };
}

const IpcThreadContext = struct {
    app: *App,
    server: ipc.Server,
};

fn ipcLoop(ctx: *IpcThreadContext) void {
    while (true) {
        const request = ctx.server.acceptActivation() catch |err| {
            std.log.warn("IPC accept failed: {s}", .{@errorName(err)});
            continue;
        };
        ctx.app.postMessageId(.{ .activation = activationCommand(request) });
    }
}

fn waitChild(io: std.Io, child: std.process.Child) void {
    var mutable_child = child;
    _ = mutable_child.wait(io) catch |err| {
        std.log.warn("launched app wait failed: {s}", .{@errorName(err)});
    };
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

fn appendDefaultDirs(
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

        // Home Manager desktop entries
        const hm_apps = try std.fmt.allocPrint(allocator, "{s}/.local/state/nix/profiles/home-manager/share/applications", .{home});
        errdefer allocator.free(hm_apps);
        try owned_dirs.append(allocator, hm_apps);
        try appendDir(allocator, dirs, hm_apps);

        const hm_apps2 = try std.fmt.allocPrint(allocator, "{s}/.local/state/home-manager/gcroots/current-home/home-path/share/applications", .{home});
        errdefer allocator.free(hm_apps2);
        try owned_dirs.append(allocator, hm_apps2);
        try appendDir(allocator, dirs, hm_apps2);
    }
    if (env.get("USER")) |user| {
        const user_profile_apps = try std.fmt.allocPrint(allocator, "/etc/profiles/per-user/{s}/share/applications", .{user});
        errdefer allocator.free(user_profile_apps);
        try owned_dirs.append(allocator, user_profile_apps);
        try appendDir(allocator, dirs, user_profile_apps);
    }
}

fn scanDesktopFilesRecursive(index: *app_index.Index, io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(index.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".desktop")) continue;

        const text = dir.readFileAlloc(io, entry.path, index.allocator, .limited(1024 * 1024)) catch continue;
        defer index.allocator.free(text);
        _ = try index.addFromDesktopText(entry.path, text);
    }
}

// ── Scoring with frequency boost ────────────────────────────────────

fn collectMatches(
    allocator: std.mem.Allocator,
    index: *const app_index.Index,
    freq: *const cache.FrequencyTable,
    query: []const u8,
) ![]Match {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);

    for (index.apps.items, 0..) |desktop_app, app_i| {
        const base_score = if (query.len == 0) blk: {
            break :blk @as(i32, @intCast(index.apps.items.len - app_i));
        } else blk: {
            var s = fuzzy.score(query, desktop_app.name);
            if (desktop_app.generic_name.len > 0)
                s = @max(s, fuzzy.score(query, desktop_app.generic_name) - 4);
            if (desktop_app.categories.len > 0)
                s = @max(s, fuzzy.score(query, desktop_app.categories) - 8);
            break :blk s;
        };
        if (base_score == fuzzy.no_match) continue;

        // Frequency boost: each launch adds 15 points.
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

// ── UI ──────────────────────────────────────────────────────────────

const colors = struct {
    const bg = [4]f32{ 0.07, 0.07, 0.10, 0.95 };
    const surface = [4]f32{ 0.11, 0.11, 0.16, 1.0 };
    const surface_hover = [4]f32{ 0.16, 0.16, 0.22, 1.0 };
    const selected = [4]f32{ 0.20, 0.30, 0.55, 1.0 };
    const selected_hover = [4]f32{ 0.24, 0.34, 0.60, 1.0 };
    const border = [4]f32{ 0.20, 0.22, 0.30, 1.0 };
    const accent = [4]f32{ 0.40, 0.56, 1.0, 1.0 };
    const text_primary = [4]f32{ 0.92, 0.93, 0.97, 1.0 };
    const text_secondary = [4]f32{ 0.55, 0.58, 0.68, 1.0 };
    const text_dim = [4]f32{ 0.38, 0.40, 0.50, 1.0 };
    const input_bg = [4]f32{ 0.06, 0.06, 0.09, 1.0 };
};

fn resultRow(ui: *AppUIContext, state: *const AppState, match: Match, rank: usize) anyerror!*AppNode {
    const ux = ui.ux();
    const desktop_app = state.index.apps.items[match.index];
    const is_selected = state.selected == rank;
    const row_bg: [4]f32 = if (is_selected) colors.selected else colors.surface;
    const hover_bg: [4]f32 = if (is_selected) colors.selected_hover else colors.surface_hover;

    const subtitle = if (desktop_app.generic_name.len > 0)
        desktop_app.generic_name
    else if (desktop_app.categories.len > 0)
        desktop_app.categories
    else
        desktop_app.exec;

    return try ux.div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.flex_col,
            tw.p_xy_px(14.0, 8.0),
            tw.gap_px(2.0),
            tw.bg_value(row_bg),
            tw.hover_value(hover_bg),
            tw.rounded(8.0),
            tw.cursor_pointer,
            tw.overflow_x_hidden,
        }),
        .on_click = .{ .select = rank },
        .children = &.{
            try ux.text(.{
                .content = desktop_app.name,
                .font = state.font_data,
                .style = tw.style(.{
                    tw.text(15.0),
                    tw.text_color_value(if (is_selected) colors.accent else colors.text_primary),
                    tw.text_ellipsis,
                    tw.whitespace_nowrap,
                }),
            }),
            try ux.text(.{
                .content = subtitle,
                .font = state.font_data,
                .style = tw.style(.{
                    tw.text(12.0),
                    tw.text_color_value(colors.text_secondary),
                    tw.text_ellipsis,
                    tw.whitespace_nowrap,
                }),
            }),
        },
    });
}

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const query = ui.getInputText(NodeIds.search_input) orelse "";
    const matches = try collectMatches(arena, &state.index, &state.freq, query);

    const mutable_state: *AppState = @constCast(state);
    mutable_state.last_match_count = matches.len;

    const shown = @min(state.limit, @min(matches.len, max_visible));

    // Populate visible_app_indices for the update handler.
    for (matches[0..shown], 0..) |match, rank| {
        mutable_state.visible_app_indices[rank] = match.index;
    }

    // Read current scroll from old frame's node (will be carried forward by reconciler).
    const prev_scroll: f32 = if (ui.getById(NodeIds.results_list)) |old| old.scroll_y else 0.0;
    const prev_viewport: f32 = if (ui.getById(NodeIds.results_list)) |old| old.layout_result.height else 400.0;

    var result_children: std.ArrayList(?*AppNode) = .empty;
    for (matches[0..shown], 0..) |match, rank| {
        try result_children.append(arena, try resultRow(ui, state, match, rank));
    }

    if (shown == 0 and query.len > 0) {
        try result_children.append(arena, try ux.div(.{
            .style = tw.style(.{
                tw.w_full,
                tw.p_xy_px(14.0, 16.0),
            }),
            .children = &.{
                try ux.text(.{
                    .content = "No matches",
                    .font = state.font_data,
                    .style = tw.style(.{ tw.text(14.0), tw.text_color_value(colors.text_dim) }),
                }),
            },
        }));
    }

    // Auto-focus the search input on every build (so it's focused on show).
    ui.requestFocus(NodeIds.search_input);

    return try ux.div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.items_center,
            tw.justify_center,
            tw.bg_value(.{ 0.0, 0.0, 0.0, 0.0 }),
        }),
        .children = &.{
            // Backdrop: catches clicks outside the panel to dismiss
            try ux.div(.{
                .style = tw.style(.{
                    tw.absolute,
                    tw.inset(0),
                    tw.size_screen,
                    tw.bg_value(.{ 0.0, 0.0, 0.0, 0.35 }),
                }),
                .on_click = .{ .activation = .hide },
            }),
            // Central panel (sibling, not child of backdrop)
            try ux.div(.{
                .style = tw.style(.{
                    tw.w(620.0),
                    tw.max_h(520.0),
                    tw.flex_col,
                    tw.bg_value(colors.bg),
                    tw.rounded(12.0),
                    tw.overflow_y_hidden,
                }),
                .children = &.{
                    // Search bar
                    try ux.div(.{
                        .style = tw.style(.{
                            tw.w_full,
                            tw.p_each_px(14.0, 16.0, 10.0, 16.0),
                            tw.flex_col,
                            tw.gap_px(6.0),
                        }),
                        .children = &.{
                            try ux.textInput(.{
                                .id = NodeIds.search_input,
                                .style = tw.style(.{
                                    tw.w_full,
                                    tw.p_px(10.0),
                                    tw.bg_value(colors.input_bg),
                                    tw.text_color_value(colors.text_primary),
                                    tw.text(16.0),
                                    tw.rounded(8.0),
                                    tw.border_value(1.0, colors.border),
                                }),
                                .font = state.font_data,
                                .placeholder = "Search...",
                                .placeholder_color = colors.text_dim,
                                .on_text_input = .query_changed,
                                .on_key_down = .key_nav,
                            }),
                        },
                    }),
                    // Divider
                    try ux.div(.{
                        .style = tw.style(.{
                            tw.w_full,
                            tw.h(1.0),
                            tw.bg_value(colors.border),
                        }),
                    }),
                    // Results list (scrollable) with scroll-to-selected
                    blk: {
                        const list_node = try ux.div(.{
                            .id = NodeIds.results_list,
                            .style = tw.style(.{
                                tw.w_full,
                                tw.grow_1,
                                tw.flex_col,
                                tw.p_each_px(6.0, 8.0, 8.0, 8.0),
                                tw.gap_px(2.0),
                                tw.overflow_y_scroll,
                                tw.overflow_x_hidden,
                            }),
                            .children = result_children.items,
                        });
                        // Compute scroll to keep selected item in view.
                        // Row height = padding(8+8) + name(~18) + subtitle(~15) + gap(2) ~ 51
                        const row_h: f32 = 53.0;
                        const gap_v: f32 = 2.0;
                        const pad_top: f32 = 6.0;
                        const sel_f: f32 = @floatFromInt(state.selected);
                        const item_top = pad_top + sel_f * (row_h + gap_v);
                        const item_bottom = item_top + row_h;
                        var scroll = prev_scroll;
                        // Scroll down: keep one row of margin below
                        if (item_bottom + row_h > scroll + prev_viewport) scroll = item_bottom + row_h - prev_viewport;
                        // Scroll up: keep one row of margin above
                        if (item_top - row_h < scroll) scroll = @max(item_top - row_h, 0.0);
                        list_node.scroll_y = @max(scroll, 0.0);
                        break :blk list_node;
                    },
                },
            }),
        },
    });
}

// ── Key handling via on_key callback ────────────────────────────────

// Evdev scancodes for navigation keys.
const EvKey = struct {
    const ESC = 1;
    const ENTER = 28;
    const UP = 103;
    const DOWN = 108;
    const TAB = 15;
};

var g_app: ?*App = null;

fn onKeyCallback(evdev_key: u32, state_val: u32) void {
    if (state_val == 0) return; // ignore release (handle press=1 and repeat=2)
    const app = g_app orelse return;
    const is_press = state_val == 1;

    switch (evdev_key) {
        EvKey.ESC => if (is_press) app.postMessageId(.{ .activation = .hide }),
        EvKey.ENTER => if (is_press) app.postMessageId(.{ .select = app.state.selected }),
        EvKey.UP => {
            if (app.state.selected > 0) app.state.selected -= 1;
            app.postMessageId(.key_nav);
        },
        EvKey.DOWN => {
            const max = @min(app.state.limit, app.state.last_match_count);
            if (max > 0 and app.state.selected < max - 1) app.state.selected += 1;
            app.postMessageId(.key_nav);
        },
        EvKey.TAB => {
            const max = @min(app.state.limit, app.state.last_match_count);
            if (max > 0 and app.state.selected < max - 1)
                app.state.selected += 1
            else
                app.state.selected = 0;
            app.postMessageId(.key_nav);
        },
        else => {},
    }
}

// ── Update ──────────────────────────────────────────────────────────

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    switch (msg.id) {
        .query_changed => {
            app.state.selected = 0;
            return .rebuild;
        },
        .key_nav => return .rebuild,
        .select => |rank| {
            const shown = @min(app.state.limit, app.state.last_match_count);
            if (rank >= shown) return .none;

            const app_i = app.state.visible_app_indices[rank];
            if (app_i >= app.state.index.apps.items.len) return .none;
            const desktop_app = app.state.index.apps.items[app_i];

            // Bump frequency and persist.
            app.state.freq.bump(desktop_app.name) catch {};
            cache.writeFrequency(app.io, app.allocator, app.state.cache_dir_path, &app.state.freq) catch {};

            std.log.info("launching: {s} (exec: {s})", .{ desktop_app.name, desktop_app.exec });
            launchExec(app.io, desktop_app.exec) catch |err| {
                std.log.warn("failed to launch {s}: {s}", .{ desktop_app.name, @errorName(err) });
            };
            app.setVisibility(false);
            return .none;
        },
        .activation => |cmd| {
            switch (cmd) {
                .show, .focus_search => {
                    app.state.selected = 0;
                    _ = rescanIfNeeded(&app.state);
                    app.setVisibility(true);
                },
                .hide => app.setVisibility(false),
                .toggle => {
                    const vis = !app.isVisible();
                    if (vis) {
                        app.state.selected = 0;
                        _ = rescanIfNeeded(&app.state);
                    }
                    app.setVisibility(vis);
                },
            }
            return .rebuild;
        },
    }
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();

    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(allocator);

    var owned_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_dirs.items) |dir| allocator.free(dir);
        owned_dirs.deinit(allocator);
    }

    var limit: usize = 50;
    var scan_nix_store = false;
    var scan_path = false;
    var daemon = false;
    var use_cache = true;
    var cache_ttl: i96 = default_cache_ttl;
    var client_request: ?activation.Request = null;
    var invalidate = false;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            const dir = arg_it.next() orelse return error.MissingDirectoryArgument;
            try appendDir(allocator, &dirs, dir);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const raw = arg_it.next() orelse return error.MissingLimitArgument;
            limit = try std.fmt.parseInt(usize, raw, 10);
        } else if (std.mem.eql(u8, arg, "--scan-nix-store")) {
            scan_nix_store = true;
        } else if (std.mem.eql(u8, arg, "--scan-path")) {
            scan_path = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            use_cache = false;
        } else if (std.mem.eql(u8, arg, "--cache-ttl")) {
            const raw = arg_it.next() orelse return error.MissingCacheTtlArgument;
            cache_ttl = try std.fmt.parseInt(i96, raw, 10);
        } else if (std.mem.eql(u8, arg, "--daemon")) {
            daemon = true;
        } else if (std.mem.eql(u8, arg, "--toggle")) {
            client_request = .toggle;
        } else if (std.mem.eql(u8, arg, "--show")) {
            client_request = .show;
        } else if (std.mem.eql(u8, arg, "--hide")) {
            client_request = .hide;
        } else if (std.mem.eql(u8, arg, "--focus-search")) {
            client_request = .focus_search;
        } else if (std.mem.eql(u8, arg, "--invalidate")) {
            invalidate = true;
        } else {
            std.debug.print("unknown argument: {s}\n\n{s}", .{ arg, usage });
            return error.UnknownArgument;
        }
    }

    const socket_path = try ipc.socketPath(allocator, runtimeDir(init.environ_map), app_id);
    defer allocator.free(socket_path);

    if (client_request) |request| {
        try (ipc.Client{ .path = socket_path, .io = io }).sendActivation(request);
        return;
    }

    const cache_path = try cache.cacheDir(allocator, init.environ_map);
    defer allocator.free(cache_path);

    if (invalidate) {
        // Just write an empty index to invalidate.
        var empty_index = app_index.Index.init(allocator);
        defer empty_index.deinit();
        cache.writeIndex(io, cache_path, &empty_index) catch {};
        cache.writeStamp(io, allocator, cache_path) catch {};
        std.debug.print("Cache invalidated.\n", .{});
        return;
    }

    // Always populate dirs for rescan-on-show.
    if (dirs.items.len == 0) {
        try appendDefaultDirs(allocator, init.environ_map, &dirs, &owned_dirs);
    }

    // Load frequency table (survives rescans).
    var freq = try cache.readFrequency(io, allocator, cache_path);
    defer freq.deinit();

    // Initial index: try cache for fast startup, rescan will happen on first show.
    var index: app_index.Index = blk: {
        if (use_cache) {
            if (try cache.isFresh(io, allocator, cache_path, cache_ttl)) {
                if (try cache.readIndex(io, allocator, cache_path)) |cached| {
                    std.log.info("loaded {d} apps from cache (rescan on show)", .{cached.apps.items.len});
                    break :blk cached;
                }
            }
        }
        break :blk app_index.Index.init(allocator);
    };
    errdefer index.deinit();

    var app = try App.init(
        allocator,
        io,
        .{
            .backend = .wayland,
            .transparent = true,
            .title = "Launcher",
            .surface_kind = .{ .layer_shell = .{
                .layer = .overlay,
                .anchors = .{ .top = true, .bottom = true, .left = true, .right = true },
                .exclusive_zone = -1,
                .keyboard_interactivity = .exclusive,
                .namespace = "ramiel-launcher",
            } },
            .width = 0,
            .height = 0,
        },
        .{
            .index = index,
            .freq = freq,
            .cache_dir_path = cache_path,
            .limit = limit,
            .scan_dirs = dirs.items,
            .scan_path_binaries = scan_path,
            .env = init.environ_map,
            .io = io,
        },
        update,
    );
    defer app.deinit();
    defer app.state.index.deinit();

    // If not daemon, do the initial scan now (daemon rescans on first show).
    if (!daemon) _ = rescanIfNeeded(&app.state);

    // Set up backend key callback for navigation (Escape, Enter, arrows).
    g_app = &app;
    app.setBackendKeyHandler(onKeyCallback);

    app.state.font_data = try app.loadDefaultFont(
        "JetBrains Mono",
        .{ .memory = lib.assets.getFontData(.jetbrains_mono) },
        24,
    );

    // If daemon mode, start hidden.
    if (daemon) app.setVisibility(false);

    // IPC daemon.
    var ipc_server: ?ipc.Server = null;
    var ipc_ctx: ?*IpcThreadContext = null;
    defer {
        if (ipc_ctx) |ctx| allocator.destroy(ctx);
        if (ipc_server) |*s| s.deinit();
    }

    if (daemon) {
        ipc_server = try ipc.Server.listen(socket_path, io);
        ipc_ctx = try allocator.create(IpcThreadContext);
        ipc_ctx.?.* = .{ .app = &app, .server = ipc_server.? };
        const ipc_thread = try std.Thread.spawn(.{}, ipcLoop, .{ipc_ctx.?});
        ipc_thread.detach();
        std.log.info("daemon listening on {s}", .{socket_path});
    }

    try app.setRootBuilder(build);
    try app.run();
}
