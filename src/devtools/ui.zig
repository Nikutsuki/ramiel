const std = @import("std");
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const Style = @import("../ui/layout.zig").Style;
const Border = @import("../ui/layout.zig").Border;
const Spacing = @import("../ui/layout.zig").Spacing;
const Node = @import("../ui/node.zig").Node;
const types = @import("../ui/types.zig");
const EventBinding = types.EventBinding;
const EventData = types.EventData;
const EventLayoutSnapshot = types.EventLayoutSnapshot;
const state_mod = @import("state.zig");

pub fn buildDevToolsPanel(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *state_mod.DevToolsState(MessageT),
    font: *FontData,
    retained_root: *Node(MessageT),
) !*Node(MessageT) {
    if (!state.is_active) {
        const empty = try createNode(MessageT, allocator, .fragment);
        return empty;
    }

    const panel = try createNode(MessageT, allocator, .container);
    panel.style = .{
        .position = .absolute,
        .top = 0.0,
        .right = 0.0,
        .width = .{ .exact = state.panel_width },
        .height = .Full,
        .z_index = 1_000_000,
        .direction = .Column,
        .background_color = .{ 0.10, 0.10, 0.10, 0.96 },
        .border = Border{
            .left = .{ .width = 1.0, .color = .{ 0.30, 0.30, 0.30, 1.0 } },
        },
    };

    const tab_bar = try buildTabBar(MessageT, allocator, state, font);
    try panel.addChild(tab_bar);

    const content = switch (state.active_tab) {
        .inspector => try buildInspectorTab(MessageT, allocator, state, font, retained_root),
        .profiler => try buildProfilerTab(MessageT, allocator, state, font),
        .memory => try buildMemoryTab(MessageT, allocator, state, font),
        .graphics => try buildGraphicsTab(MessageT, allocator, state, font),
    };
    try panel.addChild(content);

    return panel;
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
        .justify_content = .Start,
        .height = .{ .exact = 40.0 },
        .background_color = .{ 0.14, 0.14, 0.14, 1.0 },
        .border = Border{
            .bottom = .{ .width = 1.0, .color = .{ 0.25, 0.25, 0.25, 1.0 } },
        },
    };

    try bar.addChild(try buildTabButton(MessageT, allocator, state, .inspector, "Inspector", font));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .profiler, "Profiler", font));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .memory, "Memory", font));
    try bar.addChild(try buildTabButton(MessageT, allocator, state, .graphics, "Graphics", font));

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
        .direction = .Row,
        .align_items = .Center,
        .justify_content = .Center,
        .flex_grow = 1.0,
        .height = .Full,
        .background_color = if (active) .{ 0.22, 0.22, 0.22, 1.0 } else .{ 0.14, 0.14, 0.14, 1.0 },
        .hover_color = if (active) .{ 0.24, 0.24, 0.24, 1.0 } else .{ 0.18, 0.18, 0.18, 1.0 },
    };

    const label_node = try createTextNode(MessageT, allocator, label, font, .{
        .pointer_events = .none,
        .text_color = if (active) .{ 0.95, 0.95, 0.95, 1.0 } else .{ 0.80, 0.80, 0.80, 1.0 },
    });
    try button.addChild(label_node);

    const bindings = [_]EventBinding(MessageT){
        .{
            .event = .click,
            .userdata = @ptrCast(state),
            .handler = switch (tab) {
                .inspector => onTabClicked(MessageT, .inspector),
                .profiler => onTabClicked(MessageT, .profiler),
                .memory => onTabClicked(MessageT, .memory),
                .graphics => onTabClicked(MessageT, .graphics),
            },
        },
    };
    button.events = try button.allocator.dupe(EventBinding(MessageT), &bindings);
    return button;
}

fn buildInspectorTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
    retained_root: *Node(MessageT),
) !*Node(MessageT) {
    const container = try createContentContainer(MessageT, allocator);
    try container.addChild(try createSectionTitle(MessageT, allocator, "Inspector", font));
    devtoolsStateSlot(MessageT).* = @constCast(state);

    const tree_container = try createNode(MessageT, allocator, .container);
    tree_container.style.direction = .Column;
    tree_container.style.gap = 2.0;
    try buildTreeView(MessageT, allocator, state, font, retained_root, tree_container, 0);
    try container.addChild(tree_container);

    if (state.selected_node) |node| {
        if (!containsNodePtr(MessageT, retained_root, node)) {
            try container.addChild(try createInfoLine(MessageT, allocator, "Select a node to inspect", font));
            return container;
        }
        try container.addChild(try createSectionTitle(MessageT, allocator, "Properties", font));
        const payload_name = @tagName(std.meta.activeTag(node.payload));
        const info = try std.fmt.allocPrint(allocator, "payload={s} x={d:.1} y={d:.1} w={d:.1} h={d:.1}", .{
            payload_name,
            node.layout_result.x,
            node.layout_result.y,
            node.layout_result.width,
            node.layout_result.height,
        });
        defer allocator.free(info);
        try container.addChild(try createInfoLine(MessageT, allocator, info, font));
    } else {
        try container.addChild(try createInfoLine(MessageT, allocator, "Select a node to inspect", font));
    }

    if (state.hovered_node) |hovered| {
        if (!containsNodePtr(MessageT, retained_root, hovered)) return container;
        const hovered_name = @tagName(std.meta.activeTag(hovered.payload));
        const hovered_info = try std.fmt.allocPrint(allocator, "hovered={s}", .{hovered_name});
        defer allocator.free(hovered_info);
        try container.addChild(try createInfoLine(MessageT, allocator, hovered_info, font));
    }

    return container;
}

