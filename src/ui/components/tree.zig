const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const icon_impl = @import("icon.zig");
const dupeMessageBinding = @import("../node.zig").dupeMessageBinding;
const destroyOwnedEventUserdata = @import("../node.zig").destroyOwnedEventUserdata;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;
const hashIconId = @import("../../renderer/icon/id.zig").hashId;

pub const CoreIcons = struct {
    pub const ArrowDropdown = hashIconId("ramiel:core:arrow_dropdown");
};

pub fn FieldTreeAdapter(comptime ItemT: type) type {
    return struct {
        pub fn id(item: *const ItemT) []const u8 {
            return @field(item.*, "id");
        }

        pub fn children(item: *const ItemT) []const ItemT {
            return @field(item.*, "children").items;
        }

        pub fn isGroup(item: *const ItemT) bool {
            if (@hasField(ItemT, "is_group")) return @field(item.*, "is_group");
            return children(item).len > 0;
        }
    };
}

pub const TreeItem = struct {
    id: []const u8,
    depth: u32,
    is_group: bool,
    is_expanded: bool,
    is_selected: bool,
    can_receive_children: bool = true,
};

pub const DropPosition = enum {
    before,
    inside,
    after,
};

pub const TreePos = struct { x: f32, y: f32 };

pub fn TreeState(comptime IdT: type) type {
    const MapT = if (IdT == []const u8) std.StringHashMap(void) else std.AutoHashMap(IdT, void);
    return struct {
        allocator: std.mem.Allocator,
        selected_ids: MapT,
        expanded_ids: MapT,

        dragged_id: ?IdT = null,
        drag_pos: ?TreePos = null,
        drop_target_id: ?IdT = null,
        drop_target_pos: ?DropPosition = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .selected_ids = MapT.init(allocator),
                .expanded_ids = MapT.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            if (IdT == []const u8) {
                var it_s = self.selected_ids.keyIterator();
                while (it_s.next()) |key| {
                    self.allocator.free(key.*);
                }
                var it_e = self.expanded_ids.keyIterator();
                while (it_e.next()) |key| {
                    self.allocator.free(key.*);
                }
            }
            self.selected_ids.deinit();
            self.expanded_ids.deinit();
        }

        pub fn isSelected(self: *const Self, id: IdT) bool {
            return self.selected_ids.contains(id);
        }

        pub fn isExpanded(self: *const Self, id: IdT) bool {
            return self.expanded_ids.contains(id);
        }

        pub fn toggleExpanded(self: *Self, id: IdT) !void {
            if (IdT == []const u8) {
                if (self.expanded_ids.getEntry(id)) |entry| {
                    const key = entry.key_ptr.*;
                    _ = self.expanded_ids.remove(id);
                    self.allocator.free(key);
                } else {
                    const key = try self.allocator.dupe(u8, id);
                    try self.expanded_ids.put(key, {});
                }
            } else {
                if (self.expanded_ids.contains(id)) {
                    _ = self.expanded_ids.remove(id);
                } else {
                    try self.expanded_ids.put(id, {});
                }
            }
        }

        pub fn setExpanded(self: *Self, id: IdT, expanded: bool) !void {
            if (expanded) {
                if (!self.expanded_ids.contains(id)) {
                    if (IdT == []const u8) {
                        const key = try self.allocator.dupe(u8, id);
                        try self.expanded_ids.put(key, {});
                    } else {
                        try self.expanded_ids.put(id, {});
                    }
                }
            } else {
                if (IdT == []const u8) {
                    if (self.expanded_ids.getEntry(id)) |entry| {
                        const key = entry.key_ptr.*;
                        _ = self.expanded_ids.remove(id);
                        self.allocator.free(key);
                    }
                } else {
                    _ = self.expanded_ids.remove(id);
                }
            }
        }

        pub fn selectOnly(self: *Self, id: IdT) !void {
            self.clearSelection();
            if (IdT == []const u8) {
                const key = try self.allocator.dupe(u8, id);
                try self.selected_ids.put(key, {});
            } else {
                try self.selected_ids.put(id, {});
            }
        }

        pub fn toggleSelection(self: *Self, id: IdT) !void {
            if (IdT == []const u8) {
                if (self.selected_ids.getEntry(id)) |entry| {
                    const key = entry.key_ptr.*;
                    _ = self.selected_ids.remove(id);
                    self.allocator.free(key);
                } else {
                    const key = try self.allocator.dupe(u8, id);
                    try self.selected_ids.put(key, {});
                }
            } else {
                if (self.selected_ids.contains(id)) {
                    _ = self.selected_ids.remove(id);
                } else {
                    try self.selected_ids.put(id, {});
                }
            }
        }

        pub fn clearSelection(self: *Self) void {
            if (IdT == []const u8) {
                var it = self.selected_ids.keyIterator();
                while (it.next()) |key| {
                    self.allocator.free(key.*);
                }
            }
            self.selected_ids.clearRetainingCapacity();
        }

        pub fn clearExpanded(self: *Self) void {
            if (IdT == []const u8) {
                var it = self.expanded_ids.keyIterator();
                while (it.next()) |key| {
                    self.allocator.free(key.*);
                }
            }
            self.expanded_ids.clearRetainingCapacity();
        }
    };
}

