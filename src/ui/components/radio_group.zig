const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const NodeId = @import("../types.zig").NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const radio_impl = @import("radio.zig");
const FontData = @import("../../renderer/font/font_registry.zig").FontData;

pub fn RadioGroupContext(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        active_index: usize,
        on_change: *const fn (usize, ?*const anyopaque) MessageT,
        userdata: ?*const anyopaque = null,
    };
}

pub const RadioGroupDescriptor = struct {
    options: []const []const u8,
    font: ?*FontData = null,
    direction: layout.FlexDirection = .Column,
    gap: f32 = 8.0,
    style: layout.Style = .{},
    item_style: layout.Style = .{},
    ring: struct {
        style: layout.Style = .{},
        active_color: ?layout.Color = null,
        inactive_color: ?layout.Color = null,
    } = .{},
    dot: struct {
        style: layout.Style = .{},
        color: ?layout.Color = null,
    } = .{},
};

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: RadioGroupContext(MessageT),
    visuals: RadioGroupDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    std.debug.assert(visuals.options.len > 0);

    const children = try alloc.alloc(?*Node(MessageT), visuals.options.len);

    for (visuals.options, 0..) |label, i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "item-{d}", .{i});
        children[i] = try radio_impl.build(MessageT, ctx, .{
            .base_id = deriveChildId(logic.base_id, key),
            .selected = logic.active_index == i,
            .on_select = logic.on_change(i, logic.userdata),
            .label = label,
            .font = visuals.font,
            .style = visuals.item_style,
            .ring = .{
                .style = visuals.ring.style,
                .active_color = visuals.ring.active_color,
                .inactive_color = visuals.ring.inactive_color,
            },
            .dot = .{
                .style = visuals.dot.style,
                .color = visuals.dot.color,
            },
        });
    }

    var container_style = visuals.style;
    container_style.direction = visuals.direction;
    container_style.gap = visuals.gap;

    return ctx.div(.{
        .id = deriveChildId(logic.base_id, "root"),
        .style = container_style,
        .children = children,
    });
}
