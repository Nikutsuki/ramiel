const std = @import("std");
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const layout = @import("../ui/layout.zig");
const Style = layout.Style;
const Border = layout.Border;
const Spacing = layout.Spacing;
const Size = layout.Size;
const Node = @import("../ui/node.zig").Node;
const types = @import("../ui/types.zig");
const EventBinding = types.EventBinding;
const EventData = types.EventData;
const EventLayoutSnapshot = types.EventLayoutSnapshot;
const state_mod = @import("state.zig");
const PayloadKind = state_mod.PayloadKind;

const col_text = [4]f32{ 0.86, 0.86, 0.88, 1.0 };
const col_text_dim = [4]f32{ 0.58, 0.58, 0.62, 1.0 };
const col_text_bright = [4]f32{ 0.97, 0.97, 0.98, 1.0 };
const col_accent = [4]f32{ 0.45, 0.68, 1.0, 1.0 };
const col_panel = [4]f32{ 0.11, 0.11, 0.13, 0.97 };
const col_row = [4]f32{ 0.16, 0.16, 0.19, 1.0 };
const col_border = [4]f32{ 0.28, 0.28, 0.32, 1.0 };

const sz_label: f32 = 12.0;
const sz_value: f32 = 12.0;
const sz_title: f32 = 13.0;
const sz_big: f32 = 30.0;

pub fn buildDevToolsPanel(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *state_mod.DevToolsState(MessageT),
    font: *FontData,
    retained_root: *Node(MessageT),
) !*Node(MessageT) {
    if (!state.is_active) {
        return createNode(MessageT, allocator, .fragment);
    }
    devtoolsStateSlot(MessageT).* = state;

    const panel = try createNode(MessageT, allocator, .container);
    panel.style = .{
        .position = .absolute,
        .top = 0.0,
        .right = 0.0,
        .width = .{ .exact = state.panel_width },
        .height = .Full,
        .z_index = state_mod.devtools_z_index,
        .direction = .Column,
        .background_color = col_panel,
        .border = Border{
            .left = .{ .width = 1.0, .color = col_border },
        },
    };

    try panel.addChild(try buildResizeHandle(MessageT, allocator, state));
    try panel.addChild(try buildTabBar(MessageT, allocator, state, font));

    const content = switch (state.active_tab) {
        .inspector => try buildInspectorTab(MessageT, allocator, state, font, retained_root),
        .profiler => try buildProfilerTab(MessageT, allocator, state, font),
        .memory => try buildMemoryTab(MessageT, allocator, state, font),
        .graphics => try buildGraphicsTab(MessageT, allocator, state, font),
    };
    try panel.addChild(content);

    return panel;
}

fn buildPickButton(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *state_mod.DevToolsState(MessageT),
) !*Node(MessageT) {
    const picking = state.pick_mode;
    const btn = try createNode(MessageT, allocator, .container);
    btn.style = .{
        .direction = .Row,
        .align_items = .Center,
        .justify_content = .Center,
        .width = .{ .exact = 40.0 },
        .height = .Full,
        .background_color = if (picking) col_accent else .{ 0.08, 0.08, 0.10, 1.0 },
        .hover_color = if (picking) col_accent else .{ 0.16, 0.16, 0.20, 1.0 },
        .border = Border{ .right = .{ .width = 1.0, .color = col_border } },
    };

    const ink: [4]f32 = if (picking) .{ 0.05, 0.05, 0.08, 1.0 } else col_text;
    try btn.addChild(try buildCursorIcon(MessageT, allocator, ink));

    try bindClick(MessageT, allocator, btn, @ptrCast(state), struct {
        fn cb(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const sp = ud orelse return null;
            const st: *state_mod.DevToolsState(MessageT) = @ptrCast(@alignCast(@constCast(sp)));
            st.togglePickMode();
            return null;
        }
    }.cb);
    return btn;
}

// Inspect/target glyph drawn from primitives (a ring with crosshair arms and a
// center dot), so it reads as an element picker without a dedicated icon font.
fn buildCursorIcon(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    ink: [4]f32,
) !*Node(MessageT) {
    const box = try createNode(MessageT, allocator, .container);
    box.style = .{ .position = .relative, .width = .{ .exact = 16.0 }, .height = .{ .exact = 16.0 } };

    const ring = try createNode(MessageT, allocator, .container);
    ring.style = .{
        .position = .absolute,
        .left = 2.0,
        .top = 2.0,
        .width = .{ .exact = 12.0 },
        .height = .{ .exact = 12.0 },
        .border = Border.all(1.5, ink),
        .corner_radius = .{ .top_left = 6, .top_right = 6, .bottom_left = 6, .bottom_right = 6 },
    };
    try box.addChild(ring);

    try box.addChild(try iconBar(MessageT, allocator, ink, 7.0, 0.0, 2.0, 4.0));
    try box.addChild(try iconBar(MessageT, allocator, ink, 7.0, 12.0, 2.0, 4.0));
    try box.addChild(try iconBar(MessageT, allocator, ink, 0.0, 7.0, 4.0, 2.0));
    try box.addChild(try iconBar(MessageT, allocator, ink, 12.0, 7.0, 4.0, 2.0));

    const dot = try createNode(MessageT, allocator, .container);
    dot.style = .{
        .position = .absolute,
        .left = 6.5,
        .top = 6.5,
        .width = .{ .exact = 3.0 },
        .height = .{ .exact = 3.0 },
        .background_color = ink,
        .corner_radius = .{ .top_left = 2, .top_right = 2, .bottom_left = 2, .bottom_right = 2 },
    };
    try box.addChild(dot);
    return box;
}

