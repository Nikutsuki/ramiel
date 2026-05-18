const std = @import("std");
const glfw = @import("glfw");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const UpdateAction = lib.UpdateAction;
const FontData = lib.FontData;
const tw = lib.tw;
const everything = @import("everything.zig");
const win32 = lib.win32;

const Color = lib.Color;

const WIN_W: i32 = 1100;
const WIN_H: i32 = 620;
const VK_SPACE: u32 = 0x20;
const MAX_UI_RESULTS: usize = 200;
const PREVIEW_IMAGE_SIZE: u32 = 100;

const AppMsg = union(enum) {
    search_changed,
    results_ready,
    hide_click,
    result_click: usize,
    result_hover_enter: usize,
    result_hover_exit: usize,
};

const T = lib.For(AppMsg);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const NodeIds = lib.declareIds("examples.overlay", .{ "search_input", "results_scroller" }){};

const AppState = struct {
    allocator: std.mem.Allocator,

    font: *FontData = undefined,
    search: ?*everything.SearchSubsystem = null,

    results: []everything.SearchResult = &.{},
    total_hits: usize = 0,
    status_line: ?[]u8 = null,
    preview_requested: ?std.StringHashMap(void) = null,
    active_hover_audio: ?[]u8 = null,
    active_hover_playback_id: ?u64 = null,
};

const App = lib.Application(AppState, AppMsg);

const ResultListContext = struct {
    state: *const AppState,
    font: *FontData,
};

fn buildResultRow(ui: *AppUIContext, ctx: ResultListContext, index: usize) !?*AppNode {
    const PANEL: [4]f32 = comptime Color.parse("oklch(45% 0.1 270 / 0.95)");
    const TEXT: [4]f32 = comptime Color.parse("oklch(80% 0.1 270 / 0.95)");
    const DIM: [4]f32 = comptime Color.parse("oklch(70% 0.1 270 / 0.95)");
    const EDGE: [4]f32 = comptime Color.parse("oklch(60% 0.1 270 / 0.95)");

    const item = ctx.state.results[index];
    const has_image = !item.is_folder and isImagePath(item.full_path);

    const preview = if (has_image)
        try ui.ux().asyncImage(.{
            .source = item.full_path,
            .alt_text = item.filename,
            .alt_font = ctx.font,
            .style = tw.style(.{
                tw.square(PREVIEW_IMAGE_SIZE),
                tw.rounded(6),
                tw.bg_value(.{ EDGE[0], EDGE[1], EDGE[2], 0.20 }),
                tw.text_color_value(DIM),
                tw.p_px(3),
            }),
        })
    else
        null;

    const text_col = try ui.ux().div(.{
        .style = tw.style(.{ tw.grow_1, tw.flex_col, tw.gap_px(2) }),
        .children = &.{
            try ui.ux().text(.{
                .content = item.filename,
                .font = ctx.font,
                .style = tw.style(.{ tw.text_color_value(TEXT), tw.pointer_events_none }),
            }),
            try ui.ux().text(.{
                .content = item.full_path,
                .font = ctx.font,
                .style = tw.style(.{ tw.text_color_value(DIM), tw.pointer_events_none }),
            }),
        },
    });

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.flex_row,
            tw.items_center,
            tw.justify_between,
            tw.gap_px(10),
            tw.p_xy_px(12, 8),
            tw.bg_value(.{ PANEL[0], PANEL[1], PANEL[2], 0.0 }),
            tw.hover_value(PANEL),
            tw.transition(.{
                .property = .{ .hover_color = true, .background_color = true },
                .duration_ms = 200,
                .timing = .ease_out,
            }),
            tw.border_b_value(1, .{ EDGE[0], EDGE[1], EDGE[2], 0.45 }),
        }),
        .events = &.{
            .{ .event = .click, .msg = .{ .result_click = index } },
            .{ .event = .hover_enter, .msg = .{ .result_hover_enter = index } },
            .{ .event = .hover_exit, .msg = .{ .result_hover_exit = index } },
        },
        .children = &.{ text_col, preview },
    });
}

