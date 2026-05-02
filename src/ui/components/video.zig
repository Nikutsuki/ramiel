const std = @import("std");
const Node = @import("../node.zig").Node;
const Style = @import("../layout.zig").Style;
const UIContext = @import("../context.zig").UIContext;
const VideoPlayback = @import("../../video/playback.zig").VideoPlayback;

pub fn build(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    playback: *const VideoPlayback,
    style: Style,
) !*Node(MessageT) {
    const n = try ui.createNode();
    n.style = style;

    n.payload = .{
        .video = .{
            .playback = playback,
            .tint = .{ 1.0, 1.0, 1.0, 1.0 },
            .custom_params = .{ 0.0, 0.0, 0.0, 0.0 },
        },
    };
    return n;
}