pub fn TreeMessage(comptime IdT: type) type {
    return union(enum) {
        click: struct { id: IdT, mods: i32 },
        toggle: IdT,
        drag_start: struct { id: IdT, pos: ?TreePos },
        drag_over: struct { target_id: IdT, drop_pos: DropPosition, drag_pos: ?TreePos },
        drop: struct { target_id: IdT, drop_pos: DropPosition },
        tick: bool, // is_dragging
    };
}

pub fn update(
    comptime IdT: type,
    comptime ItemT: type,
    state: *TreeState(IdT),
    items: []const ItemT,
    msg: TreeMessage(IdT),
) !void {
    switch (msg) {
        .click => |ci| {
            const is_ctrl = (ci.mods & 0x0002) != 0; // GLFW_MOD_CONTROL

            if (!is_ctrl) {
                if (treeFindItemById(ItemT, items, ci.id)) |item| {
                    const children = itemChildren(ItemT, @constCast(item));
                    const is_group = if (@hasField(ItemT, "is_group")) item.is_group else children.items.len > 0;
                    if (is_group) {
                        try state.toggleExpanded(ci.id);
                    }
                }
            }

            if (is_ctrl) {
                try state.toggleSelection(ci.id);
            } else if (state.isSelected(ci.id)) {} else {
                try state.selectOnly(ci.id);
            }
        },
        .toggle => |id| try state.toggleExpanded(id),
        .drag_start => |ds| {
            state.dragged_id = ds.id;
            state.drag_pos = ds.pos;
            state.drop_target_id = null;
            state.drop_target_pos = null;
            if (!state.isSelected(ds.id)) {
                try state.selectOnly(ds.id);
            }
        },
        .drag_over => |do| {
            if (state.dragged_id == null) return;
            state.drop_target_id = do.target_id;
            state.drop_target_pos = do.drop_pos;
            state.drag_pos = do.drag_pos;
        },
        .drop => {
            state.dragged_id = null;
            state.drag_pos = null;
            state.drop_target_id = null;
            state.drop_target_pos = null;
        },
        .tick => |is_dragging| {
            if (state.dragged_id != null and !is_dragging) {
                state.dragged_id = null;
                state.drag_pos = null;
                state.drop_target_id = null;
                state.drop_target_pos = null;
            }
        },
    }
}

pub fn updateAdapted(
    comptime ItemT: type,
    comptime Adapter: type,
    state: *TreeState([]const u8),
    items: []const ItemT,
    msg: TreeMessage([]const u8),
) !void {
    switch (msg) {
        .click => |ci| {
            const is_ctrl = (ci.mods & 0x0002) != 0; // GLFW_MOD_CONTROL

            if (!is_ctrl) {
                if (treeFindItemByIdAdapted(ItemT, Adapter, items, ci.id)) |item| {
                    if (Adapter.isGroup(item)) {
                        try state.toggleExpanded(ci.id);
                    }
                }
            }

            if (is_ctrl) {
                try state.toggleSelection(ci.id);
            } else if (!state.isSelected(ci.id)) {
                try state.selectOnly(ci.id);
            }
        },
        .toggle => |id| try state.toggleExpanded(id),
        .drag_start => |ds| {
            state.dragged_id = ds.id;
            state.drag_pos = ds.pos;
            state.drop_target_id = null;
            state.drop_target_pos = null;
            if (!state.isSelected(ds.id)) {
                try state.selectOnly(ds.id);
            }
        },
        .drag_over => |do| {
            if (state.dragged_id == null) return;
            state.drop_target_id = do.target_id;
            state.drop_target_pos = do.drop_pos;
            state.drag_pos = do.drag_pos;
        },
        .drop => {
            state.dragged_id = null;
            state.drag_pos = null;
            state.drop_target_id = null;
            state.drop_target_pos = null;
        },
        .tick => |is_dragging| {
            if (state.dragged_id != null and !is_dragging) {
                state.dragged_id = null;
                state.drag_pos = null;
                state.drop_target_id = null;
                state.drop_target_pos = null;
            }
        },
    }
}

