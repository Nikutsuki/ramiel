const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const dupeMessageBinding = @import("../node.zig").dupeMessageBinding;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;

pub fn CheckboxParams(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        checked: bool,
        on_toggle: MessageT,

        style: layout.Style = .{},
        label: ?[]const u8 = null,
        font: ?*FontData = null,
        label_style: layout.Style = .{},
        box: BoxStyle = .{},
    };
}

pub const BoxStyle = struct {
    style: layout.Style = .{},
    active_color: ?layout.Color = null,
    inactive_color: ?layout.Color = null,
};

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    params: CheckboxParams(MessageT),
) !*Node(MessageT) {
    const tokens = ctx.active_theme.tokens;

    var box_style = params.box.style;
    switch (box_style.width) {
        .Auto => box_style.width = .{ .exact = 20.0 },
        else => {},
    }
    switch (box_style.height) {
        .Auto => box_style.height = .{ .exact = 20.0 },
        else => {},
    }
    if (!box_style.border.hasAny()) {
        box_style.border = layout.Border.all(2.0, tokens.border_subtle);
    }
    if (!box_style.corner_radius.hasAny()) {
        box_style.corner_radius = layout.CornerRadius.all(4.0);
    }

    const active_color = params.box.active_color orelse tokens.action_default;
    const inactive_color = params.box.inactive_color orelse tokens.bg_surface;

    box_style.background_color = if (params.checked) active_color else inactive_color;
    box_style.pointer_events = .none;

    const box_node = try ctx.div(.{
        .id = deriveChildId(params.base_id, "box"),
        .style = box_style,
    });

    var children: [2]?*Node(MessageT) = .{ box_node, null };
    if (params.label) |label| {
        if (params.font) |font| {
            var label_style = params.label_style;
            if (label_style.margin.left == 0.0) label_style.margin.left = 8.0;
            label_style.pointer_events = .none;
            children[1] = try ctx.text(.{
                .id = deriveChildId(params.base_id, "label"),
                .content = label,
                .font = font,
                .style = label_style,
            });
        }
    }

    var container_style = params.style;
    container_style.direction = .Row;
    container_style.align_items = .Center;
    container_style.cursor = .pointer;

    const alloc = ctx.build_arena.allocator();
    const click_b = dupeMessageBinding(MessageT, .click, params.on_toggle);
    const events = try alloc.dupe(types.EventBinding(MessageT), &.{click_b});

    return ctx.div(.{
        .id = deriveChildId(params.base_id, "root"),
        .style = container_style,
        .events = events,
        .children = children[0..],
    });
}
