const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const dupeMessageBinding = @import("../node.zig").dupeMessageBinding;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;

pub const RingStyle = struct {
    style: layout.Style = .{},
    active_color: ?layout.Color = null,
    inactive_color: ?layout.Color = null,
};

pub const DotStyle = struct {
    style: layout.Style = .{},
    color: ?layout.Color = null,
};

pub fn RadioParams(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        selected: bool,
        on_select: MessageT,

        style: layout.Style = .{},
        label: ?[]const u8 = null,
        font: ?*FontData = null,
        label_style: layout.Style = .{},
        ring: RingStyle = .{},
        dot: DotStyle = .{},
    };
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    params: RadioParams(MessageT),
) !*Node(MessageT) {
    const tokens = ctx.active_theme.tokens;

    var ring_style = params.ring.style;
    switch (ring_style.width) {
        .Auto => ring_style.width = .{ .exact = 20.0 },
        else => {},
    }
    switch (ring_style.height) {
        .Auto => ring_style.height = .{ .exact = 20.0 },
        else => {},
    }
    ring_style.direction = .Row;
    ring_style.align_items = .Center;
    ring_style.justify_content = .Center;
    if (!ring_style.border.hasAny()) {
        ring_style.border = layout.Border.all(2.0, tokens.border_subtle);
    }
    if (!ring_style.corner_radius.hasAny()) {
        ring_style.corner_radius = layout.CornerRadius.all(10.0);
    }
    ring_style.background_color = params.ring.inactive_color orelse tokens.bg_surface;
    ring_style.pointer_events = .none;

    var dot_style = params.dot.style;
    switch (dot_style.width) {
        .Auto => dot_style.width = .{ .exact = 10.0 },
        else => {},
    }
    switch (dot_style.height) {
        .Auto => dot_style.height = .{ .exact = 10.0 },
        else => {},
    }
    if (!dot_style.corner_radius.hasAny()) {
        dot_style.corner_radius = layout.CornerRadius.all(5.0);
    }
    if (!dot_style.transition.property.hasAny()) {
        dot_style.transition = ring_style.transition;
    }

    const active_color = params.ring.active_color orelse tokens.action_default;
    const dot_fill = params.dot.color orelse active_color;
    dot_style.background_color = if (params.selected) dot_fill else layout.Color.transparent;
    dot_style.pointer_events = .none;

    const ring_node = try ctx.div(.{
        .id = deriveChildId(params.base_id, "ring"),
        .style = ring_style,
        .children = &.{
            try ctx.div(.{
                .id = deriveChildId(params.base_id, "dot"),
                .style = dot_style,
            }),
        },
    });

    var children: [2]?*Node(MessageT) = .{ ring_node, null };
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

    const alloc = ctx.build_arena.allocator();
    const click_b = dupeMessageBinding(MessageT, .click, params.on_select);
    const events = try alloc.dupe(types.EventBinding(MessageT), &.{click_b});

    return ctx.div(.{
        .id = deriveChildId(params.base_id, "root"),
        .style = container_style,
        .events = events,
        .children = children[0..],
    });
}