fn iconBar(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    ink: [4]f32,
    left: f32,
    top: f32,
    w: f32,
    h: f32,
) !*Node(MessageT) {
    const bar = try createNode(MessageT, allocator, .container);
    bar.style = .{
        .position = .absolute,
        .left = left,
        .top = top,
        .width = .{ .exact = w },
        .height = .{ .exact = h },
        .background_color = ink,
    };
    return bar;
}

fn buildResizeHandle(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *state_mod.DevToolsState(MessageT),
) !*Node(MessageT) {
    const handle = try createNode(MessageT, allocator, .container);
    handle.style = .{
        .position = .absolute,
        .left = 0.0,
        .top = 0.0,
        .width = .{ .exact = 6.0 },
        .height = .Full,
        .z_index = state_mod.devtools_z_index + 1,
        .cursor = .ew_resize,
        .background_color = .{ 0.0, 0.0, 0.0, 0.0 },
        .hover_color = col_accent,
    };
    handle.lock_pointer_on_drag = true;

    const handler = struct {
        fn cb(ud: ?*const anyopaque, _: EventLayoutSnapshot, data: EventData) ?MessageT {
            const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
            _ = ud;
            if (data == .drag) state_ptr.resizeBy(data.drag.dx);
            return null;
        }
    }.cb;
    const bindings = [_]EventBinding(MessageT){
        .{ .event = .drag, .userdata = @ptrCast(state), .handler = handler },
    };
    handle.events = try allocator.dupe(EventBinding(MessageT), &bindings);
    return handle;
}

fn buildTabBar(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const bar = try createNode(MessageT, allocator, .container);
    bar.style = .{
        .direction = .Row,
        .align_items = .Stretch,
        .height = .{ .exact = 38.0 },
        .background_color = .{ 0.08, 0.08, 0.10, 1.0 },
        .border = Border{ .bottom = .{ .width = 1.0, .color = col_border } },
    };

    try bar.addChild(try buildPickButton(MessageT, allocator, state));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .inspector, "Elements", font));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .profiler, "Perf", font));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .memory, "Memory", font));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .graphics, "GPU", font));

    return bar;
}

fn buildTabButton(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *state_mod.DevToolsState(MessageT),
    tab: state_mod.DevToolsTab,
    label: []const u8,
    font: *FontData,
) !*Node(MessageT) {
    const button = try createNode(MessageT, allocator, .container);
    const active = state.active_tab == tab;
    button.style = .{
        .direction = .Column,
        .align_items = .Center,
        .justify_content = .Center,
        .flex_grow = 1.0,
        .height = .Full,
        .background_color = if (active) .{ 0.16, 0.16, 0.20, 1.0 } else .{ 0.08, 0.08, 0.10, 1.0 },
        .hover_color = if (active) .{ 0.18, 0.18, 0.22, 1.0 } else .{ 0.13, 0.13, 0.16, 1.0 },
        .border = if (active) Border{ .bottom = .{ .width = 2.0, .color = col_accent } } else Border{},
    };

    try button.addChild(try text(MessageT, allocator, label, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = if (active) col_text_bright else col_text_dim,
        .font_weight = if (active) 0.7 else 0.55,
    }));

    const handler = switch (tab) {
        .inspector => onTabClicked(MessageT, .inspector),
        .profiler => onTabClicked(MessageT, .profiler),
        .memory => onTabClicked(MessageT, .memory),
        .graphics => onTabClicked(MessageT, .graphics),
    };
    try bindClick(MessageT, allocator, button, @ptrCast(state), handler);
    return button;
}

fn buildInspectorTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
    retained_root: *Node(MessageT),
) !*Node(MessageT) {
    const container = try contentColumn(MessageT, allocator);

    const selected_valid = if (state.selected_node) |n| containsNodePtr(MessageT, retained_root, n) else false;

    if (selected_valid) {
        try container.addChild(try buildBreadcrumb(MessageT, allocator, state.selected_node.?, retained_root, font));
    }

    try container.addChild(try sectionTitle(MessageT, allocator, "DOM Tree", font));
    const tree_scroll = try createNode(MessageT, allocator, .container);
    tree_scroll.id = state_mod.tree_scroll_id;
    tree_scroll.style = .{
        .direction = .Column,
        .gap = 1.0,
        .max_height = .{ .exact = state_mod.tree_viewport_height },
        .overflow_y = .scroll,
        .background_color = .{ 0.07, 0.07, 0.09, 1.0 },
        .padding = Spacing.all(4.0),
        .corner_radius = .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
    };
    try buildTreeRow(MessageT, allocator, state, font, retained_root, tree_scroll, 0);
    try container.addChild(tree_scroll);

    if (selected_valid) {
        const node = state.selected_node.?;
        try container.addChild(try sectionTitle(MessageT, allocator, "Box Model", font));
        const bm_wrap = try createNode(MessageT, allocator, .container);
        bm_wrap.style = .{ .direction = .Row, .width = .Full, .justify_content = .Start, .padding = .{ .bottom = 4 } };
        try bm_wrap.addChild(try buildBoxModel(MessageT, allocator, node, font));
        try container.addChild(bm_wrap);

        try container.addChild(try sectionTitle(MessageT, allocator, "Experiment (live)", font));
        try buildEditPanel(MessageT, allocator, state, node, font, container);

        try container.addChild(try sectionTitle(MessageT, allocator, "Computed", font));
        try buildComputedStyles(MessageT, allocator, node, font, container);
    } else {
        try container.addChild(try infoLine(MessageT, allocator, "Click a node in the tree to inspect it.", font));
    }

    return container;
}

