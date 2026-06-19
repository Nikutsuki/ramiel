const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const dupeMessageBinding = @import("../node.zig").dupeMessageBinding;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;

pub const TriggerStyle = struct { style: layout.Style = .{} };
pub const MenuStyle = struct { style: layout.Style = .{} };
pub const ItemStyle = struct {
    style: layout.Style = .{},
    active_color: ?layout.Color = null,
    hover_color: ?layout.Color = null,
};

pub fn DropdownParams(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        is_open: bool,
        active_index: usize,
        options: []const []const u8,
        on_toggle: *const fn (bool, ?*const anyopaque) MessageT,
        on_select: *const fn (usize, ?*const anyopaque) MessageT,
        userdata: ?*const anyopaque = null,

        font: ?*FontData = null,
        style: layout.Style = .{},
        trigger: TriggerStyle = .{},
        menu: MenuStyle = .{},
        item: ItemStyle = .{},
    };
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    params: DropdownParams(MessageT),
) !*Node(MessageT) {
    const tokens = ctx.active_theme.tokens;
    const alloc = ctx.build_arena.allocator();
    const trigger_id = deriveChildId(params.base_id, "trigger");

    var trigger_style = params.trigger.style;
    if (trigger_style.background_color.a == 0) {
        trigger_style.background_color = tokens.bg_surface;
    }
    if (!trigger_style.border.hasAny()) {
        trigger_style.border = layout.Border.all(1.0, tokens.border_subtle);
    }
    if (!trigger_style.corner_radius.hasAny()) {
        trigger_style.corner_radius = layout.CornerRadius.all(4.0);
    }
    if (trigger_style.padding.horizontal() == 0.0 and trigger_style.padding.vertical() == 0.0) {
        trigger_style.padding = layout.Spacing.all(8.0);
    }
    trigger_style.direction = .Row;
    trigger_style.align_items = .Center;
    trigger_style.justify_content = .SpaceBetween;
    trigger_style.cursor = .pointer;

    const toggle_event = dupeMessageBinding(MessageT, .click, params.on_toggle(!params.is_open, params.userdata));
    const trigger_events = try alloc.dupe(types.EventBinding(MessageT), &.{toggle_event});

    const active_label = if (params.options.len > 0 and params.active_index < params.options.len)
        params.options[params.active_index]
    else
        "";

    const trigger_text = try ctx.text(.{
        .id = deriveChildId(params.base_id, "trigger_text"),
        .content = active_label,
        .font = params.font,
        .style = .{
            .pointer_events = .none,
            .text_color = if (params.trigger.style.text_color.a == 0) tokens.text_main else params.trigger.style.text_color,
        },
    });

    const trigger_node = try ctx.div(.{
        .id = trigger_id,
        .style = trigger_style,
        .events = trigger_events,
        .children = &.{trigger_text},
    });

    var portal_node: ?*Node(MessageT) = null;
    if (params.is_open) {
        const backdrop_event = dupeMessageBinding(MessageT, .click, params.on_toggle(false, params.userdata));
        const backdrop_events = try alloc.dupe(types.EventBinding(MessageT), &.{backdrop_event});
        const backdrop = try ctx.div(.{
            .id = deriveChildId(params.base_id, "backdrop"),
            .style = .{
                .position = .absolute,
                .top = 0.0,
                .left = 0.0,
                .width = .Full,
                .height = .Full,
                .z_index = 999,
                .cursor = .default,
            },
            .events = backdrop_events,
        });

        var menu_style = params.menu.style;
        if (menu_style.background_color.a == 0) {
            menu_style.background_color = tokens.bg_surface;
        }
        if (!menu_style.border.hasAny()) {
            menu_style.border = layout.Border.all(1.0, tokens.border_subtle);
        }
        if (!menu_style.corner_radius.hasAny()) {
            menu_style.corner_radius = layout.CornerRadius.all(4.0);
        }
        menu_style.position = .anchored;
        menu_style.anchor_id = trigger_id;
        menu_style.z_index = 1000;
        menu_style.direction = .Column;

        const active_item_color = params.item.active_color orelse tokens.action_default;
        const hover_item_color = params.item.hover_color orelse tokens.action_hover;

        const menu_items = try alloc.alloc(?*Node(MessageT), params.options.len);
        for (params.options, 0..) |option, i| {
            var item_style = params.item.style;
            if (item_style.padding.horizontal() == 0.0 and item_style.padding.vertical() == 0.0) {
                item_style.padding = layout.Spacing.all(8.0);
            }
            item_style.cursor = .pointer;
            if (i == params.active_index) {
                item_style.background_color = active_item_color;
            }
            item_style.hover_color = hover_item_color;

            const select_event = dupeMessageBinding(MessageT, .click, params.on_select(i, params.userdata));
            const item_events = try alloc.dupe(types.EventBinding(MessageT), &.{select_event});

            var key_buf: [32]u8 = undefined;
            const text_key = try std.fmt.bufPrint(&key_buf, "opt-{d}", .{i});
            const item_text = try ctx.text(.{
                .id = deriveChildId(params.base_id, text_key),
                .content = option,
                .font = params.font,
                .style = .{
                    .pointer_events = .none,
                    .text_color = if (i == params.active_index) tokens.text_inverse else tokens.text_main,
                },
            });

            var container_key_buf: [48]u8 = undefined;
            const container_key = try std.fmt.bufPrint(&container_key_buf, "opt-container-{d}", .{i});
            menu_items[i] = try ctx.div(.{
                .id = deriveChildId(params.base_id, container_key),
                .style = item_style,
                .events = item_events,
                .children = &.{item_text},
            });
        }

        const menu_container = try ctx.div(.{
            .id = deriveChildId(params.base_id, "menu"),
            .style = menu_style,
            .children = menu_items,
        });

        portal_node = try ctx.portal(.{
            .id = deriveChildId(params.base_id, "portal"),
            .children = &.{ backdrop, menu_container },
        });
    }

    var root_style = params.style;
    root_style.direction = .Column;

    const root_children = if (portal_node) |p|
        try alloc.dupe(?*Node(MessageT), &.{ trigger_node, p })
    else
        try alloc.dupe(?*Node(MessageT), &.{trigger_node});

    return ctx.div(.{
        .id = deriveChildId(params.base_id, "root"),
        .style = root_style,
        .children = root_children,
    });
}
