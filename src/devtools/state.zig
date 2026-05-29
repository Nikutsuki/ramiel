const std = @import("std");
const Node = @import("../ui/node.zig").Node;
const QuadBatcher = @import("../renderer/vulkan/batcher.zig").QuadBatcher;
const layout = @import("../ui/layout.zig");
const Spacing = layout.Spacing;
const CornerRadius = layout.CornerRadius;
const FlexDirection = layout.FlexDirection;
const JustifyContent = layout.JustifyContent;
const FlexAlign = layout.FlexAlign;

pub const DevToolsTab = enum {
    inspector,
    profiler,
    memory,
    graphics,
};

pub const devtools_z_index: i32 = 1_000_000;

/// Stable id for the inspector tree scroll container, so the host can scroll it
/// to reveal a picked element after reconcile.
pub const tree_scroll_id: u32 = 0xD7_5C_011;
pub const tree_row_height: f32 = 23.0;
pub const tree_viewport_height: f32 = 260.0;

pub const EditAction = enum {
    opacity_dec,
    opacity_inc,
    padding_dec,
    padding_inc,
    gap_dec,
    gap_inc,
    radius_dec,
    radius_inc,
    dir_toggle,
    justify_cycle,
    align_cycle,
    bg_alpha_dec,
    bg_alpha_inc,
    toggle_hidden,
    reset,
};

pub const StyleOverride = struct {
    opacity: ?f32 = null,
    padding_all: ?f32 = null,
    gap: ?f32 = null,
    corner_all: ?f32 = null,
    direction: ?FlexDirection = null,
    justify: ?JustifyContent = null,
    align_items: ?FlexAlign = null,
    bg: ?[4]f32 = null,
    hidden: bool = false,

    pub fn isEmpty(self: StyleOverride) bool {
        return self.opacity == null and self.padding_all == null and self.gap == null and
            self.corner_all == null and self.direction == null and self.justify == null and
            self.align_items == null and self.bg == null and !self.hidden;
    }
};

pub const PayloadKind = enum {
    none,
    fragment,
    container,
    portal,
    text,
    rich_text,
    image,
    canvas,
    text_input,
    text_area,
    video,
    custom_paint,
};

pub const FrameStats = struct {
    sample_count: usize = 0,
    last_ms: f32 = 0.0,
    avg_ms: f32 = 0.0,
    min_ms: f32 = 0.0,
    max_ms: f32 = 0.0,
    p95_ms: f32 = 0.0,
    fps: f32 = 0.0,
};

pub const LayerSnapshot = struct {
    z: i32 = 0,
    draw_calls: u32 = 0,
    quads: u32 = 0,
    indices: u32 = 0,
    has_blur: bool = false,
};

