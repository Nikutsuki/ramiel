const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const deriveChildId = @import("id.zig").deriveChildId;

pub const Axis = enum { horizontal, vertical };
const MAX_POOL_SIZE: usize = 256;

const FenwickTree = struct {
    allocator: std.mem.Allocator,
    tree: []f64,
    deltas: []f64,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) FenwickTree {
        const tree = allocator.alloc(f64, initial_capacity + 1) catch unreachable;
        const deltas = allocator.alloc(f64, initial_capacity) catch unreachable;
        @memset(tree, 0.0);
        @memset(deltas, 0.0);
        return .{ .allocator = allocator, .tree = tree, .deltas = deltas };
    }

    pub fn deinit(self: *FenwickTree) void {
        self.allocator.free(self.tree);
        self.allocator.free(self.deltas);
    }

    pub fn capacity(self: *const FenwickTree) usize {
        return self.deltas.len;
    }

    pub fn reset(self: *FenwickTree) void {
        @memset(self.tree, 0.0);
        @memset(self.deltas, 0.0);
    }

    fn rebuildTree(self: *FenwickTree) void {
        @memset(self.tree, 0.0);
        for (self.deltas, 0..) |delta, idx| {
            const tree_idx = idx + 1;
            self.tree[tree_idx] += delta;
            const parent = tree_idx + lowbit(tree_idx);
            if (parent < self.tree.len) {
                self.tree[parent] += self.tree[tree_idx];
            }
        }
    }

    pub fn shiftLeftAndRebuild(self: *FenwickTree, shift_amount: usize) void {
        if (shift_amount == 0) return;
        if (shift_amount >= self.deltas.len) {
            self.reset();
            return;
        }
        const new_len = self.deltas.len - shift_amount;
        std.mem.copyForwards(f64, self.deltas[0..new_len], self.deltas[shift_amount..self.deltas.len]);
        @memset(self.deltas[new_len..], 0.0);
        self.rebuildTree();
    }

    pub fn shiftRightAndRebuild(self: *FenwickTree, shift_amount: usize, new_total: usize) void {
        self.ensureCapacity(new_total);

        const old_len = self.deltas.len - shift_amount;
        std.mem.copyBackwards(f64, self.deltas[shift_amount..new_total], self.deltas[0..old_len]);

        @memset(self.deltas[0..shift_amount], 0.0);

        self.rebuildTree();
    }

    pub fn ensureCapacity(self: *FenwickTree, needed_capacity: usize) void {
        if (needed_capacity <= self.capacity()) return;

        const new_tree = self.allocator.alloc(f64, needed_capacity + 1) catch unreachable;
        const new_deltas = self.allocator.alloc(f64, needed_capacity) catch unreachable;
        @memset(new_tree, 0.0);
        @memset(new_deltas, 0.0);
        @memcpy(new_deltas[0..self.deltas.len], self.deltas);

        self.allocator.free(self.tree);
        self.allocator.free(self.deltas);
        self.tree = new_tree;
        self.deltas = new_deltas;
        self.rebuildTree();
    }

    pub fn update(self: *FenwickTree, index: usize, new_delta: f64) bool {
        if (index >= self.deltas.len) return false;
        const diff = new_delta - self.deltas[index];
        if (diff == 0.0) return false;

        self.deltas[index] = new_delta;
        var i: usize = index + 1;
        while (i < self.tree.len) {
            self.tree[i] += diff;
            i += lowbit(i);
        }
        return true;
    }

    pub fn queryPrefix(self: *const FenwickTree, index_exclusive: usize) f64 {
        var sum: f64 = 0.0;
        var i: usize = @min(index_exclusive, self.deltas.len);
        while (i > 0) {
            sum += self.tree[i];
            i -= lowbit(i);
        }
        return sum;
    }

    fn lowbit(value: usize) usize {
        return value & (~value +% 1);
    }
};

