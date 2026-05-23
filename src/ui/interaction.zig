const std = @import("std");
const Node = @import("node.zig").Node;
const TextSelection = @import("node.zig").TextSelection;
const Style = @import("layout.zig").Style;
const window_mod = @import("../window/window.zig");
const platform = @import("../platform/backend.zig");
const app_backend = @import("../platform/app_backend.zig");
const Cursor = window_mod.Cursor;
const types = @import("types.zig");
const NodeId = types.NodeId;
const InteractionMessage = types.InteractionMessage;
const EventBinding = types.EventBinding;
const EventData = types.EventData;

const glfw = @import("glfw");
const SCROLL_SPEED_MULTIPLIER: f32 = 24.0;
const DRAG_START_THRESHOLD_PX: f64 = 3.0;

pub fn InteractionRegistry(comptime MessageT: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        focused_node: ?*Node(MessageT) = null,

        hovered_node: ?*Node(MessageT) = null,

        /// Cursor-containment chain from root → deepest hovered node, captured each
        /// frame. Used to fire hover_enter/hover_exit on every node that gained or
        /// lost containment, not only the deepest hit. Without this, an inner div
        /// with `tw.hover` (sets hover_color, hit-claims) silently steals events
        /// from an ancestor that owns the actual on_hover_enter binding.
        hover_chain: std.ArrayList(*Node(MessageT)) = .empty,
        prev_hover_chain: std.ArrayList(*Node(MessageT)) = .empty,

        mouse_x: f64 = 0.0,
        mouse_y: f64 = 0.0,
        mouse_mods: i32 = 0,

        previous_mouse_down: bool = false,
        mouse_just_pressed: bool = false,
        mouse_just_released: bool = false,
        previous_right_down: bool = false,
        right_just_released: bool = false,
        click_press_target: ?*Node(MessageT) = null,
        is_dragging: bool = false,
        scroll_delta_x: f32 = 0.0,
        scroll_delta_y: f32 = 0.0,

        active_drag_node: ?*Node(MessageT) = null,
        active_drag_axis: enum { None, Vertical, Horizontal } = .None,
        active_drag_has_moved: bool = false,
        pointer_locked_for_drag: bool = false,

        cursor_lock_origin_x: f64 = 0.0,
        cursor_lock_origin_y: f64 = 0.0,
        drag_capture_start_x: f64 = 0.0,
        drag_capture_start_y: f64 = 0.0,
        previous_drag_x: f64 = 0.0,
        previous_drag_y: f64 = 0.0,

        selection_anchor: ?SelectionPoint = null,
        selection_focus: ?SelectionPoint = null,

        message_queue: std.ArrayList(InteractionMessage(MessageT)),
        external_mutex: std.Io.Mutex = .init,
        external_queue: std.ArrayList(InteractionMessage(MessageT)),

        hover_anim_active: bool = false,
        scroll_changed: bool = false,

        shortcut_context: ?*anyopaque = null,
        shortcut_handler: ?*const fn (
            ctx: ?*anyopaque,
            ui: *Self,
            key: i32,
            action: i32,
            is_ctrl: bool,
            is_shift: bool,
        ) bool = null,
        pending_focus_id: ?NodeId = null,

        clipboard_ctx: ?*anyopaque = null,
        clipboard_get_fn: ?*const fn (?*anyopaque) ?[:0]const u8 = null,
        clipboard_set_fn: ?*const fn (?*anyopaque, [:0]const u8) void = null,

        rebuild_requested: bool = false,
        layout_requested: bool = false,
        paint_requested: bool = false,

        /// DevTools element-picker mode. When set, the hit-test still runs (so
        /// `hovered_node` tracks the cursor) but no events are dispatched to the app,
        /// so clicking selects an element instead of triggering its behavior.
        picking: bool = false,

        const SelectionPoint = struct {
            node: *Node(MessageT),
            offset: usize,
        };

        const EditableTextRef = struct {
            buffer: *std.ArrayList(u8),
            cursor_index: *usize,
            selection_anchor: *?usize,
            font_line_height: f32,
            scroll_y: ?*f32 = null,
            target_nav_x: ?*f32 = null,
            multiline: bool,
        };

        const CursorVisual = struct {
            x: f32 = 0.0,
            y: f32 = 0.0,
            height: f32 = 0.0,
        };

        fn getClipboard(self: *const Self) ?[:0]const u8 {
            if (self.clipboard_get_fn) |get_fn| return get_fn(self.clipboard_ctx);
            return null;
        }

        fn setClipboard(self: *Self, str: [:0]const u8) void {
            if (self.clipboard_set_fn) |set_fn| set_fn(self.clipboard_ctx, str);
        }

        fn editableTextRef(node: *Node(MessageT)) ?EditableTextRef {
            return switch (node.payload) {
                .text_input => |*ti| .{
                    .buffer = &ti.buffer,
                    .cursor_index = &ti.cursor_index,
                    .selection_anchor = &ti.selection_anchor,
                    .font_line_height = ti.font.line_height,
                    .multiline = false,
                },
                .text_area => |*ta| .{
                    .buffer = &ta.buffer,
                    .cursor_index = &ta.cursor_index,
                    .selection_anchor = &ta.selection_anchor,
                    .font_line_height = ta.font.line_height,
                    .scroll_y = &ta.scroll_y,
                    .target_nav_x = &ta.target_nav_x,
                    .multiline = true,
                },
                else => null,
            };
        }

        fn hasClaimsInputAncestor(node: *Node(MessageT)) bool {
            var n: ?*Node(MessageT) = node;
            while (n) |cur| : (n = cur.parent) {
                if (cur.claims_input) return true;
            }
            return false;
        }

        fn prevUtf8Boundary(bytes: []const u8, cursor_index: usize) usize {
            if (cursor_index == 0) return 0;
            var next_idx = cursor_index - 1;
            while (next_idx > 0 and (bytes[next_idx] & 0xC0) == 0x80) {
                next_idx -= 1;
            }
            return next_idx;
        }

        fn nextUtf8Boundary(bytes: []const u8, cursor_index: usize) usize {
            if (cursor_index >= bytes.len) return bytes.len;
            var next_idx = cursor_index + 1;
            while (next_idx < bytes.len and (bytes[next_idx] & 0xC0) == 0x80) {
                next_idx += 1;
            }
            return next_idx;
        }

        fn resolveCursorVisual(node: *Node(MessageT), bytes: []const u8, cursor_index: usize, fallback_line_height: f32) CursorVisual {
            const metrics = node.layout_result.text_cache.metrics;
            var out = CursorVisual{ .height = fallback_line_height };

            var max_metric_index: usize = 0;
            for (metrics) |m| {
                max_metric_index = @max(max_metric_index, m.byte_offset + m.byte_length);

                if (cursor_index == m.byte_offset) {
                    out.x = m.x;
                    out.y = m.y;
                    out.height = m.height;
                    return out;
                }

                if (cursor_index >= m.byte_offset + m.byte_length) {
                    out.x = m.x + m.width;
                    out.y = m.y;
                    out.height = m.height;

                    if (m.byte_length > 0 and m.width == 0 and m.byte_offset < bytes.len and bytes[m.byte_offset] == '\n') {
                        out.x = 0.0;
                        out.y = m.y + m.height;
                    }
                }
            }

            if (bytes.len > 0 and (metrics.len == 0 or max_metric_index <= 1)) {
                const clamped_idx = @min(cursor_index, bytes.len);
                const ratio = @as(f32, @floatFromInt(clamped_idx)) /
                    @as(f32, @floatFromInt(bytes.len));
                out.x = node.layout_result.text_cache.width * ratio;
                out.y = 0.0;
            }

            return out;
        }

        fn updateTextAreaNavigationX(self: *Self, node: *Node(MessageT)) void {
            _ = self;
            if (node.payload != .text_area) return;

            const ta = &node.payload.text_area;
            const fallback_line_h = if (node.layout_result.text_cache.line_height > 0.0)
                node.layout_result.text_cache.line_height
            else
                ta.font.line_height;
            const visual = resolveCursorVisual(node, ta.buffer.items, ta.cursor_index, fallback_line_h);
            ta.target_nav_x = visual.x;
        }

        fn ensureTextAreaCursorVisible(self: *Self, node: *Node(MessageT)) void {
            if (node.payload != .text_area) return;

            const ta = &node.payload.text_area;
            const bdr = node.style.border;
            const pad = node.style.padding;

            const inset_top = pad.top + @max(0.0, bdr.top.width);
            const inset_bottom = pad.bottom + @max(0.0, bdr.bottom.width);
            const viewport_h = @max(0.0, node.layout_result.height - inset_top - inset_bottom);
            if (viewport_h <= 0.0) return;

            const fallback_line_h = if (node.layout_result.text_cache.line_height > 0.0)
                node.layout_result.text_cache.line_height
            else
                ta.font.line_height;

            const visual = resolveCursorVisual(node, ta.buffer.items, ta.cursor_index, fallback_line_h);
            const cursor_h = if (visual.height > 0.0) visual.height else fallback_line_h;

            var scroll_y = ta.scroll_y;
            const cursor_top = visual.y;
            const cursor_bottom = visual.y + cursor_h;

            if (cursor_top < scroll_y) {
                scroll_y = cursor_top;
            } else if (cursor_bottom > scroll_y + viewport_h) {
                scroll_y = cursor_bottom - viewport_h;
            }

            const max_scroll = @max(0.0, node.layout_result.text_cache.height - viewport_h);
            const clamped = std.math.clamp(scroll_y, 0.0, max_scroll);
            if (@abs(clamped - ta.scroll_y) > 0.01) {
                ta.scroll_y = clamped;
                self.paint_requested = true;
            }
        }

        fn moveTextAreaCursorVertical(self: *Self, node: *Node(MessageT), direction: i32) bool {
            if (node.payload != .text_area) return false;
            if (direction == 0) return false;

            const ta = &node.payload.text_area;
            const metrics = node.layout_result.text_cache.metrics;
            if (metrics.len == 0) return false;

            const fallback_line_h = if (node.layout_result.text_cache.line_height > 0.0)
                node.layout_result.text_cache.line_height
            else
                ta.font.line_height;

            const current = resolveCursorVisual(node, ta.buffer.items, ta.cursor_index, fallback_line_h);
            if (ta.target_nav_x == 0.0) {
                ta.target_nav_x = current.x;
            }
            const desired_x = ta.target_nav_x;

            var target_line_y: ?f32 = null;
            if (direction < 0) {
                var best_prev: f32 = -std.math.inf(f32);
                var found_prev = false;
                for (metrics) |m| {
                    if (m.y < current.y - 0.01 and (!found_prev or m.y > best_prev)) {
                        best_prev = m.y;
                        found_prev = true;
                    }
                }
                if (found_prev) target_line_y = best_prev;
            } else {
                for (metrics) |m| {
                    if (m.y > current.y + 0.01) {
                        target_line_y = m.y;
                        break;
                    }
                }
            }

            if (target_line_y == null) return false;

            var best_index = ta.cursor_index;
            var best_dist = std.math.inf(f32);
            var found = false;

            for (metrics) |m| {
                if (@abs(m.y - target_line_y.?) > 0.01) continue;

                const left_dist = @abs(desired_x - m.x);
                if (left_dist < best_dist) {
                    best_dist = left_dist;
                    best_index = m.byte_offset;
                    found = true;
                }

                const right_x = m.x + m.width;
                const right_dist = @abs(desired_x - right_x);
                if (right_dist < best_dist) {
                    best_dist = right_dist;
                    best_index = m.byte_offset + m.byte_length;
                    found = true;
                }
            }

            if (!found or best_index == ta.cursor_index) return false;

            ta.cursor_index = best_index;
            ta.selection_anchor = null;
            self.layout_requested = true;
            self.ensureTextAreaCursorVisible(node);
            return true;
        }

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .message_queue = std.ArrayList(InteractionMessage(MessageT)).empty,
                .external_queue = std.ArrayList(InteractionMessage(MessageT)).empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.drainExternalMessages();
            destroyResidualMessages(MessageT, self.allocator, self.message_queue.items);
            destroyResidualMessages(MessageT, self.allocator, self.external_queue.items);
            self.message_queue.deinit(self.allocator);
            self.external_queue.deinit(self.allocator);
            self.hover_chain.deinit(self.allocator);
            self.prev_hover_chain.deinit(self.allocator);
        }

        pub fn requestFocus(self: *Self, id: NodeId) void {
            self.pending_focus_id = id;
        }

        /// Thread-safe; drained into message_queue by the main loop.
        pub fn postExternalMessage(self: *Self, msg: InteractionMessage(MessageT)) void {
            self.external_mutex.lockUncancelable(std.Options.debug_io);
            defer self.external_mutex.unlock(std.Options.debug_io);

            self.external_queue.append(self.allocator, msg) catch {};
        }

        pub fn drainExternalMessages(self: *Self) void {
            self.external_mutex.lockUncancelable(std.Options.debug_io);
            defer self.external_mutex.unlock(std.Options.debug_io);

            for (self.external_queue.items) |msg| {
                self.message_queue.append(self.allocator, msg) catch {};
            }
            self.external_queue.clearRetainingCapacity();
        }

        fn onHoverChanged(self: *Self, node: *Node(MessageT), target: f32, current_time: f64) void {
            if (node.style.transition.property.hover_color and node.style.transition.duration_ms > 0) {
                node.hover_anim = .{
                    .start_time = current_time,
                    .from = node.style._hover_blend,
                    .to = target,
                    .duration = @as(f64, @floatFromInt(node.style.transition.duration_ms)) / 1000.0,
                    .timing = node.style.transition.timing,
                };
                self.hover_anim_active = true;
            } else {
                node.hover_anim = null;
                node.style._hover_blend = target;
            }
        }

        pub fn resetForNewTree(self: *Self) void {
            self.hovered_node = null;
            self.focused_node = null;
            self.hover_chain.clearRetainingCapacity();
            self.prev_hover_chain.clearRetainingCapacity();
            self.active_drag_node = null;
            self.active_drag_axis = .None;
            self.active_drag_has_moved = false;
            self.pointer_locked_for_drag = false;
            self.drag_capture_start_x = 0.0;
            self.drag_capture_start_y = 0.0;
            self.previous_drag_x = 0.0;
            self.previous_drag_y = 0.0;
            self.scroll_delta_x = 0.0;
            self.scroll_delta_y = 0.0;
            self.scroll_changed = false;
            self.selection_anchor = null;
            self.selection_focus = null;
            self.message_queue.clearRetainingCapacity();

            self.external_mutex.lockUncancelable(std.Options.debug_io);
            self.external_queue.clearRetainingCapacity();
            self.external_mutex.unlock(std.Options.debug_io);
        }

        pub fn resetAllForReload(self: *Self) void {
            self.resetForNewTree();
            self.shortcut_handler = null;
            self.shortcut_context = null;
        }

        pub fn assertCleanForReload(self: *const Self) void {
            std.debug.assert(self.hovered_node == null);
            std.debug.assert(self.focused_node == null);
            std.debug.assert(self.active_drag_node == null);
            std.debug.assert(self.selection_anchor == null);
            std.debug.assert(self.selection_focus == null);
            std.debug.assert(self.shortcut_handler == null);
            std.debug.assert(self.shortcut_context == null);
            std.debug.assert(self.hover_chain.items.len == 0);
            std.debug.assert(self.message_queue.items.len == 0);
        }

        fn swapHoverChains(self: *Self) void {
            const tmp = self.prev_hover_chain;
            self.prev_hover_chain = self.hover_chain;
            self.hover_chain = tmp;
        }

        fn cursorInsideNode(self: *const Self, node: *Node(MessageT)) bool {
            const rect = node.getTransformedRect();
            const x: f32 = @floatCast(self.mouse_x);
            const y: f32 = @floatCast(self.mouse_y);
            return x >= rect.x and x <= rect.x + rect.width and
                y >= rect.y and y <= rect.y + rect.height;
        }

        /// Walk parents from the hit upward; collect every ancestor whose bounds
        /// contain the cursor. The chain is appended in reverse (deepest first), then
        /// reversed so it reads root → hit. Cursor-containment is rechecked per
        /// ancestor so transformed/clipped intermediates don't accidentally appear.
        fn buildHoverChainFromHit(self: *Self, hit: *Node(MessageT)) void {
            self.hover_chain.append(self.allocator, hit) catch return;
            var cur: ?*Node(MessageT) = hit.parent;
            while (cur) |node| {
                if (self.cursorInsideNode(node)) {
                    self.hover_chain.append(self.allocator, node) catch return;
                }
                cur = node.parent;
            }
            std.mem.reverse(*Node(MessageT), self.hover_chain.items);
        }

        fn chainContains(chain: []const *Node(MessageT), node: *Node(MessageT)) bool {
            for (chain) |n| {
                if (n == node) return true;
            }
            return false;
        }

        /// Diff prev vs current chain. Nodes that left fire hover_exit (and lose
        /// is_hovered + animate blend out). Nodes that entered fire hover_enter
        /// (gain is_hovered + animate blend in). Order: exits (deepest first) then
        /// enters (root first), matching standard DOM hover semantics.
        fn diffHoverChain(self: *Self, current_time: f64) void {
            // Exits: deepest first. Iterate prev in reverse.
            var i: usize = self.prev_hover_chain.items.len;
            while (i > 0) {
                i -= 1;
                const node = self.prev_hover_chain.items[i];
                if (chainContains(self.hover_chain.items, node)) continue;
                node.is_hovered = false;
                if (node.style.hover_color != null) {
                    self.paint_requested = true;
                    self.onHoverChanged(node, 0.0, current_time);
                }
                if (node.hasEventBinding(.hover_exit)) {
                    self.dispatchNodeEvent(node, .hover_exit, .none);
                }
            }

            // Enters: root first.
            for (self.hover_chain.items) |node| {
                if (chainContains(self.prev_hover_chain.items, node)) continue;
                node.is_hovered = true;
                if (node.style.hover_color != null) {
                    self.paint_requested = true;
                    self.onHoverChanged(node, 1.0, current_time);
                }
                if (node.hasEventBinding(.hover_enter)) {
                    self.dispatchNodeEvent(node, .hover_enter, .none);
                }
            }
        }

        fn dispatchNodeEvent(self: *Self, node: *Node(MessageT), event_type: types.EventType, data: EventData) void {
            const layout_snap = types.EventLayoutSnapshot{
                .x = node.layout_result.x,
                .y = node.layout_result.y,
                .width = node.layout_result.width,
                .height = node.layout_result.height,
            };

            for (node.events) |binding| {
                if (binding.event != event_type) continue;
                if (binding.handler) |h| {
                    if (h(binding.userdata, layout_snap, data)) |emitted| {
                        self.message_queue.append(self.allocator, .{
                            .id = emitted,
                            .source = node,
                            .data = data,
                        }) catch unreachable;
                    }
                    continue;
                }
                if (binding.msg) |msg_id| {
                    self.message_queue.append(self.allocator, .{
                        .id = msg_id,
                        .source = node,
                        .data = data,
                    }) catch unreachable;
                    continue;
                }
            }
        }

        pub fn updateInputSnapshot(self: *Self, snapshot: platform.PointerInputSnapshot) void {
            self.mouse_x = snapshot.x;
            self.mouse_y = snapshot.y;
            self.mouse_mods = snapshot.mods;
            self.scroll_delta_x = @floatCast(snapshot.scroll_dx);
            self.scroll_delta_y = @floatCast(snapshot.scroll_dy);
            self.scroll_changed = false;

            self.mouse_just_pressed = snapshot.left_down and !self.previous_mouse_down;
            self.mouse_just_released = !snapshot.left_down and self.previous_mouse_down;
            self.is_dragging = snapshot.left_down;
            self.previous_mouse_down = snapshot.left_down;

            self.right_just_released = !snapshot.right_down and self.previous_right_down;
            self.previous_right_down = snapshot.right_down;
        }

        /// Update input state from raw values (for non-GLFW backends).
        pub fn updateInputRaw(
            self: *Self,
            mouse_x: f64,
            mouse_y: f64,
            left_down: bool,
            right_down: bool,
            scroll_dx: f64,
            scroll_dy: f64,
        ) void {
            self.updateInputSnapshot(.{
                .x = mouse_x,
                .y = mouse_y,
                .left_down = left_down,
                .right_down = right_down,
                .scroll_dx = scroll_dx,
                .scroll_dy = scroll_dy,
            });
        }

        pub fn processInteractions(self: *Self, root: *Node(MessageT), current_time: f64) void {
            self.processInteractionsInner(root, null, current_time);
        }

        /// Process interactions with a Backend pointer for cursor lock/warp during
        /// drag. Cursor warping is a no-op on backends that do not support it
        /// (e.g. native Wayland).
        pub fn processInteractionsWithBackend(self: *Self, root: *Node(MessageT), backend: *app_backend.Backend, current_time: f64) void {
            self.processInteractionsInner(root, backend, current_time);
        }

        fn processInteractionsInner(self: *Self, root: *Node(MessageT), win: ?*app_backend.Backend, current_time: f64) void {
            if (self.pending_focus_id) |req_id| {
                if (findNodeById(MessageT, root, req_id)) |target| {
                    if (self.focused_node) |prev| {
                        if (prev != target) prev.is_focused = false;
                    }
                    self.focused_node = target;
                    target.is_focused = true;
                    self.pending_focus_id = null;
                    self.layout_requested = true;
                }
            }

            self.hovered_node = null;

            const mouse_is_down = self.previous_mouse_down;

            if (self.active_drag_node) |drag_node| {
                if (mouse_is_down) {
                    self.hovered_node = drag_node;
                    const delta_x: f32 = @floatCast(self.mouse_x - self.previous_drag_x);
                    const delta_y: f32 = @floatCast(self.mouse_y - self.previous_drag_y);
                    const total_dx = self.mouse_x - self.drag_capture_start_x;
                    const total_dy = self.mouse_y - self.drag_capture_start_y;
                    const moved_enough = (total_dx * total_dx + total_dy * total_dy) >=
                        (DRAG_START_THRESHOLD_PX * DRAG_START_THRESHOLD_PX);

                    if (delta_x != 0.0 or delta_y != 0.0) {
                        if (drag_node.hasEventBinding(.drag)) {
                            if (moved_enough) {
                                self.active_drag_has_moved = true;
                                self.dispatchNodeEvent(drag_node, .drag, .{ .drag = .{
                                    .x = @floatCast(self.mouse_x),
                                    .y = @floatCast(self.mouse_y),
                                    .dx = delta_x,
                                    .dy = delta_y,
                                    .mods = self.mouse_mods,
                                } });
                            }
                        } else {
                            self.active_drag_has_moved = true;
                            self.processInternalScrollDrag(drag_node, delta_x, delta_y);
                        }
                    }
                    self.previous_drag_x = self.mouse_x;
                    self.previous_drag_y = self.mouse_y;
                } else {
                    const released_axis = self.active_drag_axis;
                    const had_scroll_capture = released_axis != .None;
                    if (self.mouse_just_released and drag_node.hasEventBinding(.pointer_up) and
                        (had_scroll_capture or self.active_drag_has_moved))
                    {
                        self.dispatchNodeEvent(drag_node, .pointer_up, .{ .mouse = .{
                            .x = @floatCast(self.mouse_x),
                            .y = @floatCast(self.mouse_y),
                            .mods = self.mouse_mods,
                        } });
                    }

                    if (self.pointer_locked_for_drag) {
                        var restore_x = self.cursor_lock_origin_x;
                        var restore_y = self.cursor_lock_origin_y;
                        switch (released_axis) {
                            .Vertical => {
                                if (drag_node.getVerticalScrollbarThumbRect()) |thumb| {
                                    restore_y = @floatCast(thumb.y + thumb.height * 0.5);
                                }
                            },
                            .Horizontal => {
                                if (drag_node.getHorizontalScrollbarThumbRect()) |thumb| {
                                    restore_x = @floatCast(thumb.x + thumb.width * 0.5);
                                }
                            },
                            .None => {
                                if (drag_node.lock_pointer_on_drag) {
                                    const r = drag_node.layout_result;
                                    restore_x = @floatCast(r.x + r.width * 0.5);
                                    restore_y = @floatCast(r.y + r.height * 0.5);
                                }
                            },
                        }
                        if (win) |w| {
                            w.setCursorModeDisabled(false);
                            w.setCursorPos(restore_x, restore_y);
                        }
                        self.mouse_x = restore_x;
                        self.mouse_y = restore_y;
                        self.previous_drag_x = restore_x;
                        self.previous_drag_y = restore_y;
                        self.pointer_locked_for_drag = false;
                    }

                    self.active_drag_node = null;
                    self.active_drag_axis = .None;
                    self.active_drag_has_moved = false;
                    self.drag_capture_start_x = 0.0;
                    self.drag_capture_start_y = 0.0;
                }
            }

            if (self.active_drag_node == null) {
                _ = self.hitTest(root);
            }

            if (self.picking) {
                if (win) |w| w.setCursor(.crosshair);
                return;
            }

            // Build current hover chain: walk parents from hovered_node up to root,
            // include every ancestor whose bounds contain the cursor. Then diff against
            // last frame to fire hover_enter/hover_exit on every gained/lost node.
            // This decouples event dispatch from the deepest-wins hit-test claim, so
            // an inner div with `tw.hover` no longer steals events from an ancestor
            // that owns the actual hover_enter/hover_exit binding.
            self.swapHoverChains();
            self.hover_chain.clearRetainingCapacity();
            if (self.hovered_node) |hit| {
                self.buildHoverChainFromHit(hit);
            }
            self.diffHoverChain(current_time);

            if (self.hovered_node) |hovered| {
                if (hovered.hasEventBinding(.pointer_move)) {
                    self.dispatchNodeEvent(hovered, .pointer_move, .{ .mouse = .{
                        .x = @floatCast(self.mouse_x),
                        .y = @floatCast(self.mouse_y),
                        .mods = self.mouse_mods,
                    } });
                }
            }

            if (self.mouse_just_pressed) {
                if (self.hovered_node) |target| {
                    var down_target: ?*Node(MessageT) = target;
                    while (down_target) |n| {
                        if (n.hasEventBinding(.pointer_down)) {
                            self.dispatchNodeEvent(n, .pointer_down, .{ .mouse = .{
                                .x = @floatCast(self.mouse_x),
                                .y = @floatCast(self.mouse_y),
                                .mods = self.mouse_mods,
                            } });
                            break;
                        }
                        down_target = n.parent;
                    }

                    self.evaluatePointerCapture(target);

                    if (self.active_drag_node) |captured| {
                        const wants_lock = self.active_drag_axis != .None or captured.lock_pointer_on_drag;
                        if (wants_lock and !self.pointer_locked_for_drag) {
                            if (win) |w| {
                                const origin = w.getCursorPos();
                                self.cursor_lock_origin_x = origin.x;
                                self.cursor_lock_origin_y = origin.y;
                                w.setCursorModeDisabled(true);
                            }
                            self.pointer_locked_for_drag = true;
                        }
                    }

                    // Resolve the node that should take focus: the hit node if
                    // it is focusable, else its nearest focusable ancestor. This
                    // keeps focus on a focusable container (e.g. an editor
                    // surface) when the click lands on a non-focusable child
                    // (text, etc.) instead of dropping focus entirely.
                    var focus_target: ?*Node(MessageT) = target;
                    while (focus_target) |ft| : (focus_target = ft.parent) {
                        if (ft.is_focusable) break;
                    }

                    if (focus_target == null) {
                        if (self.focused_node) |prev| {
                            prev.is_focused = false;
                            if (editableTextRef(prev)) |edit| {
                                edit.selection_anchor.* = null;
                            }
                            self.layout_requested = true;
                        }
                        self.focused_node = null;
                    }

                    if (focus_target) |target_node| {
                        if (self.focused_node) |prev_focus| {
                            if (prev_focus != target_node) prev_focus.is_focused = false;
                        }
                        self.focused_node = target_node;
                        target_node.is_focused = true;

                        if (self.selection_anchor != null) {
                            self.clearTextSelection(root);
                            self.paint_requested = true;
                        }
                    }

                    if (target.payload == .text_input or target.payload == .text_area) {
                        const idx = self.resolveSpatialIndex(target);
                        if (editableTextRef(target)) |edit| {
                            edit.cursor_index.* = idx;
                            edit.selection_anchor.* = idx;
                        }
                        self.updateTextAreaNavigationX(target);
                        self.ensureTextAreaCursorVisible(target);
                        self.layout_requested = true;
                    } else if (target.payload == .text and !hasClaimsInputAncestor(target)) {
                        if (self.resolveTextSelectionPointAtCursor(target)) |point| {
                            clearSelectionVisuals(root);
                            self.selection_anchor = point;
                            self.selection_focus = point;
                            self.applyTextSelectionSpan(root);
                            self.paint_requested = true;
                        } else if (self.selection_anchor != null) {
                            self.clearTextSelection(root);
                            self.paint_requested = true;
                        }
                    } else {
                        if (self.selection_anchor != null) {
                            self.clearTextSelection(root);
                            self.paint_requested = true;
                        }
                    }

                    // Remember the press target so click is dispatched on release
                    // only if (a) the release lands on the same node and (b) no drag
                    // was registered between press and release.
                    self.click_press_target = target;
                } else {
                    if (self.focused_node) |prev_focus| {
                        prev_focus.is_focused = false;
                        if (editableTextRef(prev_focus)) |edit| {
                            edit.selection_anchor.* = null;
                            self.layout_requested = true;
                        }
                    }
                    self.focused_node = null;

                    if (self.selection_anchor != null) {
                        self.clearTextSelection(root);
                        self.paint_requested = true;
                    }
                }
            } else if (mouse_is_down and self.active_drag_node == null) {
                if (self.focused_node) |node| {
                    if (node.payload == .text_input or node.payload == .text_area) {
                        if (self.hovered_node == node) {
                            const idx = self.resolveSpatialIndex(node);
                            if (editableTextRef(node)) |edit| {
                                if (edit.cursor_index.* != idx) {
                                    edit.cursor_index.* = idx;
                                    self.updateTextAreaNavigationX(node);
                                    self.ensureTextAreaCursorVisible(node);
                                    self.layout_requested = true;
                                }
                            }
                        }
                    }
                }

                if (self.selection_anchor != null) {
                    if (self.resolveTextSelectionPointAtCursor(root)) |point| {
                        const changed = if (self.selection_focus) |f|
                            f.node != point.node or f.offset != point.offset
                        else
                            true;
                        if (changed) {
                            self.selection_focus = point;
                            self.applyTextSelectionSpan(root);
                            self.paint_requested = true;
                        }
                    }
                }
            }

            if (self.mouse_just_released and self.active_drag_node == null) {
                if (self.hovered_node) |target| {
                    var up_target: ?*Node(MessageT) = target;
                    while (up_target) |n| {
                        if (n.hasEventBinding(.pointer_up)) {
                            self.dispatchNodeEvent(n, .pointer_up, .{ .mouse = .{
                                .x = @floatCast(self.mouse_x),
                                .y = @floatCast(self.mouse_y),
                                .mods = self.mouse_mods,
                            } });
                            break;
                        }
                        up_target = n.parent;
                    }
                }
            }

            // Dispatch click on release if it landed on the same node we pressed
            // and no drag motion was detected. This is what callers usually mean by
            // "click" and lets nodes carry both .on_click and .on_drag without the
            // click firing on every drag attempt.
            if (self.mouse_just_released) {
                const pressed = self.click_press_target;
                self.click_press_target = null;
                if (pressed) |press_node| {
                    if (!self.active_drag_has_moved and self.hovered_node != null) {
                        var click_target: ?*Node(MessageT) = press_node;
                        while (click_target) |n| {
                            if (n.hasEventBinding(.click)) {
                                const idx = self.resolveSpatialIndex(n);
                                self.dispatchNodeEvent(n, .click, .{ .mouse = .{
                                    .x = @floatCast(self.mouse_x),
                                    .y = @floatCast(self.mouse_y),
                                    .mods = self.mouse_mods,
                                    .cursor_index = idx,
                                } });
                                break;
                            }
                            click_target = n.parent;
                        }
                    }
                }
            }

            if (self.right_just_released) {
                if (self.hovered_node) |target| {
                    var ctx_target: ?*Node(MessageT) = target;
                    while (ctx_target) |n| {
                        if (n.hasEventBinding(.context_menu)) {
                            self.dispatchNodeEvent(n, .context_menu, .{ .mouse = .{
                                .x = @floatCast(self.mouse_x),
                                .y = @floatCast(self.mouse_y),
                                .mods = self.mouse_mods,
                            } });
                            break;
                        }
                        ctx_target = n.parent;
                    }
                }
            }

            if (!mouse_is_down) {
                if (self.focused_node) |node| {
                    if (editableTextRef(node)) |edit| {
                        if (edit.selection_anchor.*) |anchor| {
                            if (anchor == edit.cursor_index.*) {
                                edit.selection_anchor.* = null;
                                self.layout_requested = true;
                            }
                        }
                    }
                }
            }

            self.processScrollWheel();

            if (win) |w| w.setCursor(resolveCursor(MessageT, self.hovered_node));
        }

        fn resolveSpatialIndex(self: *Self, target: *Node(MessageT)) usize {
            const text_node = self.findTextNode(target);
            const tn = text_node orelse target;

            const metrics = tn.layout_result.text_cache.metrics;
            if (metrics.len == 0) {
                return switch (tn.payload) {
                    .text => tn.payload.text.content.len,
                    .text_input => tn.payload.text_input.buffer.items.len,
                    .text_area => tn.payload.text_area.buffer.items.len,
                    else => 0,
                };
            }

            const padding = tn.style.padding;
            const border = tn.style.border;

            const inset_left = padding.left + @max(0.0, border.left.width);
            const inset_top = padding.top + @max(0.0, border.top.width);

            const text_scroll_y: f32 = if (tn.payload == .text_area)
                tn.payload.text_area.scroll_y
            else
                0.0;

            const local_x = @as(f32, @floatCast(self.mouse_x)) - (tn.layout_result.x + inset_left);
            const raw_local_y = @as(f32, @floatCast(self.mouse_y)) - (tn.layout_result.y + inset_top) + text_scroll_y;

            const text_top: f32 = metrics[0].y;
            const last = metrics[metrics.len - 1];
            const text_bottom: f32 = last.y + last.height;
            const local_y = std.math.clamp(raw_local_y, text_top, text_bottom - 1.0);

            var resolved: usize = last.byte_offset + last.byte_length;

            for (metrics) |m| {
                if (local_y >= m.y and local_y < m.y + m.height) {
                    if (local_x < m.x + (m.width / 2.0)) {
                        resolved = m.byte_offset;
                        break;
                    } else if (local_x >= m.x + (m.width / 2.0) and local_x <= m.x + m.width) {
                        resolved = m.byte_offset + m.byte_length;
                        break;
                    }
                }
            }

            // The cache may be holding placeholder metrics (when a text input's
            // buffer is empty). Clamp the resolved index to the actual buffer
            // length so callers don't store cursor positions past the end and
            // crash later in delete/range arithmetic.
            const buf_len: usize = switch (tn.payload) {
                .text_input => tn.payload.text_input.buffer.items.len,
                .text_area => tn.payload.text_area.buffer.items.len,
                else => return resolved,
            };
            return @min(resolved, buf_len);
        }

        fn findTextNode(self: *Self, node: *Node(MessageT)) ?*Node(MessageT) {
            if (node.payload == .text or node.payload == .text_input or node.payload == .text_area) return node;
            for (node.children.items) |child| {
                if (self.findTextNode(child)) |res| return res;
            }
            return null;
        }

        fn clearSelectionVisuals(node: *Node(MessageT)) void {
            if (node.payload == .text) node.text_selection = null;
            for (node.children.items) |child| clearSelectionVisuals(child);
        }

        fn clearTextSelection(self: *Self, root: *Node(MessageT)) void {
            self.selection_anchor = null;
            self.selection_focus = null;
            clearSelectionVisuals(root);
        }

        fn collectSelectionOrders(
            node: *Node(MessageT),
            anchor: *Node(MessageT),
            focus: *Node(MessageT),
            counter: *u32,
            anchor_order: *?u32,
            focus_order: *?u32,
        ) void {
            if (node.payload == .text) {
                if (node == anchor) anchor_order.* = counter.*;
                if (node == focus) focus_order.* = counter.*;
                counter.* += 1;
            }
            for (node.children.items) |child| {
                collectSelectionOrders(child, anchor, focus, counter, anchor_order, focus_order);
            }
        }

        fn applySelectionSpanWalk(
            node: *Node(MessageT),
            start_order: u32,
            start_off: usize,
            end_order: u32,
            end_off: usize,
            counter: *u32,
        ) void {
            if (node.payload == .text) {
                const o = counter.*;
                counter.* += 1;
                const content_len = node.payload.text.content.len;
                if (o < start_order or o > end_order) {
                    node.text_selection = null;
                } else if (start_order == end_order) {
                    node.text_selection = .{ .anchor = start_off, .focus = end_off };
                } else if (o == start_order) {
                    node.text_selection = .{ .anchor = start_off, .focus = content_len };
                } else if (o == end_order) {
                    node.text_selection = .{ .anchor = 0, .focus = end_off };
                } else {
                    node.text_selection = .{ .anchor = 0, .focus = content_len };
                }
            }
            for (node.children.items) |child| {
                applySelectionSpanWalk(child, start_order, start_off, end_order, end_off, counter);
            }
        }

        const OrderedSpan = struct {
            start_order: u32,
            start_off: usize,
            end_order: u32,
            end_off: usize,
        };

        fn orderedSpan(self: *Self, root: *Node(MessageT)) ?OrderedSpan {
            const anchor = self.selection_anchor orelse return null;
            const focus = self.selection_focus orelse return null;

            var counter: u32 = 0;
            var anchor_order: ?u32 = null;
            var focus_order: ?u32 = null;
            collectSelectionOrders(root, anchor.node, focus.node, &counter, &anchor_order, &focus_order);

            const ao = anchor_order orelse return null;
            const fo = focus_order orelse return null;

            const focus_first = fo < ao or (fo == ao and focus.offset < anchor.offset);
            if (focus_first) {
                return .{ .start_order = fo, .start_off = focus.offset, .end_order = ao, .end_off = anchor.offset };
            }
            return .{ .start_order = ao, .start_off = anchor.offset, .end_order = fo, .end_off = focus.offset };
        }

        fn applyTextSelectionSpan(self: *Self, root: *Node(MessageT)) void {
            const span = self.orderedSpan(root) orelse {
                clearSelectionVisuals(root);
                return;
            };
            var counter: u32 = 0;
            applySelectionSpanWalk(root, span.start_order, span.start_off, span.end_order, span.end_off, &counter);
        }

        fn resolveSelectableTextIndexAtCursor(self: *Self, tn: *Node(MessageT)) ?usize {
            if (tn.payload != .text) return null;

            const metrics = tn.layout_result.text_cache.metrics;
            if (metrics.len == 0) return null;

            const padding = tn.style.padding;
            const border = tn.style.border;
            const inset_left = padding.left + @max(0.0, border.left.width);
            const inset_top = padding.top + @max(0.0, border.top.width);
            const local_x = @as(f32, @floatCast(self.mouse_x)) - (tn.layout_result.x + inset_left);
            const local_y = @as(f32, @floatCast(self.mouse_y)) - (tn.layout_result.y + inset_top);

            var found_line = false;
            var line_min_x: f32 = 0.0;
            var line_max_x: f32 = 0.0;
            var line_start: usize = 0;
            var line_end: usize = 0;

            for (metrics) |m| {
                if (local_y >= m.y and local_y < m.y + m.height) {
                    const glyph_min_x = m.x;
                    const glyph_max_x = m.x + m.width;
                    if (!found_line) {
                        found_line = true;
                        line_min_x = glyph_min_x;
                        line_max_x = glyph_max_x;
                        line_start = m.byte_offset;
                        line_end = m.byte_offset + m.byte_length;
                    } else {
                        line_min_x = @min(line_min_x, glyph_min_x);
                        line_max_x = @max(line_max_x, glyph_max_x);
                        line_start = @min(line_start, m.byte_offset);
                        line_end = @max(line_end, m.byte_offset + m.byte_length);
                    }
                }
            }

            if (!found_line) return null;

            const content_len = tn.payload.text.content.len;
            if (local_x <= line_min_x) return @min(line_start, content_len);
            if (local_x >= line_max_x) return @min(line_end, content_len);
            for (metrics) |m| {
                if (local_y >= m.y and local_y < m.y + m.height) {
                    const midpoint = m.x + (m.width / 2.0);
                    if (local_x < midpoint) return @min(m.byte_offset, content_len);
                    if (local_x <= m.x + m.width) return @min(m.byte_offset + m.byte_length, content_len);
                }
            }

            return @min(line_end, content_len);
        }

        fn resolveTextSelectionPointAtCursor(self: *Self, node: *Node(MessageT)) ?SelectionPoint {
            if (node.style.display == .none) return null;
            const t = node.getTransformedRect();
            const mx: f32 = @floatCast(self.mouse_x);
            const my: f32 = @floatCast(self.mouse_y);
            const inside = mx >= t.x and mx <= t.x + t.width and my >= t.y and my <= t.y + t.height;
            if (node.clipsChildren() and !inside) return null;

            var result: ?SelectionPoint = null;
            if (node.payload == .text and inside) {
                if (self.resolveSelectableTextIndexAtCursor(node)) |idx| {
                    result = .{ .node = node, .offset = idx };
                }
            }
            for (node.children.items) |child| {
                if (self.resolveTextSelectionPointAtCursor(child)) |r| result = r;
            }
            return result;
        }

        fn appendSelectionSpanText(
            alloc: std.mem.Allocator,
            node: *Node(MessageT),
            span: OrderedSpan,
            counter: *u32,
            buf: *std.ArrayList(u8),
        ) !void {
            if (node.payload == .text) {
                const o = counter.*;
                counter.* += 1;
                if (o >= span.start_order and o <= span.end_order) {
                    const content = node.payload.text.content;
                    var s: usize = 0;
                    var e: usize = content.len;
                    if (o == span.start_order) s = @min(span.start_off, content.len);
                    if (o == span.end_order) e = @min(span.end_off, content.len);
                    if (e > s) {
                        if (buf.items.len > 0) try buf.append(alloc, '\n');
                        try buf.appendSlice(alloc, content[s..e]);
                    }
                }
            }
            for (node.children.items) |child| {
                try appendSelectionSpanText(alloc, child, span, counter, buf);
            }
        }

        fn copySelectionToClipboard(self: *Self, root: *Node(MessageT)) void {
            const span = self.orderedSpan(root) orelse return;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            var counter: u32 = 0;
            appendSelectionSpanText(self.allocator, root, span, &counter, &buf) catch return;
            if (buf.items.len == 0) return;
            const c_str = self.allocator.dupeZ(u8, buf.items) catch return;
            defer self.allocator.free(c_str);
            self.setClipboard(c_str);
        }

        fn deleteSelectedRange(self: *Self, node: *Node(MessageT)) bool {
            const edit = editableTextRef(node) orelse return false;

            const anchor_raw = edit.selection_anchor.* orelse return false;
            const buf_len = edit.buffer.items.len;
            // The cursor / selection anchor can be advanced past the buffer when
            // a placeholder is being rendered (its glyph metrics let click
            // hit-tests pick a position beyond `buffer.items.len`). Clamp before
            // computing the slice arithmetic to avoid integer underflow.
            const anchor = @min(anchor_raw, buf_len);
            const cursor = @min(edit.cursor_index.*, buf_len);
            const start = @min(anchor, cursor);
            const end = @max(anchor, cursor);

            if (start == end) {
                edit.selection_anchor.* = null;
                edit.cursor_index.* = cursor;
                return false;
            }

            const items = edit.buffer.items;
            const remaining = items.len - end;

            std.mem.copyForwards(u8, edit.buffer.items[start..], items[end..][0..remaining]);
            edit.buffer.shrinkRetainingCapacity(items.len - (end - start));

            edit.cursor_index.* = start;
            edit.selection_anchor.* = null;

            node.markDirty();
            self.layout_requested = true;
            self.updateTextAreaNavigationX(node);
            self.ensureTextAreaCursorVisible(node);
            return true;
        }

        pub fn pushChar(self: *Self, codepoint: u21) void {
            if (self.focused_node) |node| {
                if (editableTextRef(node)) |edit| {
                    if (!edit.multiline and (codepoint == '\n' or codepoint == '\r')) {
                    } else {
                        _ = self.deleteSelectedRange(node);

                        var utf8_buf: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(codepoint, &utf8_buf)) |len| {
                            edit.buffer.insertSlice(node.allocator, edit.cursor_index.*, utf8_buf[0..len]) catch return;
                            edit.cursor_index.* += len;
                            edit.selection_anchor.* = null;
                            node.markDirty();
                            self.layout_requested = true;
                            self.updateTextAreaNavigationX(node);
                            self.ensureTextAreaCursorVisible(node);
                        } else |_| {}
                    }
                }

                if (node.hasEventBinding(.text_input)) {
                    self.dispatchNodeEvent(node, .text_input, .{ .text = .{ .codepoint = codepoint } });
                }
            }
        }

        pub fn pushKey(self: *Self, root: *Node(MessageT), key: i32, action: i32, is_ctrl: bool, is_shift: bool) void {
            if (self.shortcut_handler) |handler| {
                if (handler(self.shortcut_context, self, key, action, is_ctrl, is_shift)) return;
            }

            if (key == glfw.KeyTab and action == glfw.Press) {
                const claimed = if (self.focused_node) |f| f.claims_input else false;
                if (!claimed) {
                    self.traverseFocus(root);
                    return;
                }
            }

            if ((action == glfw.Press or action == glfw.Repeat)) {
                if (self.selection_anchor) |anchor| {
                    if (is_ctrl and key == glfw.KeyC) {
                        self.copySelectionToClipboard(root);
                        return;
                    } else if (is_ctrl and key == glfw.KeyA) {
                        const len = anchor.node.payload.text.content.len;
                        if (len > 0) {
                            self.selection_anchor = .{ .node = anchor.node, .offset = 0 };
                            self.selection_focus = .{ .node = anchor.node, .offset = len };
                            self.applyTextSelectionSpan(root);
                            self.paint_requested = true;
                        }
                        return;
                    }
                }
            }

            if (self.focused_node) |node| {
                if (action == glfw.Press or action == glfw.Repeat) {
                    if (editableTextRef(node)) |edit| {
                        if (is_ctrl and key == glfw.KeyA) {
                            if (edit.buffer.items.len > 0) {
                                edit.selection_anchor.* = 0;
                                edit.cursor_index.* = edit.buffer.items.len;
                                self.layout_requested = true;
                                self.updateTextAreaNavigationX(node);
                                self.ensureTextAreaCursorVisible(node);
                            }
                        } else if (is_ctrl and key == glfw.KeyC) {
                            if (edit.selection_anchor.*) |anchor| {
                                const start = @min(anchor, edit.cursor_index.*);
                                const end = @max(anchor, edit.cursor_index.*);
                                if (start != end) {
                                    const selected = edit.buffer.items[start..end];
                                    const c_str = self.allocator.dupeZ(u8, selected) catch return;
                                    defer self.allocator.free(c_str);
                                    self.setClipboard(c_str);
                                }
                            }
                        } else if (is_ctrl and key == glfw.KeyV) {
                            if (self.getClipboard()) |content| {
                                if (content.len > 0) {
                                    _ = self.deleteSelectedRange(node);
                                    edit.buffer.insertSlice(node.allocator, edit.cursor_index.*, content) catch return;
                                    edit.cursor_index.* += content.len;
                                    edit.selection_anchor.* = null;
                                    node.markDirty();
                                    self.layout_requested = true;
                                    self.updateTextAreaNavigationX(node);
                                    self.ensureTextAreaCursorVisible(node);
                                }
                            }
                        } else if ((key == glfw.KeyEnter or key == glfw.KeyKpEnter) and edit.multiline) {
                            _ = self.deleteSelectedRange(node);
                            const newline = [_]u8{'\n'};
                            edit.buffer.insertSlice(node.allocator, edit.cursor_index.*, newline[0..]) catch return;
                            edit.cursor_index.* += 1;
                            edit.selection_anchor.* = null;
                            node.markDirty();
                            self.layout_requested = true;
                            self.updateTextAreaNavigationX(node);
                            self.ensureTextAreaCursorVisible(node);
                        } else if (key == glfw.KeyBackspace) {
                            if (!self.deleteSelectedRange(node)) {
                                const items = edit.buffer.items;
                                if (items.len > 0 and edit.cursor_index.* > 0) {
                                    const remove_start = if (is_ctrl) 0 else prevUtf8Boundary(items, edit.cursor_index.*);
                                    const pop_count = edit.cursor_index.* - remove_start;

                                    std.mem.copyForwards(u8, edit.buffer.items[remove_start..], items[edit.cursor_index.*..]);
                                    edit.buffer.shrinkRetainingCapacity(items.len - pop_count);
                                    edit.cursor_index.* = remove_start;
                                    edit.selection_anchor.* = null;

                                    node.markDirty();
                                    self.layout_requested = true;
                                    self.updateTextAreaNavigationX(node);
                                    self.ensureTextAreaCursorVisible(node);
                                }
                            }
                        } else if (key == glfw.KeyLeft) {
                            edit.selection_anchor.* = null;
                            if (edit.cursor_index.* > 0) {
                                var moved = false;
                                for (node.layout_result.text_cache.metrics) |m| {
                                    if (m.byte_offset + m.byte_length == edit.cursor_index.*) {
                                        edit.cursor_index.* = m.byte_offset;
                                        self.layout_requested = true;
                                        moved = true;
                                        break;
                                    }
                                }
                                if (!moved) {
                                    const next_idx = prevUtf8Boundary(edit.buffer.items, edit.cursor_index.*);
                                    if (next_idx != edit.cursor_index.*) {
                                        edit.cursor_index.* = next_idx;
                                        self.layout_requested = true;
                                        moved = true;
                                    }
                                }
                                if (moved) {
                                    self.updateTextAreaNavigationX(node);
                                    self.ensureTextAreaCursorVisible(node);
                                }
                            }
                        } else if (key == glfw.KeyRight) {
                            edit.selection_anchor.* = null;
                            if (edit.cursor_index.* < edit.buffer.items.len) {
                                var moved = false;
                                for (node.layout_result.text_cache.metrics) |m| {
                                    if (m.byte_offset == edit.cursor_index.*) {
                                        edit.cursor_index.* = m.byte_offset + m.byte_length;
                                        self.layout_requested = true;
                                        moved = true;
                                        break;
                                    }
                                }
                                if (!moved) {
                                    const next_idx = nextUtf8Boundary(edit.buffer.items, edit.cursor_index.*);
                                    if (next_idx != edit.cursor_index.*) {
                                        edit.cursor_index.* = next_idx;
                                        self.layout_requested = true;
                                        moved = true;
                                    }
                                }
                                if (moved) {
                                    self.updateTextAreaNavigationX(node);
                                    self.ensureTextAreaCursorVisible(node);
                                }
                            }
                        } else if (key == glfw.KeyUp and edit.multiline) {
                            edit.selection_anchor.* = null;
                            _ = self.moveTextAreaCursorVertical(node, -1);
                        } else if (key == glfw.KeyDown and edit.multiline) {
                            edit.selection_anchor.* = null;
                            _ = self.moveTextAreaCursorVertical(node, 1);
                        } else if (key == glfw.KeyDelete) {
                            if (!self.deleteSelectedRange(node)) {
                                const items = edit.buffer.items;
                                if (edit.cursor_index.* < items.len) {
                                    const next_idx = nextUtf8Boundary(items, edit.cursor_index.*);
                                    const del_count = next_idx - edit.cursor_index.*;

                                    const remaining = items.len - (edit.cursor_index.* + del_count);
                                    std.mem.copyForwards(
                                        u8,
                                        edit.buffer.items[edit.cursor_index.*..],
                                        items[edit.cursor_index.* + del_count ..][0..remaining],
                                    );
                                    edit.buffer.shrinkRetainingCapacity(items.len - del_count);
                                    edit.selection_anchor.* = null;

                                    node.markDirty();
                                    self.layout_requested = true;
                                    self.updateTextAreaNavigationX(node);
                                    self.ensureTextAreaCursorVisible(node);
                                }
                            }
                        } else if (key == glfw.KeyHome) {
                            edit.selection_anchor.* = null;
                            edit.cursor_index.* = 0;
                            self.layout_requested = true;
                            self.updateTextAreaNavigationX(node);
                            self.ensureTextAreaCursorVisible(node);
                        } else if (key == glfw.KeyEnd) {
                            edit.selection_anchor.* = null;
                            edit.cursor_index.* = edit.buffer.items.len;
                            self.layout_requested = true;
                            self.updateTextAreaNavigationX(node);
                            self.ensureTextAreaCursorVisible(node);
                        }
                    }

                    if (node.hasEventBinding(.key_down)) {
                        // Forward real modifier state (GLFW mod bits: shift=0x1,
                        // ctrl=0x2) so handlers can bind chords like ctrl+z.
                        const dispatch_mods: i32 = (if (is_shift) @as(i32, 0x0001) else 0) | (if (is_ctrl) @as(i32, 0x0002) else 0);
                        self.dispatchNodeEvent(node, .key_down, .{ .key = .{ .key = key, .action = action, .mods = dispatch_mods } });
                    }
                }
            }
        }

        fn traverseFocus(self: *Self, root: *Node(MessageT)) void {
            var focusable_nodes = std.ArrayList(*Node(MessageT)).empty;
            defer focusable_nodes.deinit(self.allocator);

            buildFocusArray(self, root, &focusable_nodes);

            if (focusable_nodes.items.len == 0) return;

            var next_idx: usize = 0;
            if (self.focused_node) |current| {
                for (focusable_nodes.items, 0..) |node, i| {
                    if (node == current) {
                        next_idx = (i + 1) % focusable_nodes.items.len;
                        current.is_focused = false;
                        break;
                    }
                }
            }

            const next_node = focusable_nodes.items[next_idx];
            self.focused_node = next_node;
            next_node.is_focused = true;
        }

        fn buildFocusArray(self: *Self, node: *Node(MessageT), list: *std.ArrayList(*Node(MessageT))) void {
            if (node.is_focusable) list.append(self.allocator, node) catch unreachable;

            for (node.children.items) |child| {
                buildFocusArray(self, child, list);
            }
        }

        fn hitTestVerticalThumb(self: *Self, node: *Node(MessageT)) bool {
            const mouse_x: f32 = @floatCast(self.mouse_x);
            const mouse_y: f32 = @floatCast(self.mouse_y);
            if (node.getVerticalScrollbarThumbRect()) |thumb| {
                return mouse_x >= thumb.x and mouse_x <= thumb.x + thumb.width and
                    mouse_y >= thumb.y and mouse_y <= thumb.y + thumb.height;
            }
            return false;
        }

        fn hitTestHorizontalThumb(self: *Self, node: *Node(MessageT)) bool {
            const mouse_x: f32 = @floatCast(self.mouse_x);
            const mouse_y: f32 = @floatCast(self.mouse_y);
            if (node.getHorizontalScrollbarThumbRect()) |thumb| {
                return mouse_x >= thumb.x and mouse_x <= thumb.x + thumb.width and
                    mouse_y >= thumb.y and mouse_y <= thumb.y + thumb.height;
            }
            return false;
        }

        fn evaluatePointerCapture(self: *Self, node: *Node(MessageT)) void {
            var current: ?*Node(MessageT) = node;
            while (current) |n| {
                const hit_v = self.hitTestVerticalThumb(n);
                const hit_h = self.hitTestHorizontalThumb(n);
                if (hit_v or hit_h) {
                    self.active_drag_node = n;
                    self.previous_drag_x = self.mouse_x;
                    self.previous_drag_y = self.mouse_y;
                    self.drag_capture_start_x = self.mouse_x;
                    self.drag_capture_start_y = self.mouse_y;
                    self.active_drag_has_moved = false;
                    self.active_drag_axis = if (hit_v) .Vertical else .Horizontal;
                    return;
                }
                current = n.parent;
            }

            current = node;
            while (current) |n| {
                if (n.hasEventBinding(.drag)) {
                    self.active_drag_node = n;
                    self.previous_drag_x = self.mouse_x;
                    self.previous_drag_y = self.mouse_y;
                    self.drag_capture_start_x = self.mouse_x;
                    self.drag_capture_start_y = self.mouse_y;
                    self.active_drag_has_moved = false;
                    self.active_drag_axis = .None;
                    return;
                }
                current = n.parent;
            }
        }

        fn processInternalScrollDrag(self: *Self, node: *Node(MessageT), delta_x: f32, delta_y: f32) void {
            if (self.active_drag_axis == .Vertical) {
                const thumb = node.getVerticalScrollbarThumbRect() orelse {
                    self.active_drag_node = null;
                    self.active_drag_axis = .None;
                    return;
                };
                if (thumb.track_height <= 0.0 or thumb.max_scroll <= 0.0) return;
                const scroll_per_px = thumb.max_scroll / thumb.track_height;
                const new_scroll = std.math.clamp(
                    node.scroll_y + delta_y * scroll_per_px,
                    0.0,
                    thumb.max_scroll,
                );

                if (@abs(node.scroll_y - new_scroll) > 0.01) {
                    node.scroll_y = new_scroll;
                    node.markPositionDirty();
                    self.layout_requested = true;
                    self.scroll_changed = true;
                }
            } else if (self.active_drag_axis == .Horizontal) {
                const thumb = node.getHorizontalScrollbarThumbRect() orelse {
                    self.active_drag_node = null;
                    self.active_drag_axis = .None;
                    return;
                };
                const track_width = thumb.track_height;
                if (track_width <= 0.0 or thumb.max_scroll <= 0.0) return;
                const scroll_per_px = thumb.max_scroll / track_width;
                const new_scroll = std.math.clamp(
                    node.scroll_x + delta_x * scroll_per_px,
                    0.0,
                    thumb.max_scroll,
                );

                if (@abs(node.scroll_x - new_scroll) > 0.01) {
                    node.scroll_x = new_scroll;
                    node.markPositionDirty();
                    self.layout_requested = true;
                    self.scroll_changed = true;
                }
            }
        }

        fn processScrollWheel(self: *Self) void {
            if (self.scroll_delta_x == 0.0 and self.scroll_delta_y == 0.0) return;
            if (self.active_drag_node != null) return;

            var target = self.hovered_node;
            while (target) |node| {
                var consumed = false;

                if (node.payload == .text_area and self.scroll_delta_y != 0.0) {
                    const ta = &node.payload.text_area;
                    const bdr = node.style.border;
                    const pad = node.style.padding;
                    const inset_top = pad.top + @max(0.0, bdr.top.width);
                    const inset_bottom = pad.bottom + @max(0.0, bdr.bottom.width);
                    const viewport_h = @max(0.0, node.layout_result.height - inset_top - inset_bottom);
                    const max_scroll = @max(0.0, node.layout_result.text_cache.height - viewport_h);

                    if (max_scroll > 0.0) {
                        const next = std.math.clamp(
                            ta.scroll_y - self.scroll_delta_y * SCROLL_SPEED_MULTIPLIER,
                            0.0,
                            max_scroll,
                        );
                        if (@abs(next - ta.scroll_y) > 0.01) {
                            ta.scroll_y = next;
                            self.paint_requested = true;
                            self.scroll_changed = true;
                        }
                        consumed = true;
                    }
                }

                if (!consumed and node.hasEventBinding(.scroll)) {
                    const event_data = EventData{ .scroll = .{
                        .dx = self.scroll_delta_x,
                        .dy = self.scroll_delta_y,
                        .mods = self.mouse_mods,
                    } };
                    const layout_snap = types.EventLayoutSnapshot{
                        .x = node.layout_result.x,
                        .y = node.layout_result.y,
                        .width = node.layout_result.width,
                        .height = node.layout_result.height,
                    };
                    var emitted = false;
                    for (node.events) |binding| {
                        if (binding.event != .scroll) continue;
                        if (binding.handler) |h| {
                            if (h(binding.userdata, layout_snap, event_data)) |msg| {
                                self.message_queue.append(self.allocator, .{
                                    .id = msg,
                                    .source = node,
                                    .data = event_data,
                                }) catch unreachable;
                                emitted = true;
                            }
                        } else if (binding.msg) |msg_id| {
                            self.message_queue.append(self.allocator, .{
                                .id = msg_id,
                                .source = node,
                                .data = event_data,
                            }) catch unreachable;
                            emitted = true;
                        }
                    }
                    if (emitted) {
                        consumed = true;
                        break;
                    }
                }

                if (!consumed and self.scroll_delta_y != 0.0) {
                    if (node.style.overflow_y == .scroll) {
                        const max_scroll_y = @max(0.0, node.layout_result.content_height - node.layout_result.height);
                        if (max_scroll_y > 0.0) {
                            const next = std.math.clamp(
                                node.scroll_y - self.scroll_delta_y * SCROLL_SPEED_MULTIPLIER,
                                0.0,
                                max_scroll_y,
                            );
                            if (@abs(next - node.scroll_y) > 0.01) {
                                node.scroll_y = next;
                                node.markPositionDirty();
                                self.layout_requested = true;
                                self.scroll_changed = true;
                            }
                            consumed = true;
                        }
                    } else if (node.style.overflow_x == .scroll and self.scroll_delta_x == 0.0) {
                        const max_scroll_x = @max(0.0, node.layout_result.content_width - node.layout_result.width);
                        if (max_scroll_x > 0.0) {
                            const next = std.math.clamp(
                                node.scroll_x - self.scroll_delta_y * SCROLL_SPEED_MULTIPLIER,
                                0.0,
                                max_scroll_x,
                            );
                            if (@abs(next - node.scroll_x) > 0.01) {
                                node.scroll_x = next;
                                node.markPositionDirty();
                                self.layout_requested = true;
                                self.scroll_changed = true;
                            }
                            consumed = true;
                        }
                    }
                }

                if (!consumed and self.scroll_delta_x != 0.0 and node.style.overflow_x == .scroll) {
                    const max_scroll_x = @max(0.0, node.layout_result.content_width - node.layout_result.width);
                    if (max_scroll_x > 0.0) {
                        const next = std.math.clamp(
                            node.scroll_x - self.scroll_delta_x * SCROLL_SPEED_MULTIPLIER,
                            0.0,
                            max_scroll_x,
                        );
                        if (@abs(next - node.scroll_x) > 0.01) {
                            node.scroll_x = next;
                            node.markPositionDirty();
                            self.layout_requested = true;
                            self.scroll_changed = true;
                        }
                        consumed = true;
                    }
                }

                if (consumed) break;

                target = node.parent;
            }
        }

        const HitCandidate = struct {
            node: *Node(MessageT),
            z_index: i32,
            render_order: u64,
        };

        fn isInteractiveHitNode(node: *Node(MessageT)) bool {
            return node.style.pointer_events != .none and
                (node.events.len > 0 or
                    node.is_focusable or
                    node.payload == .text_input or
                    node.payload == .text_area or
                    node.payload == .text or
                    node.style.hover_color != null or
                    node.style.overflow_x == .scroll or
                    node.style.overflow_y == .scroll);
        }

        fn considerHitCandidate(
            self: *Self,
            best: *?HitCandidate,
            node: *Node(MessageT),
            render_order: *u64,
            effective_z: i32,
        ) void {
            _ = self;
            const candidate = HitCandidate{
                .node = node,
                .z_index = effective_z,
                .render_order = render_order.*,
            };
            render_order.* += 1;

            if (best.*) |current| {
                const wins_by_z = candidate.z_index > current.z_index;
                const wins_by_order = candidate.z_index == current.z_index and
                    candidate.render_order > current.render_order;
                if (wins_by_z or wins_by_order) {
                    best.* = candidate;
                }
                return;
            }

            best.* = candidate;
        }

        fn collectHitCandidate(
            self: *Self,
            node: *Node(MessageT),
            best: *?HitCandidate,
            render_order: *u64,
            parent_z: i32,
        ) void {
            if (node.style.display == .none) return;
            const effective_z = parent_z + node.style.z_index;

            const mouse_x: f32 = @floatCast(self.mouse_x);
            const mouse_y: f32 = @floatCast(self.mouse_y);
            const transformed = node.getTransformedRect();

            const hit_x = mouse_x >= transformed.x and mouse_x <= transformed.x + transformed.width;
            const hit_y = mouse_y >= transformed.y and mouse_y <= transformed.y + transformed.height;
            const inside_bounds = hit_x and hit_y;

            if (node.clipsChildren() and !inside_bounds) {
                return;
            }

            if (isInteractiveHitNode(node) and inside_bounds) {
                self.considerHitCandidate(best, node, render_order, effective_z);
            }

            for (node.children.items) |child| {
                self.collectHitCandidate(child, best, render_order, effective_z);
            }

            if (node.getVerticalScrollbarThumbRect()) |thumb| {
                const hit_thumb =
                    mouse_x >= thumb.x and mouse_x <= thumb.x + thumb.width and
                    mouse_y >= thumb.y and mouse_y <= thumb.y + thumb.height;
                if (hit_thumb) {
                    self.considerHitCandidate(best, node, render_order, effective_z);
                }
            }

            if (node.getHorizontalScrollbarThumbRect()) |thumb| {
                const hit_thumb =
                    mouse_x >= thumb.x and mouse_x <= thumb.x + thumb.width and
                    mouse_y >= thumb.y and mouse_y <= thumb.y + thumb.height;
                if (hit_thumb) {
                    self.considerHitCandidate(best, node, render_order, effective_z);
                }
            }
        }

        fn hitTest(self: *Self, node: *Node(MessageT)) bool {
            var best: ?HitCandidate = null;
            var render_order: u64 = 0;
            self.collectHitCandidate(node, &best, &render_order, 0);

            if (best) |candidate| {
                self.hovered_node = candidate.node;
                return true;
            }

            return false;
        }
    };
}