pub fn DevToolsState(comptime MessageT: type) type {
    return struct {
        const Self = @This();
        pub const frame_history_capacity: usize = 240;
        pub const max_layer_snapshots: usize = 32;
        pub const max_collapsed: usize = 1024;
        pub const max_overrides: usize = 64;
        pub const min_panel_width: f32 = 300.0;
        pub const max_panel_width: f32 = 1000.0;

        const OverrideEntry = struct {
            node: *Node(MessageT),
            override: StyleOverride,
        };

        is_active: bool = false,
        request_rebuild: bool = false,
        pick_mode: bool = false,
        scroll_to_selected: bool = false,
        active_tab: DevToolsTab = .inspector,
        panel_width: f32 = 420.0,

        hovered_node: ?*Node(MessageT) = null,
        selected_node: ?*Node(MessageT) = null,
        inspect_hover_node: ?*Node(MessageT) = null,
        prev_highlight: ?*Node(MessageT) = null,

        collapsed: [max_collapsed]?*Node(MessageT) = [_]?*Node(MessageT){null} ** max_collapsed,
        collapsed_len: usize = 0,

        overrides: [max_overrides]OverrideEntry = undefined,
        overrides_len: usize = 0,

        metrics: struct {
            total_allocations: usize = 0,
            draw_calls: u32 = 0,
            active_textures: u32 = 0,
            frame_time_ms: f32 = 0.0,
            frame_time_history_ms: [frame_history_capacity]f32 = [_]f32{0.0} ** frame_history_capacity,
            frame_time_history_len: usize = 0,
            frame_time_history_head: usize = 0,

            quad_count: u32 = 0,
            vertex_count: u32 = 0,
            index_count: u32 = 0,
            layer_count: u32 = 0,
            blur_layer_count: u32 = 0,
            layer_snapshots: [max_layer_snapshots]LayerSnapshot = [_]LayerSnapshot{.{}} ** max_layer_snapshots,
            layer_snapshot_count: usize = 0,

            node_count: u32 = 0,
            max_depth: u32 = 0,
            payload_counts: [std.meta.fields(PayloadKind).len]u32 = [_]u32{0} ** std.meta.fields(PayloadKind).len,
        } = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn setActive(self: *Self, active: bool) void {
            if (self.is_active == active) return;
            self.is_active = active;
            self.request_rebuild = true;
        }

        pub fn toggle(self: *Self) void {
            self.is_active = !self.is_active;
            self.request_rebuild = true;
        }

        pub fn setTab(self: *Self, tab: DevToolsTab) void {
            if (self.active_tab == tab) return;
            self.active_tab = tab;
            self.request_rebuild = true;
        }

        pub fn selectNode(self: *Self, node: ?*Node(MessageT)) void {
            self.selected_node = node;
            self.request_rebuild = true;
        }

        pub fn setInspectHover(self: *Self, node: ?*Node(MessageT)) void {
            self.inspect_hover_node = node;
        }

        pub fn togglePickMode(self: *Self) void {
            self.pick_mode = !self.pick_mode;
            if (!self.pick_mode) self.inspect_hover_node = null;
            self.request_rebuild = true;
        }

        pub fn pickHover(self: *Self, node: ?*Node(MessageT)) void {
            if (node) |n| {
                self.inspect_hover_node = if (isDevToolsSubtree(n)) null else n;
            } else {
                self.inspect_hover_node = null;
            }
        }

        pub fn commitPick(self: *Self, node: ?*Node(MessageT)) void {
            self.pick_mode = false;
            self.inspect_hover_node = null;
            if (node) |n| {
                if (!isDevToolsSubtree(n)) {
                    self.selected_node = n;
                    self.expandAncestors(n);
                    self.scroll_to_selected = true;
                }
            }
            self.request_rebuild = true;
        }

        pub fn expandAncestors(self: *Self, node: *Node(MessageT)) void {
            var cur = node.parent;
            while (cur) |p| {
                self.removeCollapsed(p);
                cur = p.parent;
            }
        }

        fn removeCollapsed(self: *Self, node: *Node(MessageT)) void {
            var i: usize = 0;
            while (i < self.collapsed_len) : (i += 1) {
                if (self.collapsed[i] == node) {
                    self.collapsed[i] = self.collapsed[self.collapsed_len - 1];
                    self.collapsed_len -= 1;
                    return;
                }
            }
        }

        /// Scroll offset that reveals (and roughly centers) the selected row in the
        /// inspector tree. Rows are uniform height so a flat index is enough.
        pub fn computeTreeScroll(self: *Self, root: *Node(MessageT)) ?f32 {
            const target = self.selected_node orelse return null;
            var found: ?usize = null;
            var count: usize = 0;
            self.countTreeRows(root, target, &found, &count);
            const idx = found orelse return null;

            const content_h = @as(f32, @floatFromInt(count)) * tree_row_height;
            const max_scroll = @max(0.0, content_h - tree_viewport_height);
            const want = @as(f32, @floatFromInt(idx)) * tree_row_height - tree_viewport_height / 2.0 + tree_row_height / 2.0;
            return std.math.clamp(want, 0.0, max_scroll);
        }

        fn countTreeRows(self: *Self, node: *Node(MessageT), target: *Node(MessageT), found: *?usize, count: *usize) void {
            if (node.style.z_index == devtools_z_index and node.style.position == .absolute) return;
            if (node == target) found.* = count.*;
            count.* += 1;
            if (self.isCollapsed(node)) return;
            for (node.children.items) |child| {
                self.countTreeRows(child, target, found, count);
            }
        }

        pub fn clearInspectHover(self: *Self, node: *Node(MessageT)) void {
            if (self.inspect_hover_node == node) self.inspect_hover_node = null;
        }

        pub fn resizeBy(self: *Self, delta: f32) void {
            self.panel_width = std.math.clamp(self.panel_width - delta, min_panel_width, max_panel_width);
            self.request_rebuild = true;
        }

        fn findOverride(self: *Self, node: *Node(MessageT)) ?*OverrideEntry {
            var i: usize = 0;
            while (i < self.overrides_len) : (i += 1) {
                if (self.overrides[i].node == node) return &self.overrides[i];
            }
            return null;
        }

        pub fn overrideFor(self: *const Self, node: *Node(MessageT)) ?StyleOverride {
            var i: usize = 0;
            while (i < self.overrides_len) : (i += 1) {
                if (self.overrides[i].node == node) return self.overrides[i].override;
            }
            return null;
        }

        fn ensureOverride(self: *Self, node: *Node(MessageT)) ?*StyleOverride {
            if (self.findOverride(node)) |e| return &e.override;
            if (self.overrides_len >= max_overrides) return null;
            self.overrides[self.overrides_len] = .{ .node = node, .override = .{} };
            self.overrides_len += 1;
            return &self.overrides[self.overrides_len - 1].override;
        }

        fn clearOverrideFor(self: *Self, node: *Node(MessageT)) void {
            var i: usize = 0;
            while (i < self.overrides_len) : (i += 1) {
                if (self.overrides[i].node == node) {
                    self.overrides[i] = self.overrides[self.overrides_len - 1];
                    self.overrides_len -= 1;
                    return;
                }
            }
        }

        pub fn applyEdit(self: *Self, action: EditAction) void {
            const node = self.selected_node orelse return;
            self.request_rebuild = true;

            if (action == .reset) {
                self.clearOverrideFor(node);
                return;
            }

            const ov = self.ensureOverride(node) orelse return;
            const s = node.style;
            switch (action) {
                .opacity_dec => ov.opacity = std.math.clamp((ov.opacity orelse s.opacity) - 0.1, 0.0, 1.0),
                .opacity_inc => ov.opacity = std.math.clamp((ov.opacity orelse s.opacity) + 0.1, 0.0, 1.0),
                .padding_dec => ov.padding_all = @max(0.0, (ov.padding_all orelse s.padding.top) - 2.0),
                .padding_inc => ov.padding_all = (ov.padding_all orelse s.padding.top) + 2.0,
                .gap_dec => ov.gap = @max(0.0, (ov.gap orelse s.gap) - 2.0),
                .gap_inc => ov.gap = (ov.gap orelse s.gap) + 2.0,
                .radius_dec => ov.corner_all = @max(0.0, (ov.corner_all orelse s.corner_radius.top_left) - 2.0),
                .radius_inc => ov.corner_all = (ov.corner_all orelse s.corner_radius.top_left) + 2.0,
                .dir_toggle => ov.direction = if ((ov.direction orelse s.direction) == .Row) .Column else .Row,
                .justify_cycle => ov.justify = cycleEnum(JustifyContent, ov.justify orelse s.justify_content),
                .align_cycle => ov.align_items = cycleEnum(FlexAlign, ov.align_items orelse s.align_items),
                .bg_alpha_dec => {
                    var c = ov.bg orelse s.background_color;
                    c[3] = std.math.clamp(c[3] - 0.1, 0.0, 1.0);
                    ov.bg = c;
                },
                .bg_alpha_inc => {
                    var c = ov.bg orelse s.background_color;
                    c[3] = std.math.clamp(c[3] + 0.1, 0.0, 1.0);
                    ov.bg = c;
                },
                .toggle_hidden => ov.hidden = !ov.hidden,
                .reset => unreachable,
            }

            if (self.findOverride(node)) |e| {
                if (e.override.isEmpty()) self.clearOverrideFor(node);
            }
        }

        pub fn applyOverrides(self: *Self, root: *Node(MessageT)) void {
            var i: usize = 0;
            while (i < self.overrides_len) {
                const entry = self.overrides[i];
                if (!containsNodePtr(root, entry.node)) {
                    self.overrides[i] = self.overrides[self.overrides_len - 1];
                    self.overrides_len -= 1;
                    continue;
                }
                applyOneOverride(entry.node, entry.override);
                i += 1;
            }
        }

        fn applyOneOverride(node: *Node(MessageT), ov: StyleOverride) void {
            if (ov.opacity) |v| node.style.opacity = v;
            if (ov.padding_all) |v| node.style.padding = Spacing.all(v);
            if (ov.gap) |v| node.style.gap = v;
            if (ov.corner_all) |v| node.style.corner_radius = CornerRadius.all(v);
            if (ov.direction) |v| node.style.direction = v;
            if (ov.justify) |v| node.style.justify_content = v;
            if (ov.align_items) |v| node.style.align_items = v;
            if (ov.bg) |v| node.style.background_color = v;
            if (ov.hidden) node.style.display = .none;
            // markSizeDirty bails out (without propagating to parents) when the
            // node's size flag is already set, which can leave an intermediate
            // ancestor position-clean. arrangeNode then refuses to descend into
            // it, so child-arrangement edits (justify/align/direction/gap) never
            // take effect until a viewport change forces a full relayout. Dirty
            // the whole path to the root unconditionally so the override always
            // re-arranges this frame.
            node.markDirtyWithAncestors();
            // align_items == .Stretch overwrites children's cross-axis size in
            // arrangeFlexChildren; cycling away from it does not restore them
            // unless the children are re-measured, so dirty the subtree too.
            markSubtreeDirty(node);
        }

        fn markSubtreeDirty(node: *Node(MessageT)) void {
            node.flags = .{};
            for (node.children.items) |child| markSubtreeDirty(child);
        }

        pub fn isCollapsed(self: *const Self, node: *Node(MessageT)) bool {
            var i: usize = 0;
            while (i < self.collapsed_len) : (i += 1) {
                if (self.collapsed[i] == node) return true;
            }
            return false;
        }

        pub fn toggleCollapsed(self: *Self, node: *Node(MessageT)) void {
            var i: usize = 0;
            while (i < self.collapsed_len) : (i += 1) {
                if (self.collapsed[i] == node) {
                    self.collapsed[i] = self.collapsed[self.collapsed_len - 1];
                    self.collapsed_len -= 1;
                    self.request_rebuild = true;
                    return;
                }
            }
            if (self.collapsed_len < max_collapsed) {
                self.collapsed[self.collapsed_len] = node;
                self.collapsed_len += 1;
                self.request_rebuild = true;
            }
        }

        pub fn syncInteractionTargets(self: *Self, hovered: ?*Node(MessageT), selected: ?*Node(MessageT)) void {
            self.hovered_node = hovered;
            if (selected) |node| {
                if (isDevToolsSubtree(node)) return;
                if (self.selected_node != node) {
                    self.selected_node = node;
                    self.request_rebuild = true;
                }
            }
        }

        fn isDevToolsSubtree(node: *Node(MessageT)) bool {
            var cur: ?*Node(MessageT) = node;
            while (cur) |n| {
                if (n.style.z_index == devtools_z_index and n.style.position == .absolute) {
                    return true;
                }
                cur = n.parent;
            }
            return false;
        }

        pub fn pushFrameTime(self: *Self, frame_time_ms: f32) void {
            self.metrics.frame_time_ms = frame_time_ms;
            self.metrics.frame_time_history_ms[self.metrics.frame_time_history_head] = frame_time_ms;
            self.metrics.frame_time_history_head = (self.metrics.frame_time_history_head + 1) % frame_history_capacity;
            if (self.metrics.frame_time_history_len < frame_history_capacity) {
                self.metrics.frame_time_history_len += 1;
            }
        }

        pub fn frameTimeAt(self: *const Self, idx: usize) f32 {
            const len = self.metrics.frame_time_history_len;
            if (idx >= len) return 0.0;
            const head = self.metrics.frame_time_history_head;
            const start = (head + frame_history_capacity - len) % frame_history_capacity;
            return self.metrics.frame_time_history_ms[(start + idx) % frame_history_capacity];
        }

        pub fn frameStats(self: *const Self) FrameStats {
            const len = self.metrics.frame_time_history_len;
            if (len == 0) return .{};

            var sorted: [frame_history_capacity]f32 = undefined;
            var sum: f64 = 0.0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const v = self.frameTimeAt(i);
                sorted[i] = v;
                sum += v;
            }
            std.mem.sort(f32, sorted[0..len], {}, std.sort.asc(f32));

            const avg = @as(f32, @floatCast(sum / @as(f64, @floatFromInt(len))));
            const p95_idx = @min(len - 1, (len * 95) / 100);
            return .{
                .sample_count = len,
                .last_ms = self.metrics.frame_time_ms,
                .avg_ms = avg,
                .min_ms = sorted[0],
                .max_ms = sorted[len - 1],
                .p95_ms = sorted[p95_idx],
                .fps = if (avg > 0.0001) 1000.0 / avg else 0.0,
            };
        }

        pub fn captureGraphicsMetrics(self: *Self, batcher: *const QuadBatcher) void {
            var quads: u32 = 0;
            var verts: u32 = 0;
            var indices: u32 = 0;
            var draw_calls: u32 = 0;
            var layer_count: u32 = 0;
            var blur_layers: u32 = 0;
            self.metrics.layer_snapshot_count = 0;

            for (batcher.layers.items) |layer| {
                if (layer.z >= devtools_z_index) continue;
                const v: u32 = @intCast(layer.data.vertices.items.len);
                const idx: u32 = @intCast(layer.data.indices.items.len);
                const cmds: u32 = @intCast(layer.data.commands.items.len);
                if (v == 0 and cmds == 0) continue;

                verts += v;
                indices += idx;
                quads += v / 4;
                draw_calls += cmds;
                layer_count += 1;
                if (layer.data.has_blur) blur_layers += 1;

                if (self.metrics.layer_snapshot_count < max_layer_snapshots) {
                    self.metrics.layer_snapshots[self.metrics.layer_snapshot_count] = .{
                        .z = layer.z,
                        .draw_calls = cmds,
                        .quads = v / 4,
                        .indices = idx,
                        .has_blur = layer.data.has_blur,
                    };
                    self.metrics.layer_snapshot_count += 1;
                }
            }

            self.metrics.quad_count = quads;
            self.metrics.vertex_count = verts;
            self.metrics.index_count = indices;
            self.metrics.draw_calls = draw_calls;
            self.metrics.layer_count = layer_count;
            self.metrics.blur_layer_count = blur_layers;
        }

        pub fn captureTreeMetrics(self: *Self, root: *Node(MessageT)) void {
            self.metrics.node_count = 0;
            self.metrics.max_depth = 0;
            self.metrics.payload_counts = [_]u32{0} ** std.meta.fields(PayloadKind).len;
            walkTreeMetrics(self, root, 0);
        }

        fn walkTreeMetrics(self: *Self, node: *Node(MessageT), depth: u32) void {
            if (node.style.z_index == devtools_z_index and node.style.position == .absolute) return;
            self.metrics.node_count += 1;
            if (depth > self.metrics.max_depth) self.metrics.max_depth = depth;
            self.metrics.payload_counts[@intFromEnum(payloadKind(node))] += 1;
            for (node.children.items) |child| {
                walkTreeMetrics(self, child, depth + 1);
            }
        }

        pub fn renderHighlights(self: *Self, batcher: *QuadBatcher, retained_root: *Node(MessageT)) !void {
            if (!self.is_active) return;

            try batcher.setZIndex(2_000_000);

            const hover_target = self.inspect_hover_node orelse self.hovered_node;
            if (hover_target) |node| {
                if (containsNodePtr(retained_root, node) and !isDevToolsSubtree(node)) {
                    try drawBoxModelOverlay(batcher, node);
                } else if (self.inspect_hover_node == node and !containsNodePtr(retained_root, node)) {
                    self.inspect_hover_node = null;
                }
            }

            if (self.selected_node) |node| {
                if (containsNodePtr(retained_root, node) and !isDevToolsSubtree(node)) {
                    const lr = node.layout_result;
                    try batcher.addRect(
                        lr.x,
                        lr.y,
                        lr.width,
                        lr.height,
                        .{ 1.0, 0.4, 0.2, 0.35 },
                        0,
                        0,
                        .{ 0, 0, 0, 0 },
                    );
                } else if (!containsNodePtr(retained_root, node)) {
                    self.selected_node = null;
                }
            }
        }

        fn drawBoxModelOverlay(batcher: *QuadBatcher, node: *Node(MessageT)) !void {
            const lr = node.layout_result;
            const m = node.style.margin;
            try batcher.addRect(
                lr.x - m.left,
                lr.y - m.top,
                lr.width + m.left + m.right,
                lr.height + m.top + m.bottom,
                .{ 0.95, 0.6, 0.1, 0.18 },
                0,
                0,
                .{ 0, 0, 0, 0 },
            );
            try batcher.addRect(
                lr.x,
                lr.y,
                lr.width,
                lr.height,
                .{ 0.2, 0.5, 1.0, 0.35 },
                0,
                0,
                .{ 0, 0, 0, 0 },
            );
            const p = node.style.padding;
            try batcher.addRect(
                lr.x + p.left,
                lr.y + p.top,
                @max(0.0, lr.width - p.left - p.right),
                @max(0.0, lr.height - p.top - p.bottom),
                .{ 0.4, 0.85, 0.5, 0.3 },
                0,
                0,
                .{ 0, 0, 0, 0 },
            );
        }

        fn containsNodePtr(root: *Node(MessageT), target: *Node(MessageT)) bool {
            if (root == target) return true;
            for (root.children.items) |child| {
                if (containsNodePtr(child, target)) return true;
            }
            return false;
        }

        pub fn consumeRebuildRequest(self: *Self) bool {
            if (!self.request_rebuild) return false;
            self.request_rebuild = false;
            return true;
        }

        /// True when the element being highlighted (tree-hover, picker, or live
        /// cursor hover) changed since last call. Lets the host repaint exactly
        /// when the overlay needs to move instead of driving a continuous loop.
        pub fn consumeHighlightChange(self: *Self) bool {
            const target = self.inspect_hover_node orelse self.hovered_node;
            if (target != self.prev_highlight) {
                self.prev_highlight = target;
                return true;
            }
            return false;
        }
    };
}