fn buildBreadcrumb(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    selected: *Node(MessageT),
    retained_root: *Node(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const bar = try createNode(MessageT, allocator, .container);
    bar.style = .{
        .direction = .Row,
        .flex_wrap = .Wrap,
        .align_items = .Center,
        .gap = 2.0,
    };

    var chain: [64]*Node(MessageT) = undefined;
    var count: usize = 0;
    var cur: ?*Node(MessageT) = selected;
    while (cur) |n| {
        if (count >= chain.len) break;
        chain[count] = n;
        count += 1;
        if (n == retained_root) break;
        cur = n.parent;
    }

    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const node = chain[i];
        const is_last = i == 0;
        const chip = try createNode(MessageT, allocator, .container);
        chip.style = .{
            .direction = .Row,
            .align_items = .Center,
            .padding = .{ .left = 5, .right = 5, .top = 2, .bottom = 2 },
            .background_color = if (is_last) col_accent else .{ 0.2, 0.2, 0.24, 1.0 },
            .hover_color = if (is_last) col_accent else .{ 0.26, 0.26, 0.3, 1.0 },
            .corner_radius = .{ .top_left = 3, .top_right = 3, .bottom_left = 3, .bottom_right = 3 },
        };
        try chip.addChild(try text(MessageT, allocator, @tagName(state_mod.payloadKind(node)), font, .{
            .pointer_events = .none,
            .font_size = sz_label,
            .text_color = if (is_last) .{ 0.05, 0.05, 0.08, 1.0 } else col_text,
            .font_weight = 0.6,
        }));
        try bindSelect(MessageT, allocator, chip, node);
        try bar.addChild(chip);

        if (i > 0) {
            try bar.addChild(try text(MessageT, allocator, ">", font, .{
                .pointer_events = .none,
                .font_size = sz_label,
                .text_color = col_text_dim,
            }));
        }
    }
    return bar;
}

fn buildTreeRow(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
    target_node: *Node(MessageT),
    parent_container: *Node(MessageT),
    depth: usize,
) anyerror!void {
    if (target_node.style.z_index == state_mod.devtools_z_index and target_node.style.position == .absolute) return;

    const is_selected = state.selected_node == target_node;
    const has_children = target_node.children.items.len > 0;
    const collapsed = state.isCollapsed(@constCast(target_node));

    const row = try createNode(MessageT, allocator, .container);
    row.style = .{
        .direction = .Row,
        .align_items = .Center,
        .padding = .{
            .left = @as(f32, @floatFromInt(depth * 12)) + 4.0,
            .right = 4.0,
            .top = 3.0,
            .bottom = 3.0,
        },
        .gap = 4.0,
        .background_color = if (is_selected) col_accent else .{ 0.0, 0.0, 0.0, 0.0 },
        .hover_color = if (!is_selected) .{ 0.2, 0.2, 0.24, 1.0 } else null,
        .width = .Full,
    };

    const arrow = try createNode(MessageT, allocator, .container);
    arrow.style = .{
        .width = .{ .exact = 12.0 },
        .align_items = .Center,
        .justify_content = .Center,
    };
    if (has_children) {
        try arrow.addChild(try text(MessageT, allocator, if (collapsed) ">" else "v", font, .{
            .pointer_events = .none,
            .font_size = sz_label,
            .text_color = if (is_selected) .{ 0.05, 0.05, 0.08, 1.0 } else col_text_dim,
        }));
        try bindCollapse(MessageT, allocator, arrow, target_node);
    }
    try row.addChild(arrow);

    try row.addChild(try text(MessageT, allocator, @tagName(state_mod.payloadKind(target_node)), font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = if (is_selected) .{ 0.05, 0.05, 0.08, 1.0 } else col_text,
        .font_weight = 0.6,
    }));

    if (target_node.id) |id| {
        try row.addChild(try fmtText(MessageT, allocator, font, .{
            .pointer_events = .none,
            .font_size = sz_label,
            .text_color = if (is_selected) .{ 0.1, 0.1, 0.2, 1.0 } else col_accent,
        }, "#{d}", .{id}));
    }

    try row.addChild(try fmtText(MessageT, allocator, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = if (is_selected) .{ 0.1, 0.1, 0.2, 1.0 } else col_text_dim,
    }, "{d:.0}x{d:.0}", .{ target_node.layout_result.width, target_node.layout_result.height }));

    if (has_children and collapsed) {
        try row.addChild(try fmtText(MessageT, allocator, font, .{
            .pointer_events = .none,
            .font_size = sz_label,
            .text_color = if (is_selected) .{ 0.1, 0.1, 0.2, 1.0 } else col_text_dim,
        }, "({d})", .{target_node.children.items.len}));
    }

    try bindTreeRow(MessageT, allocator, row, target_node);
    try parent_container.addChild(row);

    if (collapsed) return;
    for (target_node.children.items) |child| {
        try buildTreeRow(MessageT, allocator, state, font, child, parent_container, depth + 1);
    }
}