pub const VirtualListState = struct {
    axis: Axis,
    total_items: usize,
    scroll_offset: f64 = 0.0,
    viewport_size: f64 = 0.0,
    is_scrolling: bool = false,

    active_start_idx: usize = 0,
    active_end_idx: usize = 0,

    layout_cache: FenwickTree,
    fallback_estimate: f64 = 50.0,
    thumb_drag_ratio: f64 = 1.0,
    thumb_on_scroll_userdata: ?*const anyopaque = null,
    thumb_on_drag_state_change_userdata: ?*const anyopaque = null,
    gap: f64 = 0.0,
    stick_to_bottom: bool = false,
    layout_freeze_frames: u8 = 0,

    last_base_id: types.NodeId = 0,

    ignore_next_reconcile: bool = false,

    pub fn init(allocator: std.mem.Allocator, axis: Axis, total: usize) VirtualListState {
        return .{
            .axis = axis,
            .total_items = total,
            .layout_cache = FenwickTree.init(allocator, total),
        };
    }

    pub fn deinit(self: *VirtualListState) void {
        self.layout_cache.deinit();
    }

    pub fn resetMeasurements(self: *VirtualListState) void {
        self.layout_cache.reset();
        self.scroll_offset = 0.0;
        self.stick_to_bottom = false;
    }

    pub fn setTotalItems(self: *VirtualListState, total: usize) void {
        self.layout_cache.ensureCapacity(total);
        self.total_items = total;
        if (self.active_start_idx > total) self.active_start_idx = total;
        if (self.active_end_idx > total) self.active_end_idx = total;
        const content_size = @max(0.0, self.getPredictedTotalSize() - if (self.total_items > 0) self.gap else 0.0);
        const max_scroll = @max(0.0, content_size - self.viewport_size);
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0.0, max_scroll);
    }

    pub fn recordMeasurement(self: *VirtualListState, index: usize, size: f64) void {
        if (index >= self.total_items) return;
        self.layout_cache.ensureCapacity(self.total_items);
        const clamped = @max(size, 1.0);
        const total_item_size = clamped + self.gap;
        const delta = total_item_size - self.fallback_estimate;
        _ = self.layout_cache.update(index, delta);
    }

    fn getDeltaPrefix(self: *const VirtualListState, index_exclusive: usize) f64 {
        return self.layout_cache.queryPrefix(index_exclusive);
    }

    pub fn getPredictedTotalSize(self: *const VirtualListState) f64 {
        const base = @as(f64, @floatFromInt(self.total_items)) * self.fallback_estimate;
        return base + self.getDeltaPrefix(self.total_items);
    }

    pub fn getOffsetForIndex(self: *const VirtualListState, target_index: usize) f64 {
        const upper = @min(target_index, self.total_items);
        const base = @as(f64, @floatFromInt(upper)) * self.fallback_estimate;
        return base + self.getDeltaPrefix(upper);
    }

    pub fn getSizeForIndex(self: *const VirtualListState, index: usize) f64 {
        if (index >= self.total_items or index >= self.layout_cache.capacity()) return self.fallback_estimate;
        return self.fallback_estimate + self.layout_cache.deltas[index];
    }

    pub fn shiftItemsLeft(
        self: *VirtualListState,
        comptime MessageT: type,
        ui: *UIContext(MessageT),
        base_id: types.NodeId,
        shift_amount: usize,
    ) void {
        if (shift_amount == 0) return;

        const exact_dropped_height = self.getOffsetForIndex(shift_amount);
        self.layout_cache.shiftLeftAndRebuild(shift_amount);

        if (self.scroll_offset >= exact_dropped_height) {
            self.scroll_offset -= exact_dropped_height;
        } else {
            self.scroll_offset = 0.0;
        }

        self.active_start_idx = if (self.active_start_idx > shift_amount) self.active_start_idx - shift_amount else 0;
        self.active_end_idx = if (self.active_end_idx > shift_amount) self.active_end_idx - shift_amount else 0;

        self.layout_freeze_frames = 2;

        const scroll_id = deriveChildId(base_id, "scroll_view");
        if (ui.getById(scroll_id)) |node| {
            if (self.axis == .vertical) {
                node.scroll_y = @floatCast(self.scroll_offset);
            } else {
                node.scroll_x = @floatCast(self.scroll_offset);
            }
            node.markPositionDirty();
        }
    }

    pub fn prependItems(
        self: *VirtualListState,
        comptime MessageT: type,
        ui: *UIContext(MessageT),
        base_id: types.NodeId,
        new_count: usize,
    ) void {
        if (new_count == 0) return;

        self.total_items += new_count;

        self.layout_cache.shiftRightAndRebuild(new_count, self.total_items);

        const inserted_height = @as(f64, @floatFromInt(new_count)) * self.fallback_estimate;
        self.scroll_offset += inserted_height;

        self.active_start_idx += new_count;
        self.active_end_idx += new_count;

        const scroll_id = deriveChildId(base_id, "scroll_view");
        if (ui.getById(scroll_id)) |node| {
            if (self.axis == .vertical) {
                node.scroll_y = @floatCast(self.scroll_offset);
            } else {
                node.scroll_x = @floatCast(self.scroll_offset);
            }
            node.markPositionDirty();
        }
    }
};