pub fn cycleEnum(comptime E: type, value: E) E {
    const fields = std.meta.fields(E);
    const idx = (@as(usize, @intFromEnum(value)) + 1) % fields.len;
    return @enumFromInt(idx);
}

pub fn payloadKind(node: anytype) PayloadKind {
    return switch (node.payload) {
        .none => .none,
        .fragment => .fragment,
        .container => .container,
        .portal => .portal,
        .text => .text,
        .rich_text => .rich_text,
        .image => .image,
        .canvas => .canvas,
        .text_input => .text_input,
        .text_area => .text_area,
        .video => .video,
        .custom_paint => .custom_paint,
    };
}

const testing = std.testing;

test "cycleEnum wraps without overflow" {
    const J = JustifyContent;
    try testing.expectEqual(J.Center, cycleEnum(J, .Start));
    try testing.expectEqual(J.Start, cycleEnum(J, .SpaceAround));
    const A = FlexAlign;
    try testing.expectEqual(A.Start, cycleEnum(A, .Stretch));
}

test "style overrides keep applying across a cycle wrap" {
    const N = Node(u8);
    var node = N.init();
    node.allocator = testing.allocator;
    node.style.opacity = 1.0;

    var st = DevToolsState(u8).init();
    st.selected_node = &node;

    st.applyEdit(.opacity_dec);
    st.applyOverrides(&node);
    try testing.expect(@abs(node.style.opacity - 0.9) < 0.001);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        st.applyEdit(.justify_cycle);
        node.style = .{ .opacity = 1.0 };
        st.applyOverrides(&node);
    }

    try testing.expect(st.overrideFor(&node) != null);
    try testing.expect(@abs(node.style.opacity - 0.9) < 0.001);
    try testing.expect(node.style.justify_content != .Start or st.overrideFor(&node).?.justify != null);
}