pub fn TreeContext(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        items: []const TreeItem,

        build_row_content: *const fn (
            ctx: *UIContext(MessageT),
            item: TreeItem,
            userdata: ?*const anyopaque,
        ) anyerror!*Node(MessageT),

        wrap_message: ?*const fn (msg: TreeMessage([]const u8)) MessageT = null,

        userdata: ?*const anyopaque = null,

        dragged_item_id: ?[]const u8 = null,
        drag_pos: ?TreePos = null,
        drop_target_id: ?[]const u8 = null,
        drop_target_pos: ?DropPosition = null,
    };
}

pub fn RowEventData(comptime MessageT: type) type {
    return struct {
        wrap_message: *const fn (msg: TreeMessage([]const u8)) MessageT,
        item_id: []const u8,
        can_receive_children: bool,
    };
}

pub fn ClickData(comptime MessageT: type) type {
    return struct {
        wrap_message: *const fn (msg: TreeMessage([]const u8)) MessageT,
        item_id: []const u8,
    };
}

fn extractPos(data: types.EventData) ?TreePos {
    return switch (data) {
        .mouse => |m| .{ .x = m.x, .y = m.y },
        .drag => |d| .{ .x = d.x, .y = d.y },
        else => null,
    };
}

pub fn onClickHandle(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const self: *const RowEventData(MessageT) = @ptrCast(@alignCast(userdata.?));
            const mods = switch (data) {
                .mouse => |m| m.mods,
                .drag => |d| d.mods,
                else => 0,
            };
            return self.wrap_message(.{ .click = .{ .id = self.item_id, .mods = mods } });
        }
    }.handle;
}

pub fn DragStartData(comptime MessageT: type) type {
    return struct {
        wrap_message: *const fn (msg: TreeMessage([]const u8)) MessageT,
        item_id: []const u8,
    };
}

pub fn onDragStartHandle(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const self: *const RowEventData(MessageT) = @ptrCast(@alignCast(userdata.?));
            return self.wrap_message(.{ .drag_start = .{ .id = self.item_id, .pos = extractPos(data) } });
        }
    }.handle;
}

pub fn DragOverData(comptime MessageT: type) type {
    return struct {
        wrap_message: *const fn (msg: TreeMessage([]const u8)) MessageT,
        item_id: []const u8,
        can_receive_children: bool,
    };
}

pub fn onDragOverHandle(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, layout_res: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const self: *const RowEventData(MessageT) = @ptrCast(@alignCast(userdata.?));
            const mouse_y = switch (data) {
                .mouse => |m| m.y,
                .drag => |d| d.y,
                else => return null,
            };

            const rel_y = mouse_y - layout_res.y;
            const threshold = layout_res.height / 4.0;
            var pos: DropPosition = .inside;

            if (rel_y < threshold) {
                pos = .before;
            } else if (rel_y > layout_res.height - threshold) {
                pos = .after;
            }

            if (pos == .inside and !self.can_receive_children) {
                pos = if (rel_y < layout_res.height / 2.0) .before else .after;
            }

            return self.wrap_message(.{ .drag_over = .{
                .target_id = self.item_id,
                .drop_pos = pos,
                .drag_pos = extractPos(data),
            } });
        }
    }.handle;
}

pub fn DropData(comptime MessageT: type) type {
    return struct {
        wrap_message: *const fn (msg: TreeMessage([]const u8)) MessageT,
        item_id: []const u8,
        can_receive_children: bool,
    };
}

pub fn onDropHandle(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, layout_res: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const self: *const RowEventData(MessageT) = @ptrCast(@alignCast(userdata.?));
            const mouse_y = switch (data) {
                .mouse => |m| m.y,
                .drag => |d| d.y,
                else => return null,
            };

            const rel_y = mouse_y - layout_res.y;
            const threshold = layout_res.height / 4.0;
            var pos: DropPosition = .inside;

            if (rel_y < threshold) {
                pos = .before;
            } else if (rel_y > layout_res.height - threshold) {
                pos = .after;
            }

            if (pos == .inside and !self.can_receive_children) {
                pos = if (rel_y < layout_res.height / 2.0) .before else .after;
            }

            return self.wrap_message(.{ .drop = .{ .target_id = self.item_id, .drop_pos = pos } });
        }
    }.handle;
}

pub const TreeDescriptor = struct {
    style: layout.Style = .{},
    row_style: layout.Style = .{},
    indent_px: f32 = 16.0,
    expander_size: f32 = 20.0,
    expander_icon_id: u32 = CoreIcons.ArrowDropdown,
    expander_icon_tint: ?[4]f32 = null,
    show_indent_guides: bool = true,
    guide_line_color: ?[4]f32 = null,
    selection_indicator_width: f32 = 2.0,
    selection_indicator_color: ?[4]f32 = null,
    active_row_color: ?[4]f32 = null,
    hover_row_color: ?[4]f32 = null,
    drop_indicator_color: ?[4]f32 = null,
};

fn withAlpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], alpha };
}