pub const VirtualListDescriptor = struct {
    style: layout.Style = .{},
};

pub fn VirtualListContext(comptime MessageT: type) type {
    return struct {
        base_id: types.NodeId,
        state: *VirtualListState,
        on_need_data: *const fn (start: usize, end: usize) MessageT,
        on_scroll: *const fn (delta: f32) MessageT,
        on_drag_state_change: ?*const fn (is_dragging: bool) MessageT = null,
        build_item_fn: *const fn (ctx: *UIContext(MessageT), index: usize, userdata: ?*const anyopaque) anyerror!*Node(MessageT),
        build_userdata: ?*const anyopaque = null,
    };
}

pub fn itemNodeId(base_id: types.NodeId, slot: usize) types.NodeId {
    var key_buf: [48]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "item_slot_{d}", .{slot}) catch "item_slot";
    return deriveChildId(base_id, key);
}

pub fn applyScrollDelta(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    state: *VirtualListState,
    base_id: types.NodeId,
    delta: f32,
) bool {
    const scroll_id = deriveChildId(base_id, "scroll_view");
    const content_size = @max(0.0, state.getPredictedTotalSize() - if (state.total_items > 0) state.gap else 0.0);
    const max_scroll = @max(0.0, content_size - state.viewport_size);

    if (max_scroll <= 0.0) return false;

    state.scroll_offset = std.math.clamp(state.scroll_offset + @as(f64, @floatCast(delta)), 0.0, max_scroll);

    if (state.scroll_offset >= max_scroll - 1.0) {
        state.stick_to_bottom = true;
    } else {
        state.stick_to_bottom = false;
    }

    if (ui.getById(scroll_id)) |node| {
        if (state.axis == .vertical) {
            node.scroll_y = @floatCast(state.scroll_offset);
        } else {
            node.scroll_x = @floatCast(state.scroll_offset);
        }
        node.markPositionDirty();
    }

    return true;
}

pub fn scrollToEnd(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    state: *VirtualListState,
    base_id: types.NodeId,
) bool {
    state.stick_to_bottom = true;
    const scroll_id = deriveChildId(base_id, "scroll_view");
    const content_size = @max(0.0, state.getPredictedTotalSize() - if (state.total_items > 0) state.gap else 0.0);
    const max_scroll = @max(0.0, content_size - state.viewport_size);
    state.scroll_offset = max_scroll;

    if (ui.getById(scroll_id)) |node| {
        if (state.axis == .vertical) {
            node.scroll_y = @floatCast(state.scroll_offset);
        } else {
            node.scroll_x = @floatCast(state.scroll_offset);
        }
        node.markPositionDirty();
    }

    return max_scroll > 0.0;
}

fn pointerLockDownHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, _: types.EventData) ?MessageT {
            const fn_ptr: *const fn (bool) MessageT = @ptrCast(@alignCast(userdata.?));
            return fn_ptr(true);
        }
    }.handle;
}

fn pointerLockUpHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, _: types.EventData) ?MessageT {
            const fn_ptr: *const fn (bool) MessageT = @ptrCast(@alignCast(userdata.?));
            return fn_ptr(false);
        }
    }.handle;
}

fn thumbInteractionHandler(comptime MessageT: type, comptime axis: Axis) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const list_state: *const VirtualListState = @ptrCast(@alignCast(userdata.?));
            const on_scroll_any = list_state.thumb_on_scroll_userdata orelse return null;
            const on_scroll: *const fn (f32) MessageT = @ptrCast(@alignCast(on_scroll_any));
            switch (data) {
                .drag => |d| {
                    const raw_delta = if (axis == .vertical) d.dy else d.dx;
                    return on_scroll(raw_delta * @as(f32, @floatCast(list_state.thumb_drag_ratio)));
                },
                .scroll => |s| {
                    const raw_delta = if (axis == .vertical)
                        -s.dy * 40.0
                    else if (s.dx != 0.0)
                        -s.dx * 40.0
                    else
                        -s.dy * 40.0;
                    return on_scroll(raw_delta);
                },
                else => return null,
            }
        }
    }.handle;
}

