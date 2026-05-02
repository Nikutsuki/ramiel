const std = @import("std");
const Node = @import("../node.zig").Node;
const Style = @import("../layout.zig").Style;
const UIContext = @import("../context.zig").UIContext;
const types = @import("../types.zig");
const VideoPlayback = @import("../../video/playback.zig").VideoPlayback;
const video = @import("video.zig");

pub const AnimatedMediaDescriptor = struct {
    style: Style = .{},
};

pub fn AnimatedMediaContext(comptime MessageT: type) type {
    return struct {
        on_click: ?MessageT = null,
    };
}

pub fn build(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    playback: *VideoPlayback,
    desc: AnimatedMediaDescriptor,
    logic: AnimatedMediaContext(MessageT),
) !*Node(MessageT) {
    playback.setVolume(0.0);
    if (playback.state == .paused or playback.state == .ended) {
        playback.play();
    }

    var root_events: ?[]const types.EventBinding(MessageT) = null;
    if (logic.on_click) |click_msg| {
        const alloc = ui.build_arena.allocator();
        const events = try alloc.alloc(types.EventBinding(MessageT), 1);
        events[0] = .{ .event = .click, .msg = click_msg };
        root_events = events;
    }

    const video_node = try video.build(MessageT, ui, playback, desc.style);

    if (root_events) |events| {
        video_node.events = events;
    }

    return video_node;
}
