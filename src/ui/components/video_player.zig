const std = @import("std");
const Node = @import("../node.zig").Node;
const Style = @import("../layout.zig").Style;
const UIContext = @import("../context.zig").UIContext;
const types = @import("../types.zig");
const FontData = @import("../../renderer/font/font_registry.zig").FontData;
const VideoPlayback = @import("../../video/playback.zig").VideoPlayback;
const video = @import("video.zig");
const slider = @import("slider.zig");
const icon = @import("icon.zig");
const deriveChildId = @import("id.zig").deriveChildId;
const icon_id = @import("../../renderer/icon/id.zig");
const hashId = icon_id.hashId;

pub const CoreIcons = struct {
    pub const Play = hashId("ramiel:core:play");
    pub const Pause = hashId("ramiel:core:pause");
    pub const Volume = hashId("ramiel:core:volume");
    pub const VolumeOff = hashId("ramiel:core:volume_off");
};

pub const VideoPlayerDescriptor = struct {
    base_id: types.NodeId,
    style: Style = .{},
    font: *FontData,
    controls_background_style: Style = .{
        .flex_grow = 1.0,
        .margin = .{
            .left = 16.0,
            .right = 16.0,
        },
        .height = .{ .exact = 72.0 },
        .direction = .Row,
        .align_items = .Center,
        .gap = 14.0,
        .padding = .all(12.0),
        .background_color = .{ 0.08, 0.09, 0.12, 0.85 },
        .corner_radius = .all(8.0),
    },
    controls_icon_button_style: Style = .{
        .width = .{ .exact = 36.0 },
        .height = .{ .exact = 36.0 },
        .align_items = .Center,
        .justify_content = .Center,
        .background_color = .{ 0.20, 0.22, 0.30, 1.0 },
        .hover_color = .{ 0.25, 0.28, 0.38, 1.0 },
        .corner_radius = .all(6.0),
        .cursor = .pointer,
    },
    controls_icon_style: Style = .{
        .width = .{ .exact = 18.0 },
        .height = .{ .exact = 18.0 },
    },
    slider_descriptor: slider.SliderDescriptor = .{},
    progress_slider_descriptor: ?slider.SliderDescriptor = null,
    volume_slider_descriptor: ?slider.SliderDescriptor = null,
    volume_group_style: Style = .{
        .width = .{ .exact = 196.0 },
        .direction = .Row,
        .align_items = .Center,
        .gap = 10.0,
    },
    play_icon_id: u32 = CoreIcons.Play,
    pause_icon_id: u32 = CoreIcons.Pause,
    volume_icon_id: u32 = CoreIcons.Volume,
    volume_off_icon_id: u32 = CoreIcons.VolumeOff,
    default_unmute_volume: f32 = 1.0,
};

pub fn VideoPlayerContext(comptime MessageT: type) type {
    return struct {
        playback: *const VideoPlayback,
        progress: f32,
        volume: f32,
        is_hovered: bool,
        on_play_toggle: MessageT,
        on_seek: *const fn (f32, ?*const anyopaque) MessageT,
        on_volume: *const fn (f32, ?*const anyopaque) MessageT,
        on_seek_volume_userdata: ?*const anyopaque = null,
        previous_volume: ?f32 = null,
        on_hover_enter: MessageT,
        on_hover_leave: MessageT,
    };
}

