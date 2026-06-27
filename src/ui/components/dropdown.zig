//! Single-selection dropdown: trigger label + anchored popup menu in a portal.
//!
//! **Stateless** - caller owns `is_open`, `active_index`, and `options`; re-pass them each rebuild.
//!
//! **Callbacks** (`on_toggle`, `on_select`) return `MessageT` values that are embedded into click
//! bindings at build time. `on_select(i, …)` is invoked once per row during build with that row's
//! index; handle selection in your message reducer, not inside the callback.
//!
//! **Scrolling** - all options are materialized as rows. For long lists set `menu.style` with
//! `max_height` + `overflow_y = .scroll` (e.g. `tw.max_h(240)` + `tw.overflow_y_scroll`). For very
//! large or searchable lists use `virtual_list.zig` instead.
//!
//! **Open layout** - when `is_open`, a portal renders a full-screen backdrop (click closes) and a
//! menu with `position = .anchored` below the trigger. See `examples/components_showcase/main.zig`.
const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const dupeMessageBinding = @import("../node.zig").dupeMessageBinding;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;
const icon_impl = @import("icon.zig");
const hashIconId = @import("../../renderer/icon/id.zig").hashId;

/// Built-in chevron icon (shared with the tree expander). Points down; rotate 180° to flip it up.
pub const arrow_icon_id = hashIconId("ramiel:core:arrow_dropdown");

/// Optional indicator chevron rendered inside the trigger. Disabled by default so existing
/// callers (and callers without an icon resolver wired) are unaffected. To right-align it, set
/// `tw.justify_between` on the trigger style; to space it from the label, set `arrow.style` margin.
pub const ArrowStyle = struct {
    /// Render the chevron in the trigger row.
    enabled: bool = false,
    /// Icon to draw; defaults to the built-in chevron-down.
    icon_id: u32 = arrow_icon_id,
    /// Square render size in px.
    size: f32 = 16.0,
    /// Tint; unset → follows the trigger `text_color`, else opaque white.
    tint: ?[4]f32 = null,
    /// Rotation (radians) applied while closed / open.
    closed_rotation: f32 = 0.0,
    open_rotation: f32 = std.math.pi,
    /// Optional smooth rotate animation (e.g. `.forTransform(150)`). Null = snap instantly.
    transition: ?layout.TransitionStyle = null,
    /// Extra style merged onto the icon node (margins, etc.); size/rotation/transition are set here.
    style: layout.Style = .{},
};

pub const TriggerStyle = struct { style: layout.Style = .{} };
pub const MenuStyle = struct { style: layout.Style = .{} };
pub const ItemStyle = struct {
    style: layout.Style = .{},
    active_color: ?layout.Color = null,
    hover_color: ?layout.Color = null,
    /// Row label color for non-active rows; unset leaves the text Style default.
    text_color: ?layout.Color = null,
    /// Row label color for the active row; unset leaves the text Style default.
    active_text_color: ?layout.Color = null,
};

/// Parameters for `build`. All fields are read each frame; nothing is stored inside the component.
pub fn DropdownParams(comptime MessageT: type) type {
    return struct {
        /// Stable id; child nodes use `deriveChildId(base_id, …)`.
        base_id: NodeId,
        /// When true the portal (backdrop + menu) is rendered.
        is_open: bool,
        /// Index into `options` for the trigger label and active row highlight.
        active_index: usize,
        /// Row labels. Trigger shows `options[active_index]`; each entry becomes one menu row.
        options: []const []const u8,
        /// `fn(open, userdata) MessageT` - trigger click sends `!is_open`; backdrop sends `false`.
        on_toggle: *const fn (bool, ?*const anyopaque) MessageT,
        /// `fn(index, userdata) MessageT` - called at build time per row; `index` is the row number.
        on_select: *const fn (usize, ?*const anyopaque) MessageT,
        userdata: ?*const anyopaque = null,

        font: ?*FontData = null,
        /// Root wrapper style (`direction` is forced to `.Column`).
        style: layout.Style = .{},
        /// Closed-state button (`TriggerStyle.style`).
        trigger: TriggerStyle = .{},
        /// Open popup panel (`MenuStyle.style`). Set `max_height` + `overflow_y = .scroll` here for long lists.
        menu: MenuStyle = .{},
        /// Per-row styling and active/hover background overrides.
        item: ItemStyle = .{},
        /// Optional chevron indicator in the trigger; rotates between closed/open states.
        arrow: ArrowStyle = .{},
    };
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    params: DropdownParams(MessageT),
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    const trigger_id = deriveChildId(params.base_id, "trigger");

    var trigger_style = params.trigger.style;
    trigger_style.direction = .Row;
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
            .white_space = .NoWrap,
            .text_color = params.trigger.style.text_color,
        },
    });

    const trigger_children = if (params.arrow.enabled) blk: {
        var arrow_style = params.arrow.style;
        arrow_style.width = .{ .exact = params.arrow.size };
        arrow_style.height = .{ .exact = params.arrow.size };
        arrow_style.pointer_events = .none;
        arrow_style.transform.rotate = if (params.is_open)
            params.arrow.open_rotation
        else
            params.arrow.closed_rotation;
        if (params.arrow.transition) |t| arrow_style.transition = t;

        const arrow_tint = params.arrow.tint orelse blk_tint: {
            const tc = params.trigger.style.text_color;
            break :blk_tint if (tc.a != 0) tc.toArray() else .{ 1.0, 1.0, 1.0, 1.0 };
        };

        const arrow_icon = try icon_impl.build(MessageT, ctx, .{
            .icon_id = params.arrow.icon_id,
            .intrinsic_size = .{ params.arrow.size, params.arrow.size },
            .style = arrow_style,
            .tint = arrow_tint,
        });
        break :blk try alloc.dupe(?*Node(MessageT), &.{ trigger_text, arrow_icon });
    } else try alloc.dupe(?*Node(MessageT), &.{trigger_text});

    const trigger_node = try ctx.div(.{
        .id = trigger_id,
        .style = trigger_style,
        .events = trigger_events,
        .children = trigger_children,
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
        menu_style.position = .anchored;
        menu_style.anchor_id = trigger_id;
        menu_style.z_index = 1000;
        menu_style.direction = .Column;

        const menu_items = try alloc.alloc(?*Node(MessageT), params.options.len);
        for (params.options, 0..) |option, i| {
            var item_style = params.item.style;
            item_style.cursor = .pointer;
            if (i == params.active_index) {
                if (params.item.active_color) |c| item_style.background_color = c;
            }
            if (params.item.hover_color) |c| item_style.hover_color = c;

            const select_event = dupeMessageBinding(MessageT, .click, params.on_select(i, params.userdata));
            const item_events = try alloc.dupe(types.EventBinding(MessageT), &.{select_event});

            var key_buf: [32]u8 = undefined;
            const text_key = try std.fmt.bufPrint(&key_buf, "opt-{d}", .{i});
            const item_text = try ctx.text(.{
                .id = deriveChildId(params.base_id, text_key),
                .content = option,
                .font = params.font,
                .style = blk: {
                    var s: layout.Style = .{ .pointer_events = .none, .white_space = .NoWrap };
                    const c = if (i == params.active_index)
                        (params.item.active_text_color orelse params.item.text_color)
                    else
                        params.item.text_color;
                    if (c) |col| s.text_color = col;
                    break :blk s;
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
