const std = @import("std");
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const Node = @import("../ui/node.zig").Node;
const DevToolsState = @import("state.zig").DevToolsState;

pub fn TabModule(comptime MessageT: type) type {
    return struct {
        context: *anyopaque,
        name: []const u8,
        onFrame: *const fn (ctx: *anyopaque, delta_time_s: f64, state: *DevToolsState(MessageT)) void,
        buildTabUI: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            state: *const DevToolsState(MessageT),
            font: *FontData,
        ) anyerror!*Node(MessageT),
    };
}