fn buildBoxModel(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    node: *Node(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const lr = node.layout_result;
    const m = node.style.margin;
    const b = node.style.border.widths();
    const p = node.style.padding;
    const content_w = @max(0.0, lr.width - p.horizontal() - b[1] - b[3]);
    const content_h = @max(0.0, lr.height - p.vertical() - b[0] - b[2]);

    const content = try createNode(MessageT, allocator, .container);
    content.style = .{
        .align_items = .Center,
        .justify_content = .Center,
        .flex_grow = 1.0,
        .padding = Spacing.all(8.0),
        .background_color = .{ 0.3, 0.5, 0.85, 0.45 },
        .min_width = .{ .exact = 80.0 },
        .min_height = .{ .exact = 30.0 },
    };
    try content.addChild(try fmtText(MessageT, allocator, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = col_text_bright,
    }, "{d:.0} x {d:.0}", .{ content_w, content_h }));

    const padding_box = try nestBox(MessageT, allocator, font, "padding", .{ 0.4, 0.8, 0.5, 0.35 }, p.top, p.right, p.bottom, p.left, content);
    const border_box = try nestBox(MessageT, allocator, font, "border", .{ 0.85, 0.75, 0.3, 0.35 }, b[0], b[1], b[2], b[3], padding_box);
    const margin_box = try nestBox(MessageT, allocator, font, "margin", .{ 0.9, 0.55, 0.25, 0.3 }, m.top, m.right, m.bottom, m.left, border_box);
    return margin_box;
}

fn nestBox(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    name: []const u8,
    color: [4]f32,
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
    inner: *Node(MessageT),
) !*Node(MessageT) {
    const box = try createNode(MessageT, allocator, .container);
    box.style = .{
        .direction = .Column,
        .align_items = .Center,
        .flex_grow = 1.0,
        .gap = 2.0,
        .padding = Spacing.all(8.0),
        .background_color = color,
        .corner_radius = .{ .top_left = 2, .top_right = 2, .bottom_left = 2, .bottom_right = 2 },
    };

    try box.addChild(try text(MessageT, allocator, name, font, .{
        .pointer_events = .none,
        .font_size = 9.0,
        .text_color = col_text_bright,
        .font_weight = 0.6,
    }));

    try box.addChild(try valueText(MessageT, allocator, font, top));

    const mid = try createNode(MessageT, allocator, .container);
    mid.style = .{ .direction = .Row, .align_items = .Center, .justify_content = .Center, .width = .Full, .gap = 5.0 };
    try mid.addChild(try valueText(MessageT, allocator, font, left));
    try mid.addChild(inner);
    try mid.addChild(try valueText(MessageT, allocator, font, right));
    try box.addChild(mid);

    try box.addChild(try valueText(MessageT, allocator, font, bottom));
    return box;
}

fn valueText(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    v: f32,
) !*Node(MessageT) {
    return fmtText(MessageT, allocator, font, .{
        .pointer_events = .none,
        .font_size = 10.0,
        .text_color = col_text_bright,
    }, "{d:.0}", .{v});
}

fn buildEditPanel(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    node: *Node(MessageT),
    font: *FontData,
    container: *Node(MessageT),
) !void {
    const ov = state.overrideFor(node);
    const s = node.style;
    const opacity = if (ov) |o| (o.opacity orelse s.opacity) else s.opacity;
    const padding = if (ov) |o| (o.padding_all orelse s.padding.top) else s.padding.top;
    const gap = if (ov) |o| (o.gap orelse s.gap) else s.gap;
    const radius = if (ov) |o| (o.corner_all orelse s.corner_radius.top_left) else s.corner_radius.top_left;
    const bg = if (ov) |o| (o.bg orelse s.background_color) else s.background_color;
    const dir = if (ov) |o| (o.direction orelse s.direction) else s.direction;
    const just = if (ov) |o| (o.justify orelse s.justify_content) else s.justify_content;
    const algn = if (ov) |o| (o.align_items orelse s.align_items) else s.align_items;
    const hidden = if (ov) |o| o.hidden else false;

    var buf: [32]u8 = undefined;
    try container.addChild(try stepperRow(MessageT, allocator, state, font, "opacity", std.fmt.bufPrint(&buf, "{d:.2}", .{opacity}) catch "?", .opacity_dec, .opacity_inc));
    try container.addChild(try stepperRow(MessageT, allocator, state, font, "padding", std.fmt.bufPrint(&buf, "{d:.0}", .{padding}) catch "?", .padding_dec, .padding_inc));
    try container.addChild(try stepperRow(MessageT, allocator, state, font, "gap", std.fmt.bufPrint(&buf, "{d:.0}", .{gap}) catch "?", .gap_dec, .gap_inc));
    try container.addChild(try stepperRow(MessageT, allocator, state, font, "radius", std.fmt.bufPrint(&buf, "{d:.0}", .{radius}) catch "?", .radius_dec, .radius_inc));
    try container.addChild(try stepperRow(MessageT, allocator, state, font, "bg alpha", std.fmt.bufPrint(&buf, "{d:.2}", .{bg[3]}) catch "?", .bg_alpha_dec, .bg_alpha_inc));
    try container.addChild(try cycleRow(MessageT, allocator, state, font, "direction", @tagName(dir), .dir_toggle));
    try container.addChild(try cycleRow(MessageT, allocator, state, font, "justify", @tagName(just), .justify_cycle));
    try container.addChild(try cycleRow(MessageT, allocator, state, font, "align", @tagName(algn), .align_cycle));
    try container.addChild(try cycleRow(MessageT, allocator, state, font, "hidden", if (hidden) "yes" else "no", .toggle_hidden));

    const reset = try createNode(MessageT, allocator, .container);
    reset.style = .{
        .direction = .Row,
        .justify_content = .Center,
        .align_items = .Center,
        .width = .Full,
        .padding = .{ .top = 5, .bottom = 5, .left = 8, .right = 8 },
        .background_color = .{ 0.35, 0.2, 0.2, 1.0 },
        .hover_color = .{ 0.45, 0.25, 0.25, 1.0 },
        .corner_radius = .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
    };
    try reset.addChild(try text(MessageT, allocator, "Reset overrides", font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = col_text_bright,
    }));
    try bindClick(MessageT, allocator, reset, @ptrCast(@constCast(state)), onEdit(MessageT, .reset));
    try container.addChild(reset);
}