fn queueImagePreviews(app: *App) void {
    const state = &app.state;
    const cache = if (state.preview_requested) |*c| c else return;

    for (state.results) |item| {
        if (item.is_folder or !isImagePath(item.full_path)) continue;
        if (cache.contains(item.full_path)) continue;

        cache.put(item.full_path, {}) catch continue;
        app.loadImageFromDiskAsyncSized(
            item.full_path,
            item.full_path,
            PREVIEW_IMAGE_SIZE,
            PREVIEW_IMAGE_SIZE,
        ) catch {};
    }
}

fn clearResults(app: *App) void {
    const state = &app.state;
    stopActiveHoverAudio(app);

    if (state.preview_requested) |*cache| {
        cache.clearRetainingCapacity();
    }
    if (state.results.len == 0) return;
    everything.freeResultSlice(state.allocator, state.results);
    state.results = &.{};
    state.total_hits = 0;
}

fn setStatus(state: *AppState, line: []const u8) void {
    if (state.status_line) |old| state.allocator.free(old);
    state.status_line = state.allocator.dupe(u8, line) catch null;
}

fn deinitAppState(app: *App) void {
    const state = &app.state;
    stopActiveHoverAudio(app);

    if (state.search) |search| {
        search.deinit();
        state.search = null;
    }

    clearResults(app);

    if (state.status_line) |line| {
        state.allocator.free(line);
        state.status_line = null;
    }

    if (state.preview_requested) |*cache| {
        cache.deinit();
        state.preview_requested = null;
    }
}

fn isAudioPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;

    return std.ascii.eqlIgnoreCase(ext, ".mp3") or
        std.ascii.eqlIgnoreCase(ext, ".wav") or
        std.ascii.eqlIgnoreCase(ext, ".ogg") or
        std.ascii.eqlIgnoreCase(ext, ".flac") or
        std.ascii.eqlIgnoreCase(ext, ".m4a") or
        std.ascii.eqlIgnoreCase(ext, ".aac");
}

fn stopActiveHoverAudio(app: *App) void {
    const state = &app.state;
    if (state.active_hover_playback_id) |id| {
        app.stopSound(id);
        app.unloadSound(state.active_hover_audio.?);
        state.active_hover_playback_id = null;
    }
    state.active_hover_audio = null;
}

fn playHoveredAudio(app: *App, index: usize) void {
    const state = &app.state;
    if (index >= state.results.len) return;
    const item = state.results[index];
    if (item.is_folder or !isAudioPath(item.full_path)) return;

    if (state.active_hover_audio) |active| {
        if (std.mem.eql(u8, active, item.full_path)) return;
        if (state.active_hover_playback_id) |id| {
            app.stopSound(id);
            state.active_hover_playback_id = null;
        }
        state.active_hover_audio = null;
    }

    const zpath = state.allocator.dupeZ(u8, item.full_path) catch return;
    defer state.allocator.free(zpath);

    if (app.playAudioStream(zpath)) |playback_id| {
        state.active_hover_audio = item.full_path;
        state.active_hover_playback_id = playback_id;
    }
}

fn isImagePath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "__MACOSX") != null) return false;
    if (std.mem.indexOf(u8, path, "$RECYCLE.BIN") != null) return false;

    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;

    return std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or
        std.ascii.eqlIgnoreCase(ext, ".bmp") or
        std.ascii.eqlIgnoreCase(ext, ".gif") or
        std.ascii.eqlIgnoreCase(ext, ".tga") or
        std.ascii.eqlIgnoreCase(ext, ".psd") or
        std.ascii.eqlIgnoreCase(ext, ".pic");
}

fn fmtTextureState(state: anytype) []const u8 {
    return switch (state) {
        .missing => "missing",
        .decoding => "decoding",
        .ready => "ready",
    };
}

fn onSearchResultsReady(ctx: ?*anyopaque) void {
    const ui: *AppUIContext = @ptrCast(@alignCast(ctx.?));
    ui.postExternalMessage(.{ .id = AppMsg.results_ready });
    glfw.postEmptyEvent();
}