pub fn TreeSourceLogic(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        build_row_content: *const fn (
            ctx: *UIContext(MessageT),
            item: TreeItem,
            userdata: ?*const anyopaque,
        ) anyerror!*Node(MessageT),
        wrap_message: *const fn (msg: TreeMessage([]const u8)) MessageT,
        userdata: ?*const anyopaque = null,
    };
}

pub fn buildFromSource(
    comptime MessageT: type,
    comptime ItemT: type,
    ctx: *UIContext(MessageT),
    state: *const TreeState([]const u8),
    root_items: []const ItemT,
    logic: TreeSourceLogic(MessageT),
    visuals: TreeDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    var visible_items = std.ArrayList(TreeItem).empty;
    defer visible_items.deinit(alloc);
    try flattenSource(ItemT, alloc, root_items, state, 0, &visible_items);

    return build(MessageT, ctx, .{
        .base_id = logic.base_id,
        .items = visible_items.items,
        .build_row_content = logic.build_row_content,
        .wrap_message = logic.wrap_message,
        .userdata = logic.userdata,
        .dragged_item_id = state.dragged_id,
        .drag_pos = state.drag_pos,
        .drop_target_id = state.drop_target_id,
        .drop_target_pos = state.drop_target_pos,
    }, visuals);
}

pub fn buildFromSourceAdapted(
    comptime MessageT: type,
    comptime ItemT: type,
    comptime Adapter: type,
    ctx: *UIContext(MessageT),
    state: *const TreeState([]const u8),
    root_items: []const ItemT,
    logic: TreeSourceLogic(MessageT),
    visuals: TreeDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    var visible_items = std.ArrayList(TreeItem).empty;
    defer visible_items.deinit(alloc);

    try flattenSourceAdapted(ItemT, Adapter, alloc, root_items, state, 0, &visible_items);

    return build(MessageT, ctx, .{
        .base_id = logic.base_id,
        .items = visible_items.items,
        .build_row_content = logic.build_row_content,
        .wrap_message = logic.wrap_message,
        .userdata = logic.userdata,
        .dragged_item_id = state.dragged_id,
        .drag_pos = state.drag_pos,
        .drop_target_id = state.drop_target_id,
        .drop_target_pos = state.drop_target_pos,
    }, visuals);
}

fn flattenSource(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    items: []const ItemT,
    state: *const TreeState([]const u8),
    depth: u32,
    out: *std.ArrayList(TreeItem),
) anyerror!void {
    for (items) |*item| {
        const id = itemId(ItemT, item);
        const children = itemChildren(ItemT, @constCast(item));
        const is_group = if (@hasField(ItemT, "is_group")) item.is_group else children.items.len > 0;
        const is_expanded = state.isExpanded(id);
        const is_selected = state.isSelected(id);

        try out.append(allocator, .{
            .id = id,
            .depth = depth,
            .is_group = is_group,
            .is_expanded = is_expanded,
            .is_selected = is_selected,
            .can_receive_children = is_group,
        });

        if (is_expanded) {
            try flattenSource(ItemT, allocator, children.items, state, depth + 1, out);
        }
    }
}