fn thumbDragStartHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, _: types.EventData) ?MessageT {
            const list_state: *VirtualListState = @ptrCast(@alignCast(@constCast(userdata.?)));
            list_state.is_scrolling = true;
            if (list_state.thumb_on_drag_state_change_userdata) |ptr| {
                const cb: *const fn (bool) MessageT = @ptrCast(@alignCast(ptr));
                return cb(true);
            }
            return null;
        }
    }.handle;
}

fn thumbDragEndHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, _: types.EventData) ?MessageT {
            const list_state: *VirtualListState = @ptrCast(@alignCast(@constCast(userdata.?)));
            list_state.is_scrolling = false;
            if (list_state.thumb_on_drag_state_change_userdata) |ptr| {
                const cb: *const fn (bool) MessageT = @ptrCast(@alignCast(ptr));
                return cb(false);
            }
            return null;
        }
    }.handle;
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: VirtualListContext(MessageT),
    descriptor: VirtualListDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    const state = logic.state;
    state.last_base_id = logic.base_id;
    state.gap = @as(f64, @floatCast(descriptor.style.gap));
    ctx.registerPostLayoutHook(.{
        .userdata = @ptrCast(state),
        .callback = postLayoutHook(MessageT),
    }) catch {};
    if (syncViewportFromNative(MessageT, state, ctx, logic.base_id)) {
        ctx.interaction_registry.rebuild_requested = true;
    }
    const true_content_size = @max(0.0, state.getPredictedTotalSize() - if (state.total_items > 0) state.gap else 0.0);
    const absolute_max_scroll = @max(0.0, true_content_size - state.viewport_size);
    if (state.stick_to_bottom) {
        state.scroll_offset = absolute_max_scroll;
    } else {
        state.scroll_offset = std.math.clamp(state.scroll_offset, 0.0, absolute_max_scroll);
    }

    const buffer_size = state.viewport_size * 2.0;
    const start_offset = @max(0.0, state.scroll_offset - buffer_size);
    const end_offset = state.scroll_offset + state.viewport_size + buffer_size;

    const start_idx = findIndexForOffset(state, start_offset);
    const end_idx = @min(state.total_items, findIndexForOffset(state, end_offset) + 1);
    const active_count = end_idx - start_idx;
    std.debug.assert(active_count <= MAX_POOL_SIZE);

    state.active_start_idx = start_idx;
    state.active_end_idx = end_idx;
    const need_data_msg = logic.on_need_data(start_idx, end_idx);

    var active_items = std.ArrayList(*Node(MessageT)).empty;
    defer active_items.deinit(alloc);

    for (start_idx..end_idx) |i| {
        const slot = i % MAX_POOL_SIZE;
        const node = try logic.build_item_fn(ctx, i, logic.build_userdata);

        var wrapper_style = layout.Style{
            .position = .absolute,
        };

        if (state.axis == .vertical) {
            wrapper_style.top = @floatCast(state.getOffsetForIndex(i));
            wrapper_style.left = 0.0;
            wrapper_style.width = .Full;
        } else {
            wrapper_style.left = @floatCast(state.getOffsetForIndex(i));
            wrapper_style.top = 0.0;
            wrapper_style.height = .Full;
        }

        const wrapper = try ctx.div(.{
            .id = itemNodeId(logic.base_id, slot),
            .style = wrapper_style,
            .children = try alloc.dupe(*Node(MessageT), &.{node}),
        });

        try active_items.append(alloc, wrapper);
    }

    var content_style = layout.Style{
        .position = .relative,
    };
    if (state.axis == .vertical) {
        content_style.width = .Full;
        content_style.height = .{ .exact = @floatCast(true_content_size) };
    } else {
        content_style.height = .Full;
        content_style.width = .{ .exact = @floatCast(true_content_size) };
    }

    const content_container = try ctx.div(.{
        .id = deriveChildId(logic.base_id, "content_container"),
        .style = content_style,
        .children = try active_items.toOwnedSlice(alloc),
    });
    var wrapper_style = descriptor.style;
    wrapper_style.position = .relative;

    var scroll_style = layout.Style{
        .width = .Full,
        .height = .Full,
        .direction = if (state.axis == .vertical) .Column else .Row,
        .overflow_y = if (state.axis == .vertical) .scroll else .hidden,
        .overflow_x = if (state.axis == .horizontal) .scroll else .hidden,
        .gap = wrapper_style.gap,
        .padding = wrapper_style.padding,
    };

    wrapper_style.gap = 0.0;
    wrapper_style.padding = .all(0.0);

    scroll_style.scrollbar_width = wrapper_style.scrollbar_width;
    scroll_style.scrollbar_min_height = wrapper_style.scrollbar_min_height;
    scroll_style.scrollbar_color = wrapper_style.scrollbar_color;
    scroll_style.scrollbar_radius = wrapper_style.scrollbar_radius;

    const view_size = state.viewport_size;
    const content_size = true_content_size;
    const sb_width = @as(f64, @floatCast(if (wrapper_style.scrollbar_width > 0.0) wrapper_style.scrollbar_width else 8.0));
    const sb_min_h = @as(f64, @floatCast(if (wrapper_style.scrollbar_min_height > 0.0) wrapper_style.scrollbar_min_height else 20.0));
    const visible_ratio = view_size / @max(1.0, content_size);
    const thumb_size = @min(view_size, @max(sb_min_h, view_size * visible_ratio));
    const max_scroll = absolute_max_scroll;
    const track_size = @max(0.0, view_size - thumb_size);
    const scroll_ratio = std.math.clamp(state.scroll_offset / @max(1.0, max_scroll), 0.0, 1.0);
    const thumb_offset = track_size * scroll_ratio;
    state.thumb_drag_ratio = if (track_size > 0.0) max_scroll / track_size else 0.0;
    state.thumb_on_scroll_userdata = @ptrCast(logic.on_scroll);
    state.thumb_on_drag_state_change_userdata = @ptrCast(logic.on_drag_state_change);

    var thumb_style = layout.Style{
        .position = .absolute,
        .background_color = .{ 0, 0, 0, 0 },
        .cursor = .pointer,
    };

    if (state.axis == .vertical) {
        thumb_style.right = 2.0;
        thumb_style.top = @floatCast(thumb_offset);
        thumb_style.width = .{ .exact = @floatCast(sb_width) };
        thumb_style.height = .{ .exact = @floatCast(thumb_size) };
    } else {
        thumb_style.bottom = 2.0;
        thumb_style.left = @floatCast(thumb_offset);
        thumb_style.width = .{ .exact = @floatCast(thumb_size) };
        thumb_style.height = .{ .exact = @floatCast(sb_width) };
    }

    const scroll_ud: *const anyopaque = @ptrCast(state);
    const drag_handler = if (state.axis == .vertical)
        thumbInteractionHandler(MessageT, .vertical)
    else
        thumbInteractionHandler(MessageT, .horizontal);
    const scroll_view_events = try alloc.dupe(types.EventBinding(MessageT), &.{
        .{ .event = .hover_enter, .msg = need_data_msg },
        .{ .event = .scroll, .userdata = scroll_ud, .handler = drag_handler },
    });
    const scroll_view = try ctx.div(.{
        .id = deriveChildId(logic.base_id, "scroll_view"),
        .style = scroll_style,
        .events = scroll_view_events,
        .children = try alloc.dupe(*Node(MessageT), &.{content_container}),
    });
    if (state.axis == .vertical) {
        scroll_view.scroll_y = @floatCast(state.scroll_offset);
    } else {
        scroll_view.scroll_x = @floatCast(state.scroll_offset);
    }

    const thumb_events = try alloc.dupe(types.EventBinding(MessageT), &.{
        .{ .event = .pointer_down, .userdata = scroll_ud, .handler = thumbDragStartHandler(MessageT) },
        .{ .event = .pointer_up, .userdata = scroll_ud, .handler = thumbDragEndHandler(MessageT) },
        .{ .event = .drag, .userdata = scroll_ud, .handler = drag_handler },
        .{ .event = .scroll, .userdata = scroll_ud, .handler = drag_handler },
    });

    const invisible_thumb = try ctx.div(.{
        .id = deriveChildId(logic.base_id, "thumb_hitbox"),
        .style = thumb_style,
        .events = thumb_events,
    });
    invisible_thumb.lock_pointer_on_drag = true;

    return ctx.div(.{
        .id = logic.base_id,
        .style = wrapper_style,
        .children = try alloc.dupe(*Node(MessageT), &.{ scroll_view, invisible_thumb }),
    });
}