pub fn destroyResidualMessages(
    comptime MessageT: type,
    allocator: std.mem.Allocator,
    items: []InteractionMessage(MessageT),
) void {
    if (comptime !messageTypeHasDeinit(MessageT)) return;
    for (items) |msg| {
        var copy = msg.id;
        copy.deinit(allocator);
    }
}

fn messageTypeHasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}

fn findNodeById(comptime MessageT: type, node: *Node(MessageT), id: NodeId) ?*Node(MessageT) {
    if (node.id) |node_id| {
        if (node_id == id) return node;
    }
    for (node.children.items) |child| {
        if (findNodeById(MessageT, child, id)) |found| return found;
    }
    return null;
}

// Explicit style.cursor wins (deepest non-null ancestor); else auto by payload.
fn resolveCursor(comptime MessageT: type, hovered: ?*Node(MessageT)) Cursor {
    var cur = hovered;
    while (cur) |node| {
        if (node.style.cursor) |c| return c;
        cur = node.parent;
    }

    if (hovered) |node| {
        if (node.payload == .text_input) return .text;
        if (node.payload == .text_area) return .text;
        if (node.payload == .text) return .text;
        if (node.hasEventBinding(.click) or node.style.hover_color != null) return .pointer;
    }

    return .default;
}

const testing = std.testing;
const TestMessage = u32;
const TestNode = Node(TestMessage);
const TestInteractionRegistry = InteractionRegistry(TestMessage);