fn stepperRow(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
    label: []const u8,
    value: []const u8,
    comptime dec: state_mod.EditAction,
    comptime inc: state_mod.EditAction,
) !*Node(MessageT) {
    const row = try createNode(MessageT, allocator, .container);
    row.style = .{ .direction = .Row, .justify_content = .SpaceBetween, .align_items = .Center, .width = .Full, .gap = 8.0 };
    try row.addChild(try text(MessageT, allocator, label, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = col_text_dim,
    }));

    const controls = try createNode(MessageT, allocator, .container);
    controls.style = .{ .direction = .Row, .align_items = .Center, .gap = 4.0 };
    try controls.addChild(try editButton(MessageT, allocator, state, dec, "-", font));

    const val_box = try createNode(MessageT, allocator, .container);
    val_box.style = .{
        .direction = .Row,
        .align_items = .Center,
        .justify_content = .Center,
        .width = .{ .exact = 44.0 },
    };
    try val_box.addChild(try text(MessageT, allocator, value, font, .{
        .pointer_events = .none,
        .font_size = sz_value,
        .text_color = col_text,
    }));
    try controls.addChild(val_box);

    try controls.addChild(try editButton(MessageT, allocator, state, inc, "+", font));
    try row.addChild(controls);
    return row;
}

fn cycleRow(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
    label: []const u8,
    value: []const u8,
    comptime action: state_mod.EditAction,
) !*Node(MessageT) {
    const row = try createNode(MessageT, allocator, .container);
    row.style = .{ .direction = .Row, .justify_content = .SpaceBetween, .align_items = .Center, .width = .Full, .gap = 8.0 };
    try row.addChild(try text(MessageT, allocator, label, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = col_text_dim,
    }));

    const btn = try createNode(MessageT, allocator, .container);
    btn.style = .{
        .direction = .Row,
        .align_items = .Center,
        .justify_content = .Center,
        .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
        .background_color = col_row,
        .hover_color = .{ 0.24, 0.24, 0.28, 1.0 },
        .corner_radius = .{ .top_left = 3, .top_right = 3, .bottom_left = 3, .bottom_right = 3 },
    };
    try btn.addChild(try text(MessageT, allocator, value, font, .{
        .pointer_events = .none,
        .font_size = sz_value,
        .text_color = col_text,
    }));
    try bindClick(MessageT, allocator, btn, @ptrCast(@constCast(state)), onEdit(MessageT, action));
    try row.addChild(btn);
    return row;
}

fn editButton(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    comptime action: state_mod.EditAction,
    glyph: []const u8,
    font: *FontData,
) !*Node(MessageT) {
    const btn = try createNode(MessageT, allocator, .container);
    btn.style = .{
        .direction = .Row,
        .align_items = .Center,
        .justify_content = .Center,
        .width = .{ .exact = 22.0 },
        .padding = .{ .top = 2, .bottom = 2, .left = 0, .right = 0 },
        .background_color = col_row,
        .hover_color = col_accent,
        .corner_radius = .{ .top_left = 3, .top_right = 3, .bottom_left = 3, .bottom_right = 3 },
    };
    try btn.addChild(try text(MessageT, allocator, glyph, font, .{
        .pointer_events = .none,
        .font_size = sz_value,
        .text_color = col_text_bright,
        .font_weight = 0.7,
    }));
    try bindClick(MessageT, allocator, btn, @ptrCast(@constCast(state)), onEdit(MessageT, action));
    return btn;
}

