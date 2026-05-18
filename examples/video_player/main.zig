const std = @import("std");
const lib = @import("ramiel");
const nfd = @import("nfd");
pub const tracy_impl = @import("tracy_impl");

const tw = lib.tw;
const UpdateAction = lib.UpdateAction;

const AppMessage = union(enum) {
    open_file,
    toggle_playback,
    seek: f32,
    set_volume: f32,
    set_hover: bool,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const NodeIds = lib.declareIds("examples.video_player", .{
    "open_button",
    "video_player",
}){};

const AppState = struct {
    video_instance: ?*lib.VideoPlayback = null,
    volume: f32 = 1.0,
    controls_hovered: bool = false,
    current_time_s: f64 = 0.0,
    ui_progress_override: ?f32 = null,
};

const App = lib.Application(AppState, AppMessage);

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const ux = ui.ux();
    const components = ui.components();

    const btn_style = tw.style(.{
        tw.p_px(4),
        tw.bg_value(.{ 0.20, 0.22, 0.30, 1.0 }),
        tw.hover_value(.{ 0.25, 0.28, 0.38, 1.0 }),
        tw.rounded(6.0),
        tw.cursor_pointer,
    });

    const open_btn = try ux.button(.{
        .id = NodeIds.open_button,
        .style = btn_style,
        .label = "Open Video",
        .on_click = .open_file,
    });

    const controls_bar = try ux.div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.h(64.0),
            tw.flex_row,
            tw.items_center,
            tw.justify_start,
            tw.p_px(16.0),
            tw.gap_px(12.0),
            tw.bg_value(.{ 0.12, 0.13, 0.18, 1.0 }),
        }),
        .children = &.{open_btn},
    });

    var video_children = std.ArrayList(?*AppNode).empty;
    if (state.video_instance) |vid| {
        const duration = vid.getDurationS();
        const progress = if (state.ui_progress_override) |override|
            override
        else if (duration > 0.0)
            std.math.clamp(@as(f32, @floatCast(state.current_time_s / duration)), 0.0, 1.0)
        else
            0.0;

        const player_node = try components.videoPlayer(.{
            .desc = .{
                .base_id = NodeIds.video_player,
                .style = tw.style(.{ tw.size_full, tw.object_contain }),
            },
            .logic = .{
                .playback = vid,
                .progress = progress,
                .volume = state.volume,
                .is_hovered = state.controls_hovered,
                .on_play_toggle = .toggle_playback,
                .on_seek = lib.bindTag(AppMessage, f32, .seek),
                .on_volume = lib.bindTag(AppMessage, f32, .set_volume),
                .on_hover_enter = .{ .set_hover = true },
                .on_hover_leave = .{ .set_hover = false },
            },
        });
        try video_children.append(ui.build_arena.allocator(), player_node);
    } else {
        const empty_text = try ux.text(.{
            .content = "No video loaded. Click 'Open Video' to select a file.",
            .style = tw.style(.{tw.text_color_value(.{ 0.5, 0.5, 0.5, 1.0 })}),
        });
        try video_children.append(ui.build_arena.allocator(), empty_text);
    }

    const video_area = try ux.div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.grow_1,
            tw.items_center,
            tw.justify_center,
            tw.p_px(24.0),
        }),
        .children = video_children.items,
    });

    return ux.div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.flex_col,
            tw.bg_value(.{ 0.08, 0.09, 0.12, 1.0 }),
        }),
        .children = &.{ controls_bar, video_area },
    });
}

fn tick(app: *App) UpdateAction {
    const state = &app.state;
    if (state.video_instance) |vid| {
        if (vid.isSeeking()) return .none;

        var latest_time: ?f64 = null;
        while (vid.time_telemetry.pop()) |t| {
            latest_time = t;
        }

        if (latest_time) |t| {
            if (state.ui_progress_override == null) {
                state.current_time_s = t;
                if (state.controls_hovered) return .rebuild;
            } else if (!vid.isSeeking()) {
                state.ui_progress_override = null;
            }
        }
    }
    return .none;
}

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    const state = &app.state;
    switch (msg.id) {
        .open_file => {
            if (msg.data != .mouse) return .none;
            const path = nfd.openFileDialog("mp4,mkv,webm,mov,avi", null) catch |err| {
                std.log.err("Failed to open file dialog: {}", .{err});
                return .none;
            } orelse return .none;
            defer nfd.freePath(path);

            if (state.video_instance) |old_vid| {
                app.video_manager.destroyPlayback(old_vid.id);
                state.video_instance = null;
            }

            state.video_instance = app.video_manager.createPlayback(path) catch |err| {
                std.log.err("Playback creation failed: {}", .{err});
                return .none;
            };

            if (state.video_instance) |vid| {
                state.volume = 1.0;
                vid.setVolume(state.volume);
                vid.play();
            }

            return .rebuild;
        },
        .toggle_playback => {
            if (msg.data != .mouse) return .none;

            if (state.video_instance) |vid| {
                if (vid.state == .playing) {
                    vid.pause();
                } else if (vid.state == .paused) {
                    vid.play();
                }
                return .rebuild;
            }
            return .none;
        },
        .seek => |normalized| {
            if (state.video_instance) |vid| {
                const duration = vid.getDurationS();
                if (duration > 0.0) {
                    state.ui_progress_override = std.math.clamp(normalized, 0.0, 1.0);
                    const target_s = @as(f64, normalized) * duration;
                    vid.seekTo(target_s);
                    return .rebuild;
                }
            }
            return .none;
        },
        .set_volume => |value| {
            const clamped = std.math.clamp(value, 0.0, 1.0);
            state.volume = clamped;
            if (state.video_instance) |vid| {
                vid.setVolume(clamped);
            }
            return .rebuild;
        },
        .set_hover => |hovered| {
            if (state.controls_hovered == hovered) return .none;
            state.controls_hovered = hovered;
            return .rebuild;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var app = try App.init(
        rt.allocator(),
        io,
        .{ .title = "Video Player Subsystem", .width = 1280, .height = 720 },
        AppState{},
        update,
    );
    defer app.deinit();

    app.tick_fn = tick;

    _ = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    try app.setRootBuilder(build);
    try app.run();
}