fn flattenSourceAdapted(
    comptime ItemT: type,
    comptime Adapter: type,
    allocator: std.mem.Allocator,
    items: []const ItemT,
    state: *const TreeState([]const u8),
    depth: u32,
    out: *std.ArrayList(TreeItem),
) anyerror!void {
    for (items) |*item| {
        const id = Adapter.id(item);
        const is_group = Adapter.isGroup(item);
        const is_expanded = state.isExpanded(id);

        try out.append(allocator, .{
            .id = id,
            .depth = depth,
            .is_group = is_group,
            .is_expanded = is_expanded,
            .is_selected = state.isSelected(id),
            .can_receive_children = is_group,
        });

        if (is_group and is_expanded) {
            try flattenSourceAdapted(
                ItemT,
                Adapter,
                allocator,
                Adapter.children(item),
                state,
                depth + 1,
                out,
            );
        }
    }
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: TreeContext(MessageT),
    visuals: TreeDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    const tokens = ctx.active_theme.tokens;
    const rows = try alloc.alloc(?*Node(MessageT), logic.items.len);

    for (logic.items, 0..) |item, i| {
        rows[i] = try buildRow(MessageT, ctx, logic, visuals, item);
    }

    var portal_node: ?*Node(MessageT) = null;
    if (logic.dragged_item_id) |dragged_id| {
        if (logic.drag_pos) |pos| {
            var dragged_item: ?TreeItem = null;
            for (logic.items) |item| {
                if (std.mem.eql(u8, item.id, dragged_id)) {
                    dragged_item = item;
                    break;
                }
            }

            if (dragged_item) |item| {
                const preview_content = try logic.build_row_content(ctx, item, logic.userdata);
                var preview_style = visuals.row_style;
                preview_style.position = .absolute;
                preview_style.left = pos.x + 10.0;
                preview_style.top = pos.y + 10.0;
                preview_style.pointer_events = .none;
                preview_style.opacity = 0.9;
                preview_style.z_index = 1000;
                if (preview_style.background_color[3] == 0.0) {
                    preview_style.background_color = withAlpha(tokens.bg_surface, 0.95);
                }
                if (!preview_style.border.hasAny()) {
                    preview_style.border = layout.Border.all(1.0, withAlpha(tokens.border_subtle, 0.8));
                }
                if (preview_style.shadow_color[3] == 0.0) {
                    preview_style.shadow_color = .{ 0.0, 0.0, 0.0, 0.25 };
                    preview_style.shadow_blur = 10.0;
                    preview_style.shadow_offset = .{ 0.0, 4.0 };
                }

                const preview_node = try ctx.div(.{
                    .id = deriveChildId(logic.base_id, "drag_preview"),
                    .style = preview_style,
                    .children = &.{preview_content},
                });

                portal_node = try ctx.portal(.{
                    .id = deriveChildId(logic.base_id, "drag_portal"),
                    .children = &.{preview_node},
                });
            }
        }
    }

    var tree_style = visuals.style;
    tree_style.direction = .Column;

    const children = if (portal_node) |p|
        try alloc.dupe(?*Node(MessageT), &.{ try ctx.div(.{
            .id = deriveChildId(logic.base_id, "rows_container"),
            .style = .{ .direction = .Column, .width = .Full },
            .children = rows,
        }), p })
    else
        rows;

    return ctx.div(.{
        .id = deriveChildId(logic.base_id, "root"),
        .style = tree_style,
        .children = children,
    });
}