fn onOverlayHotkey(user_ptr: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(user_ptr.?));
    const currently_visible = app.isVisible();

    if (!currently_visible) {
        app.backend.centerOnPrimaryMonitor(@intCast(WIN_W), @intCast(WIN_H));
    }

    app.setVisibility(!currently_visible);
}

fn submitQueryFromInput(ui: *AppUIContext, state: *AppState) void {
    const search = state.search orelse return;

    const raw = ui.getInputText(NodeIds.search_input) orelse return;
    const query = std.mem.trim(u8, raw, " \t\r\n");
    search.submitQuery(query) catch |err| {
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Query submit failed: {s}", .{@errorName(err)}) catch "Query submit failed";
        setStatus(state, line);
    };
}

fn refreshResults(app: *App) !void {
    const state = &app.state;
    const search = state.search orelse return;

    const snapshot = try search.copyLatestResults(state.allocator, MAX_UI_RESULTS);

    clearResults(app);
    state.results = snapshot;
    state.total_hits = search.latestTotalHits();

    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "Showing {d} of {d} matches",
        .{ state.results.len, state.total_hits },
    ) catch "Search results updated";
    setStatus(state, line);
    queueImagePreviews(app);

    const debug_count = @min(state.results.len, 20);
    for (state.results[0..debug_count]) |item| {
        if (item.is_folder or !isImagePath(item.full_path)) {
            continue;
        }
    }
}