fn buildComputedStyles(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    node: *Node(MessageT),
    font: *FontData,
    container: *Node(MessageT),
) !void {
    const s = node.style;
    if (node.id) |id| {
        try container.addChild(try kvFmt(MessageT, allocator, font, "node-id", "{d}", .{id}));
    } else {
        try container.addChild(try kv(MessageT, allocator, font, "node-id", "(anonymous)"));
    }
    try container.addChild(try kv(MessageT, allocator, font, "display", @tagName(s.display)));
    try container.addChild(try kv(MessageT, allocator, font, "position", @tagName(s.position)));
    try container.addChild(try kv(MessageT, allocator, font, "direction", @tagName(s.direction)));
    try container.addChild(try kv(MessageT, allocator, font, "justify", @tagName(s.justify_content)));
    try container.addChild(try kv(MessageT, allocator, font, "align", @tagName(s.align_items)));
    try container.addChild(try kvFmt(MessageT, allocator, font, "z-index", "{d}", .{s.z_index}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "opacity", "{d:.2}", .{s.opacity}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "flex-grow", "{d:.2}", .{s.flex_grow}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "gap", "{d:.0}", .{s.gap}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "font-size", "{d:.0}", .{s.font_size}));
    try container.addChild(try sizeKv(MessageT, allocator, font, "width", s.width));
    try container.addChild(try sizeKv(MessageT, allocator, font, "height", s.height));
    try container.addChild(try swatchRow(MessageT, allocator, font, "background", s.background_color));
    try container.addChild(try swatchRow(MessageT, allocator, font, "text-color", s.text_color));
    if (node.style.border.hasAny()) {
        try container.addChild(try swatchRow(MessageT, allocator, font, "border", s.border.top.color));
    }

    try container.addChild(try fmtText(MessageT, allocator, font, .{
        .text_color = col_text_dim,
        .font_size = sz_value,
        .pointer_events = .none,
    }, "focusable={} focused={} hovered={}", .{ node.is_focusable, node.is_focused, node.is_hovered }));
    try container.addChild(try kvFmt(MessageT, allocator, font, "children", "{d}", .{node.children.items.len}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "events", "{d}", .{node.events.len}));
}

fn buildProfilerTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const container = try contentColumn(MessageT, allocator);
    const stats = state.frameStats();

    const hero = try createNode(MessageT, allocator, .container);
    hero.style = .{ .direction = .Row, .align_items = .End, .gap = 8.0 };
    try hero.addChild(try fmtText(MessageT, allocator, font, .{
        .pointer_events = .none,
        .font_size = sz_big,
        .text_color = fpsColor(stats.fps),
        .font_weight = 0.8,
    }, "{d:.0}", .{stats.fps}));
    try hero.addChild(try text(MessageT, allocator, "FPS", font, .{
        .pointer_events = .none,
        .font_size = sz_value,
        .text_color = col_text_dim,
    }));
    try container.addChild(hero);

    try container.addChild(try sectionTitle(MessageT, allocator, "Frame Time (ms)", font));
    try container.addChild(try buildFrameGraph(MessageT, allocator, state, font));

    try container.addChild(try kvFmt(MessageT, allocator, font, "last", "{d:.2} ms", .{stats.last_ms}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "avg", "{d:.2} ms", .{stats.avg_ms}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "min", "{d:.2} ms", .{stats.min_ms}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "max", "{d:.2} ms", .{stats.max_ms}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "p95", "{d:.2} ms", .{stats.p95_ms}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "samples", "{d}", .{stats.sample_count}));
    return container;
}

fn buildFrameGraph(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const graph_height: f32 = 90.0;
    const target_ms: f32 = 16.6;
    const scale_max: f32 = 50.0;

    const wrap = try createNode(MessageT, allocator, .container);
    wrap.style = .{
        .direction = .Row,
        .align_items = .End,
        .justify_content = .End,
        .gap = 1.0,
        .height = .{ .exact = graph_height },
        .background_color = .{ 0.07, 0.07, 0.09, 1.0 },
        .padding = Spacing.all(3.0),
        .corner_radius = .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
    };

    const len = state.metrics.frame_time_history_len;
    const max_bars: usize = 110;
    const start = if (len > max_bars) len - max_bars else 0;

    if (len == 0) {
        try wrap.addChild(try text(MessageT, allocator, "collecting...", font, .{
            .pointer_events = .none,
            .font_size = sz_label,
            .text_color = col_text_dim,
        }));
        return wrap;
    }

    var i: usize = start;
    while (i < len) : (i += 1) {
        const ms = state.frameTimeAt(i);
        const ratio = std.math.clamp(ms / scale_max, 0.02, 1.0);
        const bar = try createNode(MessageT, allocator, .container);
        bar.style = .{
            .width = .{ .exact = 3.0 },
            .height = .{ .exact = ratio * (graph_height - 6.0) },
            .background_color = if (ms <= target_ms)
                .{ 0.4, 0.8, 0.45, 1.0 }
            else if (ms <= target_ms * 2.0)
                .{ 0.9, 0.75, 0.3, 1.0 }
            else
                .{ 0.9, 0.35, 0.3, 1.0 },
        };
        try wrap.addChild(bar);
    }
    return wrap;
}

fn buildMemoryTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const container = try contentColumn(MessageT, allocator);
    const m = state.metrics;

    try container.addChild(try sectionTitle(MessageT, allocator, "Retained Tree", font));
    try container.addChild(try kvFmt(MessageT, allocator, font, "nodes", "{d}", .{m.node_count}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "max depth", "{d}", .{m.max_depth}));

    try container.addChild(try sectionTitle(MessageT, allocator, "By Payload", font));
    const fields = std.meta.fields(PayloadKind);
    inline for (fields) |f| {
        const count = m.payload_counts[f.value];
        if (count > 0) {
            try container.addChild(try kvFmt(MessageT, allocator, font, f.name, "{d}", .{count}));
        }
    }
    return container;
}