fn buildRow(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: TreeContext(MessageT),
    visuals: TreeDescriptor,
    item: TreeItem,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    const event_alloc = ctx.gpa;
    const tokens = ctx.active_theme.tokens;

    var row_children = std.ArrayList(?*Node(MessageT)).empty;
    defer row_children.deinit(alloc);

    const selected_color = visuals.active_row_color orelse withAlpha(tokens.action_default, 0.24);
    const hover_color = visuals.hover_row_color orelse withAlpha(tokens.action_default, 0.14);
    const guide_color = visuals.guide_line_color orelse withAlpha(tokens.border_subtle, 0.55);
    const selection_indicator_color = visuals.selection_indicator_color orelse tokens.action_default;
    const drop_indicator_color = visuals.drop_indicator_color orelse tokens.action_default;

    const gutter_w = visuals.selection_indicator_width + 6.0;
    const gutter = try ctx.div(.{
        .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_gutter", .{item.id})),
        .style = .{
            .width = .{ .exact = gutter_w },
            .pointer_events = .none,
        },
    });
    try row_children.append(alloc, gutter);

    if (item.depth > 0) {
        const indent_width = @as(f32, @floatFromInt(item.depth)) * visuals.indent_px;
        if (visuals.show_indent_guides) {
            const guide_nodes = try alloc.alloc(?*Node(MessageT), item.depth);
            for (0..item.depth) |level| {
                const line = try ctx.div(.{
                    .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_guide_line_{d}", .{ item.id, level })),
                    .style = .{
                        .width = .{ .exact = 1.0 },
                        .background_color = guide_color,
                        .pointer_events = .none,
                    },
                });
                guide_nodes[level] = try ctx.div(.{
                    .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_guide_slot_{d}", .{ item.id, level })),
                    .style = .{
                        .width = .{ .exact = visuals.indent_px },
                        .direction = .Row,
                        .align_items = .Stretch,
                        .justify_content = .Center,
                        .pointer_events = .none,
                    },
                    .children = &.{line},
                });
            }
            try row_children.append(alloc, try ctx.div(.{
                .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_indent_guides", .{item.id})),
                .style = .{
                    .direction = .Row,
                    .width = .{ .exact = indent_width },
                    .align_items = .Stretch,
                    .pointer_events = .none,
                },
                .children = guide_nodes,
            }));
        } else {
            try row_children.append(alloc, try ctx.div(.{
                .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_indent", .{item.id})),
                .style = .{ .width = .{ .exact = indent_width }, .pointer_events = .none },
            }));
        }
    }

    if (item.is_group) {
        const toggle_msg = if (logic.wrap_message) |wrap| wrap(.{ .toggle = item.id }) else null;
        const expander_style = layout.Style{
            .width = .{ .exact = visuals.expander_size },
            .height = .{ .exact = visuals.expander_size },
            .align_items = .Center,
            .align_self = .Center,
            .justify_content = .Center,
            .cursor = .pointer,
            .margin = .{ .right = 4.0 },
            .corner_radius = layout.CornerRadius.all(3.0),
            .hover_color = withAlpha(tokens.bg_surface, 0.8),
        };

        const expander_events = if (toggle_msg) |msg|
            try alloc.dupe(types.EventBinding(MessageT), &.{dupeMessageBinding(MessageT, .click, msg)})
        else
            &[_]types.EventBinding(MessageT){};

        const icon_size = @max(14.0, visuals.expander_size + 2.0);
        const icon_style = layout.Style{
            .width = .{ .exact = icon_size },
            .height = .{ .exact = icon_size },
            .align_self = .Center,
            .pointer_events = .none,
            .transform = .{ .rotate = if (item.is_expanded) 0.0 else std.math.pi * 3.0 / 2.0 },
        };

        const expander_icon = try icon_impl.build(MessageT, ctx, .{
            .icon_id = visuals.expander_icon_id,
            .intrinsic_size = .{ icon_size, icon_size },
            .style = icon_style,
            .tint = visuals.expander_icon_tint orelse tokens.text_muted,
        });

        try row_children.append(alloc, try ctx.div(.{
            .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_expander", .{item.id})),
            .style = expander_style,
            .events = expander_events,
            .children = &.{expander_icon},
        }));
    } else {
        try row_children.append(alloc, try ctx.div(.{
            .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_expander_spacer", .{item.id})),
            .style = .{ .width = .{ .exact = visuals.expander_size + 4.0 } },
        }));
    }

    var row_style = visuals.row_style;
    const vertical_padding = layout.Spacing{
        .top = row_style.padding.top,
        .bottom = row_style.padding.bottom,
    };
    row_style.padding.top = 0;
    row_style.padding.bottom = 0;

    const user_content = try logic.build_row_content(ctx, item, logic.userdata);
    try row_children.append(alloc, try ctx.div(.{
        .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_content_wrapper", .{item.id})),
        .style = .{
            .direction = .Row,
            .align_self = .Center,
            .flex_grow = 1,
            .padding = vertical_padding,
        },
        .children = &.{user_content},
    }));

    row_style.direction = .Row;
    row_style.align_items = .Stretch;
    row_style.cursor = .pointer;
    row_style.width = .Full;
    row_style.position = .relative;
    if (row_style.hover_color == null) {
        row_style.hover_color = hover_color;
    }
    row_style.background_color = if (item.is_selected) selected_color else .{ 0.0, 0.0, 0.0, 0.0 };

    var overlay_children = std.ArrayList(?*Node(MessageT)).empty;
    defer overlay_children.deinit(alloc);

    if (item.is_selected) {
        try overlay_children.append(alloc, try ctx.div(.{
            .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_selection_overlay", .{item.id})),
            .style = .{
                .position = .absolute,
                .left = 0.0,
                .top = 0.0,
                .bottom = 0.0,
                .width = .{ .exact = visuals.selection_indicator_width },
                .background_color = selection_indicator_color,
                .corner_radius = layout.CornerRadius.all(visuals.selection_indicator_width * 0.5),
                .pointer_events = .none,
            },
        }));
    }

    if (logic.drop_target_id) |drop_target_id| {
        if (logic.drop_target_pos) |drop_pos| {
            if (std.mem.eql(u8, drop_target_id, item.id)) {
                switch (drop_pos) {
                    .before => try overlay_children.append(alloc, try ctx.div(.{
                        .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_drop_before", .{item.id})),
                        .style = .{
                            .position = .absolute,
                            .left = 0.0,
                            .right = 0.0,
                            .top = 0.0,
                            .height = .{ .exact = 2.0 },
                            .background_color = drop_indicator_color,
                            .pointer_events = .none,
                        },
                    })),
                    .after => try overlay_children.append(alloc, try ctx.div(.{
                        .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_drop_after", .{item.id})),
                        .style = .{
                            .position = .absolute,
                            .left = 0.0,
                            .right = 0.0,
                            .bottom = 0.0,
                            .height = .{ .exact = 2.0 },
                            .background_color = drop_indicator_color,
                            .pointer_events = .none,
                        },
                    })),
                    .inside => try overlay_children.append(alloc, try ctx.div(.{
                        .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_drop_inside", .{item.id})),
                        .style = .{
                            .position = .absolute,
                            .left = 0.0,
                            .right = 0.0,
                            .top = 0.0,
                            .bottom = 0.0,
                            .border = layout.Border.all(1.0, withAlpha(drop_indicator_color, 0.95)),
                            .background_color = withAlpha(drop_indicator_color, 0.1),
                            .pointer_events = .none,
                        },
                    })),
                }
            }
        }
    }

    if (overlay_children.items.len > 0) {
        try row_children.append(alloc, try ctx.div(.{
            .id = deriveChildId(logic.base_id, try std.fmt.allocPrint(alloc, "{s}_overlay_root", .{item.id})),
            .style = .{
                .position = .absolute,
                .left = 0.0,
                .right = 0.0,
                .top = 0.0,
                .bottom = 0.0,
                .pointer_events = .none,
            },
            .children = try overlay_children.toOwnedSlice(alloc),
        }));
    }

    var events_buf: [4]types.EventBinding(MessageT) = undefined;
    var events_count: usize = 0;

    if (logic.wrap_message) |wrap| {
        const row_data = try event_alloc.create(RowEventData(MessageT));
        row_data.* = .{
            .wrap_message = wrap,
            .item_id = item.id,
            .can_receive_children = item.can_receive_children,
        };
        const destroy = destroyOwnedEventUserdata(RowEventData(MessageT));

        events_buf[events_count] = .{
            .event = .click,
            .userdata = row_data,
            .destroy_userdata = destroy,
            .handler = onClickHandle(MessageT),
        };
        events_count += 1;

        events_buf[events_count] = .{
            .event = .drag,
            .userdata = row_data,
            .handler = onDragStartHandle(MessageT),
        };
        events_count += 1;

        events_buf[events_count] = .{
            .event = .pointer_move,
            .userdata = row_data,
            .handler = onDragOverHandle(MessageT),
        };
        events_count += 1;

        events_buf[events_count] = .{
            .event = .pointer_up,
            .userdata = row_data,
            .handler = onDropHandle(MessageT),
        };
        events_count += 1;
    }

    return ctx.div(.{
        .id = deriveChildId(logic.base_id, item.id),
        .style = row_style,
        .children = try row_children.toOwnedSlice(alloc),
        .events = try alloc.dupe(types.EventBinding(MessageT), events_buf[0..events_count]),
    });
}