fn postLayoutHook(comptime MessageT: type) *const fn (ctx: *UIContext(MessageT), userdata: *anyopaque) bool {
    return struct {
        fn handle(ctx: *UIContext(MessageT), userdata: *anyopaque) bool {
            const state: *VirtualListState = @ptrCast(@alignCast(userdata));
            if (state.last_base_id == 0) return false;

            var needs_layout = false;
            if (reconcileLayout(MessageT, state, ctx, state.last_base_id)) {
                ctx.interaction_registry.rebuild_requested = true;
                needs_layout = true;
            }

            const true_content_size = @max(0.0, state.getPredictedTotalSize() - if (state.total_items > 0) state.gap else 0.0);
            const content_id = deriveChildId(state.last_base_id, "content_container");
            if (ctx.getById(content_id)) |content_node| {
                const target_size: f32 = @floatCast(true_content_size);
                if (state.axis == .vertical) {
                    const needs_update = switch (content_node.style.height) {
                        .exact => |value| @abs(value - target_size) > 0.5,
                        else => true,
                    };
                    if (needs_update) {
                        content_node.style.height = .{ .exact = target_size };
                        content_node.markSizeDirty();
                        needs_layout = true;
                    }
                } else {
                    const needs_update = switch (content_node.style.width) {
                        .exact => |value| @abs(value - target_size) > 0.5,
                        else => true,
                    };
                    if (needs_update) {
                        content_node.style.width = .{ .exact = target_size };
                        content_node.markSizeDirty();
                        needs_layout = true;
                    }
                }
            }

            if (state.stick_to_bottom) {
                const max_scroll = @max(0.0, true_content_size - state.viewport_size);
                if (@abs(state.scroll_offset - max_scroll) > 0.5) {
                    state.scroll_offset = max_scroll;
                    const scroll_id = deriveChildId(state.last_base_id, "scroll_view");
                    if (ctx.getById(scroll_id)) |node| {
                        if (state.axis == .vertical) {
                            node.scroll_y = @floatCast(state.scroll_offset);
                        } else {
                            node.scroll_x = @floatCast(state.scroll_offset);
                        }
                        node.markPositionDirty();
                    }
                    needs_layout = true;
                }
            }

            if (state.active_end_idx > state.active_start_idx) {
                var i = state.active_start_idx;
                while (i < state.active_end_idx) : (i += 1) {
                    const slot = i % MAX_POOL_SIZE;
                    const item_id = itemNodeId(state.last_base_id, slot);
                    const item_node = ctx.getById(item_id) orelse continue;
                    const new_offset: f32 = @floatCast(state.getOffsetForIndex(i));
                    if (state.axis == .vertical) {
                        const old_top = item_node.style.top orelse 0.0;
                        if (@abs(old_top - new_offset) > 0.01) {
                            item_node.style.top = new_offset;
                            item_node.markPositionDirty();
                            needs_layout = true;
                        }
                    } else {
                        const old_left = item_node.style.left orelse 0.0;
                        if (@abs(old_left - new_offset) > 0.01) {
                            item_node.style.left = new_offset;
                            item_node.markPositionDirty();
                            needs_layout = true;
                        }
                    }
                }
            }

            return needs_layout;
        }
    }.handle;
}

