const std = @import("std");
const vk = @import("../../vk.zig");

pub const ResourceHandle = enum(u32) {
    swapchain = 0,
    scene_base = 1,
    _,

    pub fn fromInt(val: u32) ResourceHandle {
        return @enumFromInt(val);
    }
};

pub const ResourceUsage = struct {
    handle: ResourceHandle,
    layout: vk.ImageLayout,
    access: vk.AccessFlags,
    stage: vk.PipelineStageFlags,
};

pub const ResourceState = struct {
    layout: vk.ImageLayout,
    access: vk.AccessFlags,
    stage: vk.PipelineStageFlags,
};

pub const PassNode = struct {
    name: []const u8,
    inputs: []const ResourceUsage,
    outputs: []const ResourceUsage,

    is_transfer: bool = false,

    render_pass: vk.RenderPass = .null_handle,
    framebuffer: vk.Framebuffer = .null_handle,
    clear: bool = false,

    extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    slice_start: usize = 0,
    slice_end: usize = 0,

    payload: ?*anyopaque = null,
    executeFn: *const fn (ctx: ?*anyopaque, cb: vk.CommandBuffer) void,
};

pub const RenderGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(PassNode),
    sorted_nodes: std.ArrayList(PassNode),
    resource_states: std.AutoHashMap(ResourceHandle, ResourceState),

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return RenderGraph{
            .allocator = allocator,
            .nodes = std.ArrayList(PassNode).empty,
            .sorted_nodes = std.ArrayList(PassNode).empty,
            .resource_states = std.AutoHashMap(ResourceHandle, ResourceState).init(allocator),
        };
    }

    pub fn reset(self: *RenderGraph) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node.inputs);
            self.allocator.free(node.outputs);
        }
        self.nodes.clearRetainingCapacity();
        self.sorted_nodes.clearRetainingCapacity();
    }

    pub fn addPass(self: *RenderGraph, node: PassNode) !void {
        const inputs_copy = try self.allocator.dupe(ResourceUsage, node.inputs);
        errdefer self.allocator.free(inputs_copy);

        const outputs_copy = try self.allocator.dupe(ResourceUsage, node.outputs);
        errdefer self.allocator.free(outputs_copy);

        var owned = node;
        owned.inputs = inputs_copy;
        owned.outputs = outputs_copy;
        try self.nodes.append(self.allocator, owned);
    }

    pub fn compile(self: *RenderGraph) !void {
        self.sorted_nodes.clearRetainingCapacity();

        for (self.nodes.items) |node| {
            for (node.inputs) |input| {
                if (!self.resource_states.contains(input.handle)) {
                    try self.resource_states.put(input.handle, .{ .layout = .undefined, .access = .{}, .stage = .{ .top_of_pipe_bit = true } });
                }
            }
            for (node.outputs) |output| {
                if (!self.resource_states.contains(output.handle)) {
                    try self.resource_states.put(output.handle, .{ .layout = .undefined, .access = .{}, .stage = .{ .top_of_pipe_bit = true } });
                }
            }
        }

        const node_count = self.nodes.items.len;
        var in_degrees = try self.allocator.alloc(usize, node_count);
        defer self.allocator.free(in_degrees);
        @memset(in_degrees, 0);

        var adj = try self.allocator.alloc(std.ArrayList(usize), node_count);
        defer {
            for (adj) |*list| list.deinit(self.allocator);
            self.allocator.free(adj);
        }
        for (adj) |*list| list.* = std.ArrayList(usize).empty;

        var producer_map = std.AutoHashMap(ResourceHandle, usize).init(self.allocator);
        defer producer_map.deinit();

        for (self.nodes.items, 0..) |node, i| {
            for (node.inputs) |input| {
                if (producer_map.get(input.handle)) |producer_idx| {
                    try adj[producer_idx].append(self.allocator, i);
                    in_degrees[i] += 1;
                }
            }
            for (node.outputs) |output| {
                try producer_map.put(output.handle, i);
            }
        }

        var queue = std.ArrayList(usize).empty;
        defer queue.deinit(self.allocator);

        for (in_degrees, 0..) |deg, i| {
            if (deg == 0) try queue.append(self.allocator, i);
        }

        var sorted_count: usize = 0;
        while (queue.items.len > 0) {
            const current_idx = queue.orderedRemove(0);
            try self.sorted_nodes.append(self.allocator, self.nodes.items[current_idx]);
            sorted_count += 1;

            for (adj[current_idx].items) |dependent_idx| {
                in_degrees[dependent_idx] -= 1;
                if (in_degrees[dependent_idx] == 0) {
                    try queue.append(self.allocator, dependent_idx);
                }
            }
        }

        if (sorted_count != node_count) {
            return error.CircularDependencyDetected;
        }
    }

    pub fn injectBarriers(self: *RenderGraph, vkd: vk.DeviceWrapper, cb: vk.CommandBuffer, node: PassNode, image_map: *const std.AutoHashMap(ResourceHandle, vk.Image)) !void {
        var barriers = std.ArrayList(vk.ImageMemoryBarrier).empty;
        defer barriers.deinit(self.allocator);

        var src_stage: vk.PipelineStageFlags = .{};
        var dst_stage: vk.PipelineStageFlags = .{};

        const usages = [_][]const ResourceUsage{ node.inputs, node.outputs };

        for (usages) |usage_list| {
            for (usage_list) |usage| {
                var state = self.resource_states.getPtr(usage.handle).?;

                if (state.layout != usage.layout or @as(u32, @bitCast(state.access)) != @as(u32, @bitCast(usage.access))) {
                    const image = image_map.get(usage.handle) orelse return error.MissingPhysicalResource;

                    try barriers.append(self.allocator, vk.ImageMemoryBarrier{
                        .src_access_mask = state.access,
                        .dst_access_mask = usage.access,
                        .old_layout = state.layout,
                        .new_layout = usage.layout,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = image,
                        .subresource_range = .{
                            .aspect_mask = .{ .color_bit = true },
                            .base_mip_level = 0,
                            .level_count = 1,
                            .base_array_layer = 0,
                            .layer_count = 1,
                        },
                    });

                    const src_bits = @as(u32, @bitCast(src_stage)) | @as(u32, @bitCast(state.stage));
                    src_stage = @as(vk.PipelineStageFlags, @bitCast(src_bits));

                    const dst_bits = @as(u32, @bitCast(dst_stage)) | @as(u32, @bitCast(usage.stage));
                    dst_stage = @as(vk.PipelineStageFlags, @bitCast(dst_bits));

                    state.layout = usage.layout;
                    state.access = usage.access;
                    state.stage = usage.stage;
                }
            }
        }

        if (barriers.items.len > 0) {
            if (@as(u32, @bitCast(src_stage)) == 0) src_stage = .{ .top_of_pipe_bit = true };

            vkd.cmdPipelineBarrier(
                cb,
                src_stage,
                dst_stage,
                .{},
                null,
                null,
                barriers.items,
            );
        }
    }

    pub fn deinit(self: *RenderGraph) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node.inputs);
            self.allocator.free(node.outputs);
        }
        self.nodes.deinit(self.allocator);
        self.sorted_nodes.deinit(self.allocator);
        self.resource_states.deinit();
    }
};