fn buildProfilerTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const container = try createContentContainer(MessageT, allocator);
    try container.addChild(try createSectionTitle(MessageT, allocator, "Profiler", font));

    const frame = try std.fmt.allocPrint(allocator, "frame_time_ms={d:.3}", .{state.metrics.frame_time_ms});
    defer allocator.free(frame);
    try container.addChild(try createInfoLine(MessageT, allocator, frame, font));
    try container.addChild(try createInfoLine(MessageT, allocator, "Profiler data provider pending", font));

    return container;
}

fn buildMemoryTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const container = try createContentContainer(MessageT, allocator);
    try container.addChild(try createSectionTitle(MessageT, allocator, "Memory", font));

    const allocs = try std.fmt.allocPrint(allocator, "total_allocations={d}", .{state.metrics.total_allocations});
    defer allocator.free(allocs);
    try container.addChild(try createInfoLine(MessageT, allocator, allocs, font));
    try container.addChild(try createInfoLine(MessageT, allocator, "Memory data provider pending", font));

    return container;
}

fn buildGraphicsTab(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
) !*Node(MessageT) {
    const container = try createContentContainer(MessageT, allocator);
    try container.addChild(try createSectionTitle(MessageT, allocator, "Graphics", font));

    const info = try std.fmt.allocPrint(allocator, "draw_calls={d} active_textures={d}", .{
        state.metrics.draw_calls,
        state.metrics.active_textures,
    });
    defer allocator.free(info);
    try container.addChild(try createInfoLine(MessageT, allocator, info, font));
    try container.addChild(try createInfoLine(MessageT, allocator, "Graphics data provider pending", font));

    return container;
}

fn createContentContainer(comptime MessageT: type, allocator: std.mem.Allocator) !*Node(MessageT) {
    const container = try createNode(MessageT, allocator, .container);
    container.style = .{
        .direction = .Column,
        .gap = 8.0,
        .padding = Spacing.all(12.0),
        .overflow_y = .scroll,
        .flex_grow = 1.0,
    };
    return container;
}

fn createSectionTitle(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    text: []const u8,
    font: *FontData,
) !*Node(MessageT) {
    return createTextNode(MessageT, allocator, text, font, .{
        .text_color = .{ 0.96, 0.96, 0.96, 1.0 },
        .font_weight = 0.65,
    });
}

fn createInfoLine(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    text: []const u8,
    font: *FontData,
) !*Node(MessageT) {
    return createTextNode(MessageT, allocator, text, font, .{
        .text_color = .{ 0.80, 0.80, 0.80, 1.0 },
    });
}

fn createTextNode(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    text: []const u8,
    font: *FontData,
    style: Style,
) !*Node(MessageT) {
    const node = try createNode(MessageT, allocator, .{
        .text = .{
            .content = try allocator.dupe(u8, text),
            .font = font,
            .max_width = 0.0,
        },
    });
    node.style = style;
    return node;
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

fn buildTreeView(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    state: *const state_mod.DevToolsState(MessageT),
    font: *FontData,
    target_node: *Node(MessageT),
    parent_container: *Node(MessageT),
    depth: usize,
) anyerror!void {
    if (target_node.style.z_index == 1_000_000 and target_node.style.position == .absolute) return;

    const is_selected = state.selected_node == target_node;

    const row = try createNode(MessageT, allocator, .container);
    row.style = .{
        .direction = .Row,
        .padding = .{
            .left = @as(f32, @floatFromInt(depth * 14)),
            .right = 0.0,
            .top = 4.0,
            .bottom = 4.0,
        },
        .background_color = if (is_selected) .{ 0.2, 0.4, 0.8, 0.8 } else .{ 0.0, 0.0, 0.0, 0.0 },
        .hover_color = if (!is_selected) .{ 0.25, 0.25, 0.25, 1.0 } else null,
        .width = .Full,
    };

    const payload_name = @tagName(std.meta.activeTag(target_node.payload));
    const label = try std.fmt.allocPrint(allocator, "{s} [{d:.0}x{d:.0}]", .{
        payload_name,
        target_node.layout_result.width,
        target_node.layout_result.height,
    });
    defer allocator.free(label);

    const text_node = try createTextNode(MessageT, allocator, label, font, .{
        .text_color = if (is_selected) .{ 1.0, 1.0, 1.0, 1.0 } else .{ 0.75, 0.75, 0.75, 1.0 },
        .pointer_events = .none,
    });
    try row.addChild(text_node);

    const bindings = [_]EventBinding(MessageT){
        .{
            .event = .click,
            .userdata = @ptrCast(target_node),
            .handler = struct {
                fn cb(ud: ?*const anyopaque, _: EventLayoutSnapshot, _: EventData) ?MessageT {
                    const opaque_target = ud orelse return null;
                    const state_ptr = devtoolsStateSlot(MessageT).* orelse return null;
                    const target: *Node(MessageT) = @ptrCast(@alignCast(@constCast(opaque_target)));
                    state_ptr.selected_node = target;
                    state_ptr.request_rebuild = true;
                    return null;
                }
            }.cb,
        },
    };
    row.events = try allocator.dupe(EventBinding(MessageT), &bindings);

    try parent_container.addChild(row);

    for (target_node.children.items) |child| {
        try buildTreeView(MessageT, allocator, state, font, child, parent_container, depth + 1);
    }
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
