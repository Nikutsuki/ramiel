const std = @import("std");
const Node = @import("../ui/node.zig").Node;
const QuadBatcher = @import("../renderer/vulkan/batcher.zig").QuadBatcher;

pub const DevToolsTab = enum {
    inspector,
    profiler,
    memory,
    graphics,
};

pub fn DevToolsState(comptime MessageT: type) type {
    return struct {
        const Self = @This();
        pub const frame_history_capacity: usize = 240;

        is_active: bool = false,
        request_rebuild: bool = false,
        active_tab: DevToolsTab = .inspector,
        panel_width: f32 = 360.0,

        hovered_node: ?*Node(MessageT) = null,
        selected_node: ?*Node(MessageT) = null,

        metrics: struct {
            total_allocations: usize = 0,
            draw_calls: u32 = 0,
            active_textures: u32 = 0,
            frame_time_ms: f32 = 0.0,
            frame_time_history_ms: [frame_history_capacity]f32 = [_]f32{0.0} ** frame_history_capacity,
            frame_time_history_len: usize = 0,
            frame_time_history_head: usize = 0,
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
                if (n.style.z_index == 1_000_000 and n.style.position == .absolute) {
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

        pub fn renderHighlights(self: *Self, batcher: *QuadBatcher, retained_root: *Node(MessageT)) !void {
            if (!self.is_active) return;

            try batcher.setZIndex(2_000_000);

            if (self.hovered_node) |node| {
                if (containsNodePtr(retained_root, node) and !isDevToolsSubtree(node)) {
                    const lr = node.layout_result;
                    try batcher.addRect(
                        lr.x,
                        lr.y,
                        lr.width,
                        lr.height,
                        .{ 0.2, 0.5, 1.0, 0.4 },
                        0,
                        0,
                        .{ 0, 0, 0, 0 },
                    );
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
                        .{ 1.0, 0.4, 0.2, 0.4 },
                        0,
                        0,
                        .{ 0, 0, 0, 0 },
                    );
                } else if (!containsNodePtr(retained_root, node)) {
                    self.selected_node = null;
                }
            }
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
    };
}