fn syncViewportFromNative(
    comptime MessageT: type,
    self: *VirtualListState,
    ui: *UIContext(MessageT),
    base_id: types.NodeId,
) bool {
    if (self.layout_freeze_frames > 0) return false;

    const scroll_id = deriveChildId(base_id, "scroll_view");
    const scroll_node = ui.getById(scroll_id) orelse return true;

    var changed = false;

    const current_viewport = if (self.axis == .vertical)
        @as(f64, @floatCast(scroll_node.layout_result.height))
    else
        @as(f64, @floatCast(scroll_node.layout_result.width));

    if (current_viewport != self.viewport_size) {
        self.viewport_size = current_viewport;
        changed = true;
    }

    const native_scroll = if (self.axis == .vertical)
        @as(f64, @floatCast(scroll_node.scroll_y))
    else
        @as(f64, @floatCast(scroll_node.scroll_x));

    if (!self.stick_to_bottom and @abs(native_scroll - self.scroll_offset) > 0.5) {
        self.scroll_offset = native_scroll;
        changed = true;
    }

    return changed;
}

pub fn reconcileLayout(
    comptime MessageT: type,
    self: *VirtualListState,
    ui: *UIContext(MessageT),
    base_id: types.NodeId,
) bool {
    if (self.layout_freeze_frames > 0) {
        self.layout_freeze_frames -= 1;
        return false;
    }

    var needs_rebuild = false;
    const scroll_id = deriveChildId(base_id, "scroll_view");
    const scroll_node = ui.getById(scroll_id) orelse return true;

    const current_viewport = if (self.axis == .vertical)
        @as(f64, @floatCast(scroll_node.layout_result.height))
    else
        @as(f64, @floatCast(scroll_node.layout_result.width));

    if (current_viewport != self.viewport_size) {
        self.viewport_size = current_viewport;
        needs_rebuild = true;
    }

    const native_scroll = if (self.axis == .vertical)
        @as(f64, @floatCast(scroll_node.scroll_y))
    else
        @as(f64, @floatCast(scroll_node.scroll_x));

    if (self.stick_to_bottom) {} else if (@abs(native_scroll - self.scroll_offset) > 0.5) {
        self.scroll_offset = native_scroll;
        self.stick_to_bottom = false;
        needs_rebuild = true;
    }

    var i = self.active_start_idx;
    const end = @min(self.active_end_idx, self.total_items);

    var scroll_adjustment: f64 = 0.0;
    var current_scroll = self.scroll_offset; // Track the shifting viewport threshold

    while (i < end) : (i += 1) {
        const slot = i % MAX_POOL_SIZE;
        const item_id = itemNodeId(base_id, slot);

        if (ui.getById(item_id)) |item_node| {
            if (item_node.flags.size or item_node.flags.content) continue;

            const measured = if (self.axis == .vertical)
                item_node.layout_result.height
            else
                item_node.layout_result.width;

            const total_item_size = @as(f64, @floatCast(@max(measured, 1.0))) + self.gap;
            const old_delta = self.layout_cache.deltas[i];
            const new_delta = total_item_size - self.fallback_estimate;

            if (self.layout_cache.update(i, new_delta)) {
                needs_rebuild = true;

                const item_top = self.getOffsetForIndex(i);

                if (current_scroll > item_top) {
                    const adj = new_delta - old_delta;
                    scroll_adjustment += adj;
                    current_scroll += adj; // Synchronize the threshold for subsequent iterations
                }
            }
        }
    }

    if (scroll_adjustment != 0.0) {
        self.scroll_offset = @max(0.0, self.scroll_offset + scroll_adjustment);

        if (self.axis == .vertical) {
            scroll_node.layout_result.content_height += @floatCast(scroll_adjustment);
            scroll_node.scroll_y = @floatCast(self.scroll_offset);
        } else {
            scroll_node.layout_result.content_width += @floatCast(scroll_adjustment);
            scroll_node.scroll_x = @floatCast(self.scroll_offset);
        }
        scroll_node.markPositionDirty();
    }

    return needs_rebuild;
}

fn highestPowerOfTwoLE(value: usize) usize {
    if (value == 0) return 0;
    var bit: usize = 1;
    while ((bit << 1) <= value) {
        bit <<= 1;
    }
    return bit;
}

fn findIndexForOffset(state: *VirtualListState, target_offset: f64) usize {
    if (state.total_items == 0) return 0;
    var sum_delta: f64 = 0.0;
    var pos: usize = 0;
    var bit = highestPowerOfTwoLE(state.total_items);

    while (bit > 0) : (bit >>= 1) {
        const next_pos = pos + bit;
        if (next_pos <= state.total_items) {
            const next_delta = sum_delta + state.layout_cache.tree[next_pos];
            const next_prefix = (@as(f64, @floatFromInt(next_pos)) * state.fallback_estimate) + next_delta;
            if (next_prefix < target_offset) {
                pos = next_pos;
                sum_delta = next_delta;
            }
        }
    }
    return @min(pos, state.total_items);
}