fn build(ui: *AppUIContext, state: *const AppState) !*AppNode {
    const font = state.font;

    const BG: [4]f32 = comptime Color.parse("oklch(50% 0.1 270 / 0.95)");
    const PANEL: [4]f32 = comptime Color.parse("oklch(45% 0.1 270 / 0.95)");
    const PANEL_ALT: [4]f32 = comptime Color.parse("oklch(40% 0.1 270 / 0.95)");
    const INPUT_BG: [4]f32 = comptime Color.parse("oklch(50% 0.1 260 / 0.95)");
    const TEXT: [4]f32 = comptime Color.parse("oklch(80% 0.1 270 / 0.95)");
    const DIM: [4]f32 = comptime Color.parse("oklch(70% 0.1 270 / 0.95)");
    const EDGE: [4]f32 = comptime Color.parse("oklch(60% 0.1 270 / 0.95)");

    const header = try ui.ux().div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.flex_row,
            tw.justify_between,
            tw.items_center,
            tw.p_xy_px(16, 12),
            tw.bg_value(PANEL),
            tw.border_b_value(2, EDGE),
        }),
        .children = &.{
            try ui.ux().text(.{
                .content = "Everything Search Overlay",
                .font = font,
                .style = tw.style(.{ tw.text_color_value(TEXT), tw.pointer_events_none }),
            }),
            try ui.ux().text(.{
                .content = "Ctrl + Shift + Space",
                .font = font,
                .style = tw.style(.{ tw.text_color_value(DIM), tw.pointer_events_none }),
            }),
        },
    });

    const search_input = try ui.ux().textInput(.{
        .id = NodeIds.search_input,
        .style = tw.style(.{
            tw.w_full,
            tw.h(40),
            tw.p_xy_px(12, 9),
            tw.bg_value(INPUT_BG),
            tw.text_color_value(TEXT),
            tw.rounded(8),
            tw.border_value(2, EDGE),
        }),
        .font = font,
        .events = &.{
            .{ .event = .key_down, .msg = .search_changed },
            .{ .event = .text_input, .msg = .search_changed },
        },
    });

    const search_row = try ui.ux().div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.flex_row,
            tw.gap_px(8),
            tw.p_each_px(12, 14, 8, 14),
            tw.bg_value(PANEL_ALT),
            tw.border_b_value(1, EDGE),
        }),
        .children = &.{search_input},
    });

    const results_area: *AppNode = if (state.results.len == 0)
        try ui.ux().div(.{
            .id = NodeIds.results_scroller,
            .style = tw.style(.{
                tw.w_full,
                tw.grow_1,
                tw.flex_col,
                tw.bg_value(BG),
            }),
            .children = &.{
                try ui.ux().text(.{
                    .content = "No results yet. Start typing to search.",
                    .font = font,
                    .style = tw.style(.{
                        tw.text_color_value(DIM),
                        tw.p_each_px(12, 14, 8, 14),
                        tw.pointer_events_none,
                    }),
                }),
            },
        })
    else blk: {
        var rows = std.ArrayList(?*AppNode).empty;
        const arena = ui.build_arena.allocator();
        try rows.ensureTotalCapacity(arena, state.results.len);

        const row_ctx = ResultListContext{
            .state = state,
            .font = font,
        };

        for (0..state.results.len) |index| {
            try rows.append(arena, try buildResultRow(ui, row_ctx, index));
        }

        break :blk try ui.ux().div(.{
            .id = NodeIds.results_scroller,
            .style = tw.style(.{
                tw.w_full,
                tw.grow_1,
                tw.flex_col,
                tw.overflow_y_scroll,
                tw.bg_value(BG),
            }),
            .children = rows.items,
        });
    };

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.size_full,
            tw.flex_col,
            tw.bg_value(comptime Color.parse("oklch(0% 0 0 / 0)")),
            tw.rounded(4),
            tw.overflow_hidden,
            tw.opacity(0.95),
        }),
        .children = &.{ header, search_row, results_area },
    });
}

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    const ui = &app.ui;
    const state = &app.state;
    switch (msg.id) {
        .result_click => |index| {
            everything.openPath(state.results[index].full_path) catch {};
            return .none;
        },
        .result_hover_enter => |index| {
            playHoveredAudio(app, index);
            return .none;
        },
        .result_hover_exit => |index| {
            if (index < state.results.len) {
                if (state.active_hover_audio) |active| {
                    const item = state.results[index];
                    if (std.mem.eql(u8, active, item.full_path)) {
                        stopActiveHoverAudio(app);
                    }
                }
            }
            return .none;
        },
        .search_changed => {
            submitQueryFromInput(ui, state);
            return .none;
        },
        .results_ready => {
            refreshResults(app) catch |err| {
                var buf: [160]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "Result update failed: {s}", .{@errorName(err)}) catch "Result update failed";
                setStatus(state, line);
            };
            return .rebuild;
        },
        .hide_click => {
            stopActiveHoverAudio(app);
            app.setVisibility(false);
            return .none;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var app = try App.init(
        allocator,
        io,
        .{
            .title = "Everything Search Overlay",
            .width = WIN_W,
            .height = WIN_H,
            .borderless = true,
            .topmost = true,
            .transparent = true,
            .visible_on_start = true,
        },
        .{
            .allocator = allocator,
        },
        update,
    );
    defer app.deinit();
    defer deinitAppState(&app);

    app.state.preview_requested = std.StringHashMap(void).init(allocator);

    app.backend.configureAsOverlay();
    try app.registerGlobalHotkey(
        win32.MOD_CONTROL | win32.MOD_SHIFT | win32.MOD_NOREPEAT,
        VK_SPACE,
        onOverlayHotkey,
    );

    app.state.font = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    app.state.search = everything.SearchSubsystem.init(allocator, .{
        .max_results = @intCast(MAX_UI_RESULTS),
        .on_results_ready = onSearchResultsReady,
        .on_results_ready_ctx = &app.ui,
    }) catch |err| blk: {
        var buf: [512]u8 = undefined;
        const line = if (err == error.DllLoadFailed)
            std.fmt.bufPrint(
                &buf,
                "Everything integration unavailable: DllLoadFailed (expected SDK DLL at {s})",
                .{everything.bundledDllHintPath()},
            ) catch "Everything integration unavailable: DllLoadFailed"
        else
            std.fmt.bufPrint(
                &buf,
                "Everything integration unavailable: {s}",
                .{@errorName(err)},
            ) catch "Everything integration unavailable";
        setStatus(&app.state, line);
        break :blk null;
    };

    if (app.state.search != null) {
        setStatus(&app.state, "Type in the input box to query Everything");
        app.state.search.?.submitQuery("") catch {};
    }

    try app.setRootBuilder(build);
    try app.run();
}