fn makeHitTestNode(allocator: std.mem.Allocator, style: Style, x: f32, y: f32, width: f32, height: f32) !*TestNode {
    const node = try allocator.create(TestNode);
    node.* = TestNode.init();
    node.allocator = allocator;
    node.style = style;
    node.payload = .container;
    node.layout_result = .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .content_width = width,
        .content_height = height,
    };
    return node;
}

test "hitTest: higher z-index wins over sibling insertion order" {
    const allocator = testing.allocator;
    var registry = TestInteractionRegistry.init(allocator);
    defer registry.deinit();

    const root = try makeHitTestNode(allocator, .{}, 0, 0, 200, 200);
    defer root.deinit();

    const high = try makeHitTestNode(allocator, .{ .z_index = 10 }, 0, 0, 120, 120);
    high.events = try allocator.dupe(EventBinding(TestMessage), &.{
        .{ .event = .click, .msg = 1 },
    });

    const low = try makeHitTestNode(allocator, .{ .z_index = 1 }, 0, 0, 120, 120);
    low.events = try allocator.dupe(EventBinding(TestMessage), &.{
        .{ .event = .click, .msg = 2 },
    });

    try root.addChild(high);
    try root.addChild(low);

    registry.mouse_x = 40;
    registry.mouse_y = 40;

    try testing.expect(registry.hitTest(root));
    try testing.expect(registry.hovered_node == high);
}