test "align cycle keeps advancing and applying through a wrap" {
    const N = Node(u8);
    var node = N.init();
    node.allocator = testing.allocator;

    var st = DevToolsState(u8).init();
    st.selected_node = &node;

    const expected = [_]FlexAlign{ .Center, .End, .Stretch, .Start, .Center, .End };
    for (expected) |want| {
        st.applyEdit(.align_cycle);
        node.style = .{}; // simulate reconcile wiping the override back to app defaults
        st.applyOverrides(&node);
        try testing.expectEqual(want, node.style.align_items);
    }
}

const NoTextLayouter = struct {
    pub fn measureText(
        _: *NoTextLayouter,
        _: anytype,
        _: anytype,
        _: []const u8,
        _: f32,
    ) struct { width: f32, height: f32, metrics: []layout.TextLayoutMetric, is_bitmap: bool = false } {
        unreachable;
    }
};

// Reproduces the live-editor frame loop for a justify override: each "click"
// runs applyEdit, then a reconcile (which resets the node to the app-declared
// style), then applyOverrides + a full layout pass, exactly as Application.run
// does. Guards against the override silently failing to re-apply once the enum
// wraps back past its last variant.
test "justify cycle keeps re-arranging children through a wrap (full layout)" {
    const N = Node(u8);
    const alloc = testing.allocator;

    var row = N.init();
    row.allocator = alloc;
    const app_justify: JustifyContent = .Center;
    row.style = .{
        .direction = .Row,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 50 },
        .justify_content = app_justify,
    };
    defer row.children.deinit(alloc);

    var a = N.init();
    a.allocator = alloc;
    a.style = .{ .width = .{ .exact = 40 }, .height = .{ .exact = 20 } };
    var b = N.init();
    b.allocator = alloc;
    b.style = .{ .width = .{ .exact = 40 }, .height = .{ .exact = 20 } };
    try row.addChild(&a);
    try row.addChild(&b);

    var st = DevToolsState(u8).init();
    st.selected_node = &row;

    var tl = NoTextLayouter{};

    // First child x for each justify value: 300px row, two 40px children.
    // Start=0, Center=110, End=220, SpaceBetween=0, SpaceAround=55.
    const expected_x = [_]f32{ 220, 0, 55, 0, 110, 220 };
    for (expected_x) |want_x| {
        st.applyEdit(.justify_cycle);
        row.style.justify_content = app_justify; // reconcile resets to app default
        st.applyOverrides(&row);
        layout.measureNode(&row, &tl, 800, 600, true);
        layout.arrangeNode(&row, 0.0, 0.0);
        try testing.expectApproxEqAbs(want_x, a.layout_result.x, 0.01);
    }
}