fn buildGraphicsTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const container = try contentColumn(MessageT, allocator);
    const m = state.metrics;

    try container.addChild(try sectionTitle(MessageT, allocator, "Draw Stats", font));
    try container.addChild(try kvFmt(MessageT, allocator, font, "draw calls", "{d}", .{m.draw_calls}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "quads", "{d}", .{m.quad_count}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "vertices", "{d}", .{m.vertex_count}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "indices", "{d}", .{m.index_count}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "layers", "{d}", .{m.layer_count}));
    try container.addChild(try kvFmt(MessageT, allocator, font, "blur layers", "{d}", .{m.blur_layer_count}));

    try container.addChild(try sectionTitle(MessageT, allocator, "Layers (by z-index)", font));
    if (m.layer_snapshot_count == 0) {
        try container.addChild(try infoLine(MessageT, allocator, "no draw data yet", font));
    }
    var i: usize = 0;
    while (i < m.layer_snapshot_count) : (i += 1) {
        const ls = m.layer_snapshots[i];
        const row = try createNode(MessageT, allocator, .container);
        row.style = .{
            .direction = .Row,
            .align_items = .Center,
            .padding = .{ .left = 6, .right = 6, .top = 4, .bottom = 4 },
            .background_color = col_row,
            .corner_radius = .{ .top_left = 3, .top_right = 3, .bottom_left = 3, .bottom_right = 3 },
        };
        try row.addChild(try fmtText(MessageT, allocator, font, .{
            .pointer_events = .none,
            .font_size = sz_value,
            .text_color = if (ls.has_blur) col_accent else col_text,
        }, "z={d}  {d} calls  {d} quads", .{ ls.z, ls.draw_calls, ls.quads }));
        try container.addChild(row);
    }
    return container;
}

fn fpsColor(fps: f32) [4]f32 {
    if (fps >= 55.0) return .{ 0.4, 0.85, 0.45, 1.0 };
    if (fps >= 30.0) return .{ 0.9, 0.78, 0.3, 1.0 };
    return .{ 0.9, 0.4, 0.35, 1.0 };
}

fn contentColumn(comptime MessageT: type, allocator: std.mem.Allocator) !*Node(MessageT) {
    const container = try createNode(MessageT, allocator, .container);
    container.style = .{
        .direction = .Column,
        .gap = 6.0,
        .padding = Spacing.all(12.0),
        .overflow_y = .scroll,
        .flex_grow = 1.0,
    };
    return container;
}

fn sectionTitle(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    str: []const u8,
    font: *FontData,
) !*Node(MessageT) {
    const node = try text(MessageT, allocator, str, font, .{
        .text_color = col_text_bright,
        .font_size = sz_title,
        .font_weight = 0.72,
        .pointer_events = .none,
    });
    node.style.padding = .{ .top = 6.0, .bottom = 0.0, .left = 0.0, .right = 0.0 };
    return node;
}

fn infoLine(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    str: []const u8,
    font: *FontData,
) !*Node(MessageT) {
    return text(MessageT, allocator, str, font, .{
        .text_color = col_text_dim,
        .font_size = sz_value,
        .pointer_events = .none,
    });
}

fn kv(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    key: []const u8,
    value: []const u8,
) !*Node(MessageT) {
    const row = try createNode(MessageT, allocator, .container);
    row.style = .{
        .direction = .Row,
        .justify_content = .SpaceBetween,
        .align_items = .Center,
        .width = .Full,
        .gap = 8.0,
    };
    try row.addChild(try text(MessageT, allocator, key, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = col_text_dim,
    }));
    try row.addChild(try text(MessageT, allocator, value, font, .{
        .pointer_events = .none,
        .font_size = sz_value,
        .text_color = col_text,
        .font_weight = 0.62,
    }));
    return row;
}

fn kvFmt(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    key: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !*Node(MessageT) {
    var buf: [192]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    return kv(MessageT, allocator, font, key, value);
}

fn sizeKv(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    key: []const u8,
    size: Size,
) !*Node(MessageT) {
    var buf: [32]u8 = undefined;
    const value = switch (size) {
        .Auto => "auto",
        .Full => "full",
        .screen => "screen",
        .percent => |v| std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100.0}) catch "?",
        .exact => |v| std.fmt.bufPrint(&buf, "{d:.0}px", .{v}) catch "?",
    };
    return kv(MessageT, allocator, font, key, value);
}

fn swatchRow(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    key: []const u8,
    color: [4]f32,
) !*Node(MessageT) {
    const row = try createNode(MessageT, allocator, .container);
    row.style = .{
        .direction = .Row,
        .justify_content = .SpaceBetween,
        .align_items = .Center,
        .width = .Full,
        .gap = 8.0,
    };
    try row.addChild(try text(MessageT, allocator, key, font, .{
        .pointer_events = .none,
        .font_size = sz_label,
        .text_color = col_text_dim,
    }));

    const right = try createNode(MessageT, allocator, .container);
    right.style = .{ .direction = .Row, .align_items = .Center, .gap = 6.0 };

    const swatch = try createNode(MessageT, allocator, .container);
    swatch.style = .{
        .width = .{ .exact = 14.0 },
        .height = .{ .exact = 14.0 },
        .background_color = color,
        .corner_radius = .{ .top_left = 3, .top_right = 3, .bottom_left = 3, .bottom_right = 3 },
        .border = Border.all(1.0, .{ 0.4, 0.4, 0.45, 1.0 }),
    };
    try right.addChild(swatch);

    try right.addChild(try fmtText(MessageT, allocator, font, .{
        .pointer_events = .none,
        .font_size = sz_value,
        .text_color = col_text,
    }, "{x:0>2}{x:0>2}{x:0>2} {d:.2}", .{
        @as(u8, @intFromFloat(std.math.clamp(color[0], 0.0, 1.0) * 255.0)),
        @as(u8, @intFromFloat(std.math.clamp(color[1], 0.0, 1.0) * 255.0)),
        @as(u8, @intFromFloat(std.math.clamp(color[2], 0.0, 1.0) * 255.0)),
        color[3],
    }));
    try row.addChild(right);
    return row;
}