test "hover chain: ancestor with hover_enter binding receives event when descendant claims hit via hover_color" {
    const allocator = testing.allocator;
    var registry = TestInteractionRegistry.init(allocator);
    defer registry.deinit();

    const root = try makeHitTestNode(allocator, .{}, 0, 0, 200, 200);
    defer root.deinit();

    const outer = try makeHitTestNode(allocator, .{}, 0, 0, 100, 100);
    outer.events = try allocator.dupe(EventBinding(TestMessage), &.{
        .{ .event = .hover_enter, .msg = 42 },
        .{ .event = .hover_exit, .msg = 99 },
    });

    const inner = try makeHitTestNode(allocator, .{ .hover_color = .{ 1, 1, 1, 1 } }, 10, 10, 50, 50);

    try outer.addChild(inner);
    try root.addChild(outer);

    registry.mouse_x = 30;
    registry.mouse_y = 30;

    try testing.expect(registry.hitTest(root));
    try testing.expect(registry.hovered_node == inner);

    registry.buildHoverChainFromHit(inner);
    registry.diffHoverChain(0.0);

    try testing.expectEqual(@as(usize, 1), registry.message_queue.items.len);
    try testing.expectEqual(@as(TestMessage, 42), registry.message_queue.items[0].id);
    try testing.expect(outer.is_hovered);
    try testing.expect(inner.is_hovered);

    // Move cursor outside both. Both should get hover_exit; outer fires its binding.
    registry.message_queue.clearRetainingCapacity();
    registry.mouse_x = 500;
    registry.mouse_y = 500;
    registry.swapHoverChains();
    registry.hover_chain.clearRetainingCapacity();
    registry.diffHoverChain(0.0);

    try testing.expectEqual(@as(usize, 1), registry.message_queue.items.len);
    try testing.expectEqual(@as(TestMessage, 99), registry.message_queue.items[0].id);
    try testing.expect(!outer.is_hovered);
    try testing.expect(!inner.is_hovered);
}

