const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const Buffer = @import("buffer.zig").Buffer;
const TextureRegistry = @import("texture_registry.zig").TextureRegistry;
const Pipeline = @import("pipeline.zig").Pipeline;
const vk_common = @import("vk_common.zig");
const c = vk_common.c;

const MAX_FRAMES_IN_FLIGHT = @import("frame_manager.zig").MAX_FRAMES_IN_FLIGHT;
const MAX_BINDLESS = Pipeline.MAX_BINDLESS_TEXTURES;

pub const GlobalUniforms = extern struct {
    projection: @import("math.zig").Mat4,
    time: f32,
    _pad: f32,
    viewport_size: [2]f32,
};

pub const ResourceManager = struct {
    const MAX_TRACKED_BINDINGS = 32;

    const OffscreenBindingState = struct {
        valid: bool = false,
        image_view: vk.ImageView = .null_handle,
        sampler: vk.Sampler = .null_handle,
    };

    allocator: std.mem.Allocator,

    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
    global_ubo_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,

    instance_buffer: Buffer,

    max_instances: usize,

    texture_registry: TextureRegistry,

    descriptor_dirty_mask: [MAX_FRAMES_IN_FLIGHT]u32,
    offscreen_bindings: [MAX_TRACKED_BINDINGS]OffscreenBindingState,

    last_global_ubo: GlobalUniforms,
    has_last_global_ubo: bool,
    ubo_synced_mask: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        core: *Core,
        pipeline_layout: vk.DescriptorSetLayout,
        max_instances: usize,
    ) !ResourceManager {
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{
                .type = .combined_image_sampler,
                .descriptor_count = (MAX_BINDLESS * MAX_FRAMES_IN_FLIGHT) + MAX_FRAMES_IN_FLIGHT,
            },
            .{
                .type = .uniform_buffer,
                .descriptor_count = MAX_FRAMES_IN_FLIGHT,
            },
        };

        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .update_after_bind_bit = true },
            .max_sets = MAX_FRAMES_IN_FLIGHT,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @ptrCast(&pool_sizes),
        };

        const descriptor_pool = try core.vkd.createDescriptorPool(core.logical_device, &pool_info, null);

        const set_layouts = [_]vk.DescriptorSetLayout{ pipeline_layout, pipeline_layout };

        const counts = [_]u32{ MAX_BINDLESS, MAX_BINDLESS };
        var count_info = vk.DescriptorSetVariableDescriptorCountAllocateInfo{
            .descriptor_set_count = MAX_FRAMES_IN_FLIGHT,
            .p_descriptor_counts = &counts,
        };

        const alloc_info = vk.DescriptorSetAllocateInfo{
            .p_next = @ptrCast(&count_info),
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = MAX_FRAMES_IN_FLIGHT,
            .p_set_layouts = &set_layouts,
        };

        var descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet = undefined;
        _ = try core.vkd.allocateDescriptorSets(core.logical_device, &alloc_info, @ptrCast(&descriptor_sets));

        var global_ubo_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer = undefined;
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            global_ubo_buffers[i] = try Buffer.init(core, @sizeOf(GlobalUniforms), .{ .uniform_buffer_bit = true }, c.VMA_MEMORY_USAGE_CPU_TO_GPU, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT));
        }

        const inst_size = @sizeOf(@import("vertex.zig").Instance) * max_instances * MAX_FRAMES_IN_FLIGHT;

        const instance_buffer = try Buffer.init(core, inst_size, .{ .vertex_buffer_bit = true }, c.VMA_MEMORY_USAGE_CPU_TO_GPU, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT));

        const texture_registry = try TextureRegistry.init(allocator, io, core, &descriptor_sets);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const ubo_info = vk.DescriptorBufferInfo{
                .buffer = global_ubo_buffers[i].handle,
                .offset = 0,
                .range = @sizeOf(GlobalUniforms),
            };

            const write_set = vk.WriteDescriptorSet{
                .dst_set = descriptor_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_buffer_info = @ptrCast(&ubo_info),
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            };

            const writes = [_]vk.WriteDescriptorSet{write_set};
            core.vkd.updateDescriptorSets(core.logical_device, writes[0..], null);
        }

        return ResourceManager{
            .allocator = allocator,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
            .global_ubo_buffers = global_ubo_buffers,
            .instance_buffer = instance_buffer,
            .max_instances = max_instances,
            .texture_registry = texture_registry,
            .descriptor_dirty_mask = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]u32),
            .offscreen_bindings = std.mem.zeroes([MAX_TRACKED_BINDINGS]OffscreenBindingState),
            .last_global_ubo = undefined,
            .has_last_global_ubo = false,
            .ubo_synced_mask = 0,
        };
    }

    pub fn deinit(self: *ResourceManager, core: *Core) void {
        self.texture_registry.deinit(core);
        self.instance_buffer.deinit(core);
        for (&self.global_ubo_buffers) |*buf| buf.deinit(core);
        core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);
    }

    pub fn resizeBuffers(self: *ResourceManager, core: *Core, new_max_instances: usize) !void {
        try core.vkd.deviceWaitIdle(core.logical_device);

        self.instance_buffer.deinit(core);

        const inst_size = @sizeOf(@import("vertex.zig").Instance) * new_max_instances * MAX_FRAMES_IN_FLIGHT;

        self.instance_buffer = try Buffer.init(core, inst_size, .{ .vertex_buffer_bit = true }, c.VMA_MEMORY_USAGE_CPU_TO_GPU, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT));

        self.max_instances = new_max_instances;
    }

    pub fn updateGlobalUbo(self: *ResourceManager, frame_index: usize, data: GlobalUniforms) void {
        const frame_bit: u32 = @as(u32, 1) << @as(u5, @intCast(frame_index));
        if (self.has_last_global_ubo and std.meta.eql(data, self.last_global_ubo) and (self.ubo_synced_mask & frame_bit) != 0) {
            return;
        }

        const ptr = self.global_ubo_buffers[frame_index].mapped_ptr.?;
        @memcpy(ptr[0..@sizeOf(GlobalUniforms)], std.mem.asBytes(&data));

        if (!self.has_last_global_ubo or !std.meta.eql(data, self.last_global_ubo)) {
            self.last_global_ubo = data;
            self.has_last_global_ubo = true;
            self.ubo_synced_mask = 0;
        }

        self.ubo_synced_mask |= frame_bit;
    }

    pub fn markOffscreenDescriptorDirty(self: *ResourceManager, binding: u32, image_view: vk.ImageView, sampler: vk.Sampler) !void {
        if (binding >= MAX_TRACKED_BINDINGS) return error.DescriptorBindingOutOfRange;

        self.offscreen_bindings[binding] = .{
            .valid = true,
            .image_view = image_view,
            .sampler = sampler,
        };

        const binding_bit: u32 = @as(u32, 1) << @as(u5, @intCast(binding));
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.descriptor_dirty_mask[i] |= binding_bit;
        }
    }

    pub fn updateOffscreenDescriptor(self: *ResourceManager, core: *Core, frame_index: usize, binding: u32, image_view: vk.ImageView, sampler: vk.Sampler) void {
        const offscreen_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = image_view,
            .sampler = sampler,
        };

        const write_offscreen_set = vk.WriteDescriptorSet{
            .dst_set = self.descriptor_sets[frame_index],
            .dst_binding = binding,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&offscreen_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        const writes = [_]vk.WriteDescriptorSet{write_offscreen_set};
        core.vkd.updateDescriptorSets(core.logical_device, writes[0..], null);
    }

    pub fn flushDescriptorUpdates(self: *ResourceManager, core: *Core, frame_index: usize) !void {
        var mask = self.descriptor_dirty_mask[frame_index];
        while (mask != 0) {
            const bit_index = @ctz(mask);
            const bit: u32 = @intCast(bit_index);
            const binding: u32 = bit;

            if (binding >= MAX_TRACKED_BINDINGS) return error.DescriptorBindingOutOfRange;
            const state = self.offscreen_bindings[binding];
            if (state.valid) {
                self.updateOffscreenDescriptor(core, frame_index, binding, state.image_view, state.sampler);
            }

            mask &= ~(@as(u32, 1) << @as(u5, @intCast(bit)));
        }

        self.descriptor_dirty_mask[frame_index] = 0;
    }
};
