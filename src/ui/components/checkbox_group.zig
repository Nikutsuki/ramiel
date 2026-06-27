const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const NodeId = @import("../types.zig").NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const checkbox_impl = @import("checkbox.zig");
const FontData = @import("../../renderer/font/font_registry.zig").FontData;

pub fn CheckboxGroupContext(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        checked: []const bool,
        on_toggle: *const fn (usize, bool) MessageT,
    };
}

pub const CheckboxGroupDescriptor = struct {
    options: []const []const u8,
    font: ?*FontData = null,
    direction: layout.FlexDirection = .Column,
    gap: f32 = 8.0,
    style: layout.Style = .{},
    item_style: layout.Style = .{},
    label_style: layout.Style = .{},
    box: struct {
        style: layout.Style = .{},
        active_color: ?layout.Color = null,
        inactive_color: ?layout.Color = null,
    } = .{},
};

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: CheckboxGroupContext(MessageT),
    visuals: CheckboxGroupDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    std.debug.assert(visuals.options.len > 0);
    std.debug.assert(logic.checked.len == visuals.options.len);

    const children = try alloc.alloc(?*Node(MessageT), visuals.options.len);

    for (visuals.options, 0..) |label, i| {
        const now = logic.checked[i];
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "item-{d}", .{i});
        children[i] = try checkbox_impl.build(MessageT, ctx, .{
            .base_id = deriveChildId(logic.base_id, key),
            .checked = now,
            .on_toggle = logic.on_toggle(i, !now),
            .label = label,
            .font = visuals.font,
            .style = visuals.item_style,
            .label_style = visuals.label_style,
            .box = .{
                .style = visuals.box.style,
                .active_color = visuals.box.active_color,
                .inactive_color = visuals.box.inactive_color,
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