fn assertTreeItemShape(comptime ItemT: type) void {
    if (!@hasField(ItemT, "id")) {
        @compileError("Tree helpers require ItemT to have an `id: []const u8` field.");
    }
    if (!@hasField(ItemT, "children")) {
        @compileError("Tree helpers require ItemT to have a `children: std.ArrayList(ItemT)` field.");
    }
}

fn itemId(comptime ItemT: type, item: *const ItemT) []const u8 {
    assertTreeItemShape(ItemT);
    return @field(item.*, "id");
}

fn itemChildren(comptime ItemT: type, item: *ItemT) *std.ArrayList(ItemT) {
    assertTreeItemShape(ItemT);
    return &@field(item.*, "children");
}

fn treeContainsId(comptime ItemT: type, items: []const ItemT, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, itemId(ItemT, &item), id)) return true;
        const children = @field(item, "children");
        if (treeContainsId(ItemT, children.items, id)) return true;
    }
    return false;
}

fn treeFindItemById(comptime ItemT: type, items: []const ItemT, id: []const u8) ?*const ItemT {
    for (items) |*item| {
        if (std.mem.eql(u8, itemId(ItemT, item), id)) return item;
        const children = @field(item.*, "children");
        if (treeFindItemById(ItemT, children.items, id)) |found| return found;
    }
    return null;
}

fn treeFindItemByIdAdapted(
    comptime ItemT: type,
    comptime Adapter: type,
    items: []const ItemT,
    id: []const u8,
) ?*const ItemT {
    for (items) |*item| {
        if (std.mem.eql(u8, Adapter.id(item), id)) return item;
        if (treeFindItemByIdAdapted(ItemT, Adapter, Adapter.children(item), id)) |found| return found;
    }
    return null;
}

fn treeRemoveItemById(comptime ItemT: type, items: *std.ArrayList(ItemT), id: []const u8) ?ItemT {
    for (items.items, 0..) |*item, index| {
        if (std.mem.eql(u8, itemId(ItemT, item), id)) {
            return items.orderedRemove(index);
        }
        if (treeRemoveItemById(ItemT, itemChildren(ItemT, item), id)) |removed| return removed;
    }
    return null;
}

fn treeInsertRelative(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ItemT),
    target_id: []const u8,
    moved: ItemT,
    pos: DropPosition,
) !bool {
    for (items.items, 0..) |*item, index| {
        if (std.mem.eql(u8, itemId(ItemT, item), target_id)) {
            const insert_at = if (pos == .after) index + 1 else index;
            try items.insert(allocator, insert_at, moved);
            return true;
        }
        if (try treeInsertRelative(ItemT, allocator, itemChildren(ItemT, item), target_id, moved, pos)) return true;
    }
    return false;
}