// A justify/align override on a nested node must re-arrange that node's children
// even when an intermediate ancestor is position-clean and the node already
// carries a stale size-dirty flag. Before the fix this relied on markSizeDirty,
// which bailed out without propagating, leaving arrangeNode unable to descend
// (the "doesn't apply until you resize the window" bug).
test "override re-arranges through a position-clean ancestor" {
    const N = Node(u8);
    const alloc = testing.allocator;

    var root = N.init();
    root.allocator = alloc;
    root.style = .{ .direction = .Column, .width = .{ .exact = 300 }, .height = .{ .exact = 100 } };
    defer root.children.deinit(alloc);

    var mid = N.init();
    mid.allocator = alloc;
    mid.style = .{ .direction = .Column, .width = .Full };
    defer mid.children.deinit(alloc);

    var sel = N.init();
    sel.allocator = alloc;
    sel.style = .{ .direction = .Row, .width = .{ .exact = 300 }, .height = .{ .exact = 50 }, .justify_content = .Start };
    defer sel.children.deinit(alloc);

    var a = N.init();
    a.allocator = alloc;
    a.style = .{ .width = .{ .exact = 40 }, .height = .{ .exact = 20 } };
    var b = N.init();
    b.allocator = alloc;
    b.style = .{ .width = .{ .exact = 40 }, .height = .{ .exact = 20 } };
    try sel.addChild(&a);
    try sel.addChild(&b);
    try mid.addChild(&sel);
    try root.addChild(&mid);

    var tl = NoTextLayouter{};

    // Baseline layout: Start packs the first child at x=0 and clears all flags.
    layout.measureNode(&root, &tl, 800, 600, true);
    layout.arrangeNode(&root, 0.0, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0), a.layout_result.x, 0.01);

    // Reproduce the stuck state: sel is still size-dirty from an earlier frame
    // while its ancestors are clean.
    sel.flags.size = true;
    sel.flags.position = true;

    var st = DevToolsState(u8).init();
    st.selected_node = &sel;
    st.applyEdit(.justify_cycle); // Start -> Center
    st.applyOverrides(&root);

    layout.measureNode(&root, &tl, 800, 600, true);
    layout.arrangeNode(&root, 0.0, 0.0);

    // Center on a 300px row with two 40px children puts the first child at 110.
    try testing.expectApproxEqAbs(@as(f32, 110), a.layout_result.x, 0.01);
}