pub fn build(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    desc: VideoPlayerDescriptor,
    logic: VideoPlayerContext(MessageT),
) !*Node(MessageT) {
    const normalized_progress = std.math.clamp(logic.progress, 0.0, 1.0);
    const normalized_volume = std.math.clamp(logic.volume, 0.0, 1.0);
    const restore_volume = std.math.clamp(logic.previous_volume orelse desc.default_unmute_volume, 0.0, 1.0);
    const volume_toggle_target = if (normalized_volume <= 0.0001)
        if (restore_volume <= 0.0001) 1.0 else restore_volume
    else
        0.0;
    const play_toggle_icon_id = if (logic.playback.state == .playing) desc.pause_icon_id else desc.play_icon_id;
    const volume_toggle_icon_id = if (normalized_volume <= 0.0001) desc.volume_off_icon_id else desc.volume_icon_id;
    const base = desc.base_id;
    const alloc = ui.build_arena.allocator();
    var children = std.ArrayList(?*Node(MessageT)).empty;

    const video_node = try video.build(MessageT, ui, logic.playback, .{
        .width = .Full,
        .height = .Full,
        .flex_grow = 1.0,
        .corner_radius = .all(8.0),
        .object_fit = desc.style.object_fit, // Ensure the video node uses the same object_fit as the root for consistent layout
    });
    video_node.id = deriveChildId(base, "video_node_bg");
    try children.append(alloc, video_node);

    const play_icon = try icon.build(MessageT, ui, .{
        .icon_id = play_toggle_icon_id,
        .intrinsic_size = .{ 18.0, 18.0 },
        .style = desc.controls_icon_style,
    });
    const play_btn = try ui.div(.{
        .id = deriveChildId(base, "play_btn"),
        .style = desc.controls_icon_button_style,
        .events = &.{.{ .event = .click, .msg = logic.on_play_toggle }},
        .children = &.{play_icon},
    });

    if (logic.is_hovered) {
        var progress_slider_visuals = desc.progress_slider_descriptor orelse desc.slider_descriptor;
        progress_slider_visuals.track.style.flex_grow = 1.0;
        if (progress_slider_visuals.track.style.width == .Auto) {
            progress_slider_visuals.track.style.width = .Full;
        }
        const progress_slider = try slider.build(MessageT, ui, .{
            .base_id = deriveChildId(base, "progress_slider"),
            .value = normalized_progress,
            .on_change = logic.on_seek,
            .userdata = logic.on_seek_volume_userdata,
            .track = progress_slider_visuals.track,
            .fill = progress_slider_visuals.fill,
            .handle = progress_slider_visuals.handle,
        });

        const volume_icon = try icon.build(MessageT, ui, .{
            .icon_id = volume_toggle_icon_id,
            .intrinsic_size = .{ 18.0, 18.0 },
            .style = desc.controls_icon_style,
        });
        const volume_btn = try ui.div(.{
            .id = deriveChildId(base, "volume_btn"),
            .style = desc.controls_icon_button_style,
            .events = &.{.{ .event = .click, .msg = logic.on_volume(volume_toggle_target, logic.on_seek_volume_userdata) }},
            .children = &.{volume_icon},
        });
        var volume_slider_visuals = desc.volume_slider_descriptor orelse desc.slider_descriptor;
        volume_slider_visuals.track.style.flex_grow = 1.0;
        if (volume_slider_visuals.track.style.width == .Auto) {
            volume_slider_visuals.track.style.width = .Full;
        }
        const volume_slider = try slider.build(MessageT, ui, .{
            .base_id = deriveChildId(base, "volume_slider"),
            .value = normalized_volume,
            .on_change = logic.on_volume,
            .userdata = logic.on_seek_volume_userdata,
            .track = volume_slider_visuals.track,
            .fill = volume_slider_visuals.fill,
            .handle = volume_slider_visuals.handle,
        });
        const volume_group = try ui.div(.{
            .id = deriveChildId(base, "volume_group"),
            .style = desc.volume_group_style,
            .children = &.{ volume_btn, volume_slider },
        });

        const controls_bg = try ui.div(.{
            .id = deriveChildId(base, "controls_bg"),
            .style = desc.controls_background_style,
            .events = &.{
                .{ .event = .hover_enter, .msg = logic.on_hover_enter },
            },
            .children = &.{ play_btn, progress_slider, volume_group },
        });

        const controls_wrapper = try ui.div(.{
            .id = deriveChildId(base, "controls_wrapper"),
            .style = .{
                .position = .absolute,
                .left = 0.0,
                .right = 0.0,
                .bottom = 16.0,
                .direction = .Row,
            },
            .events = &.{
                .{ .event = .hover_enter, .msg = logic.on_hover_enter },
            },
            .children = &.{controls_bg},
        });
        try children.append(alloc, controls_wrapper);
    }

    var root_style = desc.style;
    root_style.position = .relative;
    root_style.overflow_x = .hidden;
    root_style.overflow_y = .hidden;

    const root_events = try alloc.dupe(types.EventBinding(MessageT), &.{
        .{ .event = .hover_enter, .msg = logic.on_hover_enter },
        .{ .event = .hover_exit, .msg = logic.on_hover_leave },
    });

    return ui.div(.{
        .id = base,
        .style = root_style,
        .events = root_events,
        .children = try children.toOwnedSlice(alloc),
    });
}