fn treeInsertInside(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ItemT),
    target_id: []const u8,
    moved: ItemT,
) !bool {
    for (items.items) |*item| {
        if (std.mem.eql(u8, itemId(ItemT, item), target_id)) {
            if (@hasField(ItemT, "is_group")) {
                @field(item.*, "is_group") = true;
            }
            if (@hasField(ItemT, "is_expanded")) {
                @field(item.*, "is_expanded") = true;
            }
            try itemChildren(ItemT, item).append(allocator, moved);
            return true;
        }
        if (try treeInsertInside(ItemT, allocator, itemChildren(ItemT, item), target_id, moved)) return true;
    }
    return false;
}

pub fn collectTopLevelSelectedIds(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    items: []const ItemT,
    selected_ids: *const std.StringHashMap(void),
    out: *std.ArrayList([]const u8),
) !void {
    return collectTopLevelSelectedIdsInner(ItemT, allocator, items, selected_ids, false, out);
}

fn collectTopLevelSelectedIdsInner(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    items: []const ItemT,
    selected_ids: *const std.StringHashMap(void),
    ancestor_selected: bool,
    out: *std.ArrayList([]const u8),
) !void {
    for (items) |item| {
        const id = itemId(ItemT, &item);
        const is_selected = selected_ids.contains(id);
        if (is_selected and !ancestor_selected) {
            try out.append(allocator, id);
        }
        const children = @field(item, "children");
        try collectTopLevelSelectedIdsInner(ItemT, allocator, children.items, selected_ids, ancestor_selected or is_selected, out);
    }
}

pub fn applyDropMessage(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    state: *TreeState([]const u8),
    root_items: *std.ArrayList(ItemT),
    target_id: []const u8,
    drop_pos: DropPosition,
    options: struct {
        userdata: ?*anyopaque = null,
        validate: ?*const fn (
            userdata: ?*anyopaque,
            src: []const u8,
            target_id: []const u8,
            drop_pos: DropPosition,
        ) bool = null,
    },
) !bool {
    const dragged_id = state.dragged_id orelse return false;

    var drag_ids = std.ArrayList([]const u8).empty;
    defer drag_ids.deinit(allocator);

    if (state.isSelected(dragged_id)) {
        try collectTopLevelSelectedIds(ItemT, allocator, root_items.items, &state.selected_ids, &drag_ids);
    }
    if (drag_ids.items.len == 0) {
        try drag_ids.append(allocator, dragged_id);
    }

    if (options.validate) |validate| {
        var write: usize = 0;
        for (drag_ids.items) |src| {
            if (validate(options.userdata, src, target_id, drop_pos)) {
                drag_ids.items[write] = src;
                write += 1;
            }
        }
        drag_ids.shrinkRetainingCapacity(write);
    }

    return applyDrop(ItemT, allocator, root_items, drag_ids.items, target_id, drop_pos);
}

pub fn applyDrop(
    comptime ItemT: type,
    allocator: std.mem.Allocator,
    root_items: *std.ArrayList(ItemT),
    dragged_ids: []const []const u8,
    target_id: []const u8,
    pos: DropPosition,
) !bool {
    assertTreeItemShape(ItemT);
    if (dragged_ids.len == 0) return false;
    if (!treeContainsId(ItemT, root_items.items, target_id)) return false;

    var moved_any = false;
    if (pos == .after) {
        var i: usize = dragged_ids.len;
        while (i > 0) : (i -= 1) {
            const drag_id = dragged_ids[i - 1];
            if (std.mem.eql(u8, drag_id, target_id)) continue;
            if (!treeContainsId(ItemT, root_items.items, drag_id)) continue;
            if (treeFindItemById(ItemT, root_items.items, drag_id)) |src| {
                const src_children = @field(src.*, "children");
                if (treeContainsId(ItemT, src_children.items, target_id)) continue;
            } else continue;

            var moved = treeRemoveItemById(ItemT, root_items, drag_id) orelse continue;
            errdefer {
                if (@hasDecl(ItemT, "deinit")) moved.deinit(allocator);
            }
            if (try treeInsertRelative(ItemT, allocator, root_items, target_id, moved, pos)) {
                moved_any = true;
            }
        }
    } else {
        for (dragged_ids) |drag_id| {
            if (std.mem.eql(u8, drag_id, target_id)) continue;
            if (!treeContainsId(ItemT, root_items.items, drag_id)) continue;
            if (treeFindItemById(ItemT, root_items.items, drag_id)) |src| {
                const src_children = @field(src.*, "children");
                if (treeContainsId(ItemT, src_children.items, target_id)) continue;
            } else continue;

            var moved = treeRemoveItemById(ItemT, root_items, drag_id) orelse continue;
            errdefer {
                if (@hasDecl(ItemT, "deinit")) moved.deinit(allocator);
            }
            const inserted = if (pos == .inside)
                try treeInsertInside(ItemT, allocator, root_items, target_id, moved)
            else
                try treeInsertRelative(ItemT, allocator, root_items, target_id, moved, pos);
            if (inserted) moved_any = true;
        }
    }

    return moved_any;
}