// align_items == .Stretch overwrites an Auto-sized child's cross extent during
// arrange. Cycling past Stretch must re-measure the child so it snaps back to
// its intrinsic size, otherwise it stays stuck at the stretched value.
test "align stretch is undone when cycling past it" {
    const N = Node(u8);
    const alloc = testing.allocator;

    var row = N.init();
    row.allocator = alloc;
    const app_align: FlexAlign = .Start;
    row.style = .{
        .direction = .Row,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 50 },
        .align_items = app_align,
    };
    defer row.children.deinit(alloc);

    var a = N.init();
    a.allocator = alloc;
    a.style = .{ .width = .{ .exact = 40 }, .height = .Auto };
    try row.addChild(&a);

    var st = DevToolsState(u8).init();
    st.selected_node = &row;

    var tl = NoTextLayouter{};

    // FlexAlign: Start, Center, End, Stretch. Heights of the Auto child: only
    // Stretch fills the 50px row; every other value leaves it at its intrinsic 0.
    const expected_h = [_]f32{ 0, 0, 50, 0, 0 };
    for (expected_h) |want_h| {
        st.applyEdit(.align_cycle);
        row.style.align_items = app_align; // reconcile resets to app default
        st.applyOverrides(&row);
        layout.measureNode(&row, &tl, 800, 600, true);
        layout.arrangeNode(&row, 0.0, 0.0);
        try testing.expectApproxEqAbs(want_h, a.layout_result.height, 0.01);
    }
}