fn text(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    content: []const u8,
    font: *FontData,
    style: Style,
) !*Node(MessageT) {
    const node = try createNode(MessageT, allocator, .{
        .text = .{
            .content = try allocator.dupe(u8, content),
            .font = font,
            .max_width = 0.0,
        },
    });
    node.style = style;
    return node;
}

// Formats into a stack buffer and lets `text` dupe it, so no heap temporary is
// left to leak when the overlay is built with the GPA (e.g. the initial mount).
fn fmtText(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    font: *FontData,
    style: Style,
    comptime fmt: []const u8,
    args: anytype,
) !*Node(MessageT) {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    return text(MessageT, allocator, s, font, style);
}

fn createNode(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    payload: @import("../ui/node.zig").RenderPayload,
) !*Node(MessageT) {
    const node = try allocator.create(Node(MessageT));
    node.* = Node(MessageT).init();
    node.allocator = allocator;
    node.payload = payload;
    return node;
}

fn bindClick(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    node: *Node(MessageT),
    userdata: *anyopaque,
    handler: *const fn (?*const anyopaque, EventLayoutSnapshot, EventData) ?MessageT,
) !void {
    const bindings = [_]EventBinding(MessageT){
        .{ .event = .click, .userdata = userdata, .handler = handler },
    };
    node.events = try allocator.dupe(EventBinding(MessageT), &bindings);
}

fn bindSelect(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    node: *Node(MessageT),
    target: *Node(MessageT),
) !void {
    const handler = struct {
        fn cb(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const opaque_target = ud orelse return null;
            const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
            const tgt: *Node(MessageT) = @ptrCast(@alignCast(@constCast(opaque_target)));
            state_ptr.selectNode(tgt);
            return null;
        }
    }.cb;
    try bindClick(MessageT, allocator, node, @ptrCast(target), handler);
}

fn bindTreeRow(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    row: *Node(MessageT),
    target: *Node(MessageT),
) !void {
    const Handlers = struct {
        fn select(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const opaque_target = ud orelse return null;
            const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
            state_ptr.selectNode(@ptrCast(@alignCast(@constCast(opaque_target))));
            return null;
        }
        fn enter(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const opaque_target = ud orelse return null;
            const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
            state_ptr.setInspectHover(@ptrCast(@alignCast(@constCast(opaque_target))));
            return null;
        }
        fn exit(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const opaque_target = ud orelse return null;
            const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
            state_ptr.clearInspectHover(@ptrCast(@alignCast(@constCast(opaque_target))));
            return null;
        }
    };
    const bindings = [_]EventBinding(MessageT){
        .{ .event = .click, .userdata = @ptrCast(target), .handler = Handlers.select },
        .{ .event = .hover_enter, .userdata = @ptrCast(target), .handler = Handlers.enter },
        .{ .event = .hover_exit, .userdata = @ptrCast(target), .handler = Handlers.exit },
    };
    row.events = try allocator.dupe(EventBinding(MessageT), &bindings);
}

fn onEdit(
    comptime MessageT: type,
    comptime action: state_mod.EditAction,
) *const fn (?*const anyopaque, EventLayoutSnapshot, EventData) ?MessageT {
    return struct {
        fn cb(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const state_ptr = ud orelse return null;
            const devtools_state: *state_mod.DevToolsState(MessageT) = @ptrCast(@alignCast(@constCast(state_ptr)));
            devtools_state.applyEdit(action);
            return null;
        }
    }.cb;
}

fn bindCollapse(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    node: *Node(MessageT),
    target: *Node(MessageT),
) !void {
    const handler = struct {
        fn cb(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const opaque_target = ud orelse return null;
            const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
            const tgt: *Node(MessageT) = @ptrCast(@alignCast(@constCast(opaque_target)));
            state_ptr.toggleCollapsed(tgt);
            return null;
        }
    }.cb;
    try bindClick(MessageT, allocator, node, @ptrCast(target), handler);
}

fn devtoolsStateSlot(comptime MessageT: type) *?*state_mod.DevToolsState(MessageT) {
    const Slot = struct {
        var value: ?*state_mod.DevToolsState(MessageT) = null;
    };
    return &Slot.value;
}

fn containsNodePtr(comptime MessageT: type, root: *Node(MessageT), target: *Node(MessageT)) bool {
    if (root == target) return true;
    for (root.children.items) |child| {
        if (containsNodePtr(MessageT, child, target)) return true;
    }
    return false;
}

fn onTabClicked(
    comptime MessageT: type,
    comptime tab: state_mod.DevToolsTab,
) *const fn (?*const anyopaque, EventLayoutSnapshot, EventData) ?MessageT {
    return struct {
        fn callback(userdata: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
            const state_ptr = userdata orelse return null;
            const devtools_state: *state_mod.DevToolsState(MessageT) = @ptrCast(@alignCast(@constCast(state_ptr)));
            devtools_state.setTab(tab);
            return null;
        }
    }.callback;
}