test "hover chain: cursor moves between gap and inner; outer fires no spurious enter/exit" {
    const allocator = testing.allocator;
    var registry = TestInteractionRegistry.init(allocator);
    defer registry.deinit();

    const root = try makeHitTestNode(allocator, .{}, 0, 0, 200, 200);
    defer root.deinit();

    const outer = try makeHitTestNode(allocator, .{}, 0, 0, 100, 100);
    outer.events = try allocator.dupe(EventBinding(TestMessage), &.{
        .{ .event = .hover_enter, .msg = 1 },
        .{ .event = .hover_exit, .msg = 2 },
    });

    const inner = try makeHitTestNode(allocator, .{ .hover_color = .{ 1, 1, 1, 1 } }, 25, 25, 50, 50);

    try outer.addChild(inner);
    try root.addChild(outer);

    // Frame 1: cursor inside outer's padding (gap), not inner. Hit = outer.
    registry.mouse_x = 5;
    registry.mouse_y = 5;
    _ = registry.hitTest(root);
    try testing.expect(registry.hovered_node == outer);
    registry.buildHoverChainFromHit(registry.hovered_node.?);
    registry.diffHoverChain(0.0);
    try testing.expectEqual(@as(usize, 1), registry.message_queue.items.len);
    try testing.expectEqual(@as(TestMessage, 1), registry.message_queue.items[0].id);

    // Frame 2: cursor moves onto inner. Hit = inner. Outer must NOT fire enter again
    // (it stays in chain) or fire exit (still contains cursor).
    registry.message_queue.clearRetainingCapacity();
    registry.swapHoverChains();
    registry.hover_chain.clearRetainingCapacity();
    registry.hovered_node = null;
    registry.mouse_x = 50;
    registry.mouse_y = 50;
    _ = registry.hitTest(root);
    try testing.expect(registry.hovered_node == inner);
    registry.buildHoverChainFromHit(registry.hovered_node.?);
    registry.diffHoverChain(0.0);
    try testing.expectEqual(@as(usize, 0), registry.message_queue.items.len);
    try testing.expect(outer.is_hovered);
    try testing.expect(inner.is_hovered);
}

test "hitTest: later sibling wins when z-index ties" {
    const allocator = testing.allocator;
    var registry = TestInteractionRegistry.init(allocator);
    defer registry.deinit();

    const root = try makeHitTestNode(allocator, .{}, 0, 0, 200, 200);
    defer root.deinit();

    const first = try makeHitTestNode(allocator, .{ .z_index = 4 }, 0, 0, 120, 120);
    first.events = try allocator.dupe(EventBinding(TestMessage), &.{
        .{ .event = .click, .msg = 1 },
    });

    const second = try makeHitTestNode(allocator, .{ .z_index = 4 }, 0, 0, 120, 120);
    second.events = try allocator.dupe(EventBinding(TestMessage), &.{
        .{ .event = .click, .msg = 2 },
    });

    try root.addChild(first);
    try root.addChild(second);

    registry.mouse_x = 40;
    registry.mouse_y = 40;

    try testing.expect(registry.hitTest(root));
    try testing.expect(registry.hovered_node == second);
}
