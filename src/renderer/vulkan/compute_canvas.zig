const std = @import("std");
const vk = @import("../../vk.zig");
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const Core = @import("core.zig").Core;
const Buffer = @import("buffer.zig").Buffer;
const Texture = @import("texture.zig").Texture;
const TextureRegistry = @import("texture_registry.zig").TextureRegistry;

const MAX_FRAMES_IN_FLIGHT = @import("frame_manager.zig").MAX_FRAMES_IN_FLIGHT;

pub const MAX_USER_PARAMS = 8;
pub const WORKGROUP_SIZE = 8;

pub const Uniforms = extern struct {
    resolution: [2]f32 = .{ 0, 0 },
    time: f32 = 0,
    delta: f32 = 0,
    frame: u32 = 0,
    _pad: [3]u32 = .{ 0, 0, 0 },
    user: [MAX_USER_PARAMS][4]f32 = std.mem.zeroes([MAX_USER_PARAMS][4]f32),
};

pub const InputImage = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

pub fn linearSampler(core: *const Core) !vk.Sampler {
    const info = vk.SamplerCreateInfo{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.Bool32.false,
        .max_anisotropy = 1.0,
        .compare_enable = vk.Bool32.false,
        .compare_op = .always,
        .min_lod = 0.0,
        .max_lod = 1.0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = vk.Bool32.false,
    };
    return core.vkd.createSampler(core.logical_device, &info, null);
}

pub fn runFilterOnce(
    core: *const Core,
    spirv: []const u32,
    width: u32,
    height: u32,
    input_pixels: []const u8,
    output_pixels: []u8,
    uniforms: Uniforms,
) !void {
    const byte_len = @as(usize, width) * @as(usize, height) * 4;
    if (input_pixels.len != byte_len or output_pixels.len != byte_len) return error.InvalidPixelData;
    if (spirv.len == 0) return error.EmptyShader;

    var input = try Texture.init(core, width, height, input_pixels);
    defer input.deinit(core);

    const sampler = try linearSampler(core);
    defer core.vkd.destroySampler(core.logical_device, sampler, null);

    const image_info = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .storage_bit = true, .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
        .initial_layout = .undefined,
    };
    const alloc_info = c.VmaAllocationCreateInfo{
        .flags = 0,
        .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = @intCast(c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        .preferredFlags = 0,
        .memoryTypeBits = 0,
        .pool = null,
        .pUserData = null,
        .priority = 0.0,
    };
    var out_image: vk.Image = .null_handle;
    var out_alloc: c.VmaAllocation = undefined;
    if (c.vmaCreateImage(core.vma_allocator, @ptrCast(&image_info), &alloc_info, @ptrCast(&out_image), &out_alloc, null) != c.VK_SUCCESS) {
        return error.ImageCreationFailed;
    }
    defer {
        const handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(out_image))));
        c.vmaDestroyImage(core.vma_allocator, handle, out_alloc);
    }

    const view_info = vk.ImageViewCreateInfo{
        .flags = .{},
        .image = out_image,
        .view_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    };
    const out_view = try core.vkd.createImageView(core.logical_device, &view_info, null);
    defer core.vkd.destroyImageView(core.logical_device, out_view, null);

    var ubo = try Buffer.init(core, @sizeOf(Uniforms), .{ .uniform_buffer_bit = true }, c.VMA_MEMORY_USAGE_CPU_TO_GPU, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT));
    defer ubo.deinit(core);
    var local_uniforms = uniforms;
    local_uniforms.resolution = .{ @floatFromInt(width), @floatFromInt(height) };
    @memcpy(ubo.mapped_ptr.?[0..@sizeOf(Uniforms)], std.mem.asBytes(&local_uniforms));

    var readback = try Buffer.init(core, @intCast(byte_len), .{ .transfer_dst_bit = true }, c.VMA_MEMORY_USAGE_CPU_ONLY, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT));
    defer readback.deinit(core);

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
    };
    const set_layout = try core.vkd.createDescriptorSetLayout(core.logical_device, &.{ .flags = .{}, .binding_count = bindings.len, .p_bindings = &bindings }, null);
    defer core.vkd.destroyDescriptorSetLayout(core.logical_device, set_layout, null);

    const pipeline_layout = try core.vkd.createPipelineLayout(core.logical_device, &.{ .flags = .{}, .set_layout_count = 1, .p_set_layouts = @ptrCast(&set_layout), .push_constant_range_count = 0, .p_push_constant_ranges = null }, null);
    defer core.vkd.destroyPipelineLayout(core.logical_device, pipeline_layout, null);

    const module = try core.vkd.createShaderModule(core.logical_device, &.{ .flags = .{}, .code_size = spirv.len * @sizeOf(u32), .p_code = spirv.ptr }, null);
    defer core.vkd.destroyShaderModule(core.logical_device, module, null);

    var pipelines: [1]vk.Pipeline = undefined;
    _ = try core.vkd.createComputePipelines(core.logical_device, .null_handle, &[_]vk.ComputePipelineCreateInfo{.{
        .flags = .{},
        .stage = .{ .flags = .{}, .stage = .{ .compute_bit = true }, .module = module, .p_name = "main", .p_specialization_info = null },
        .layout = pipeline_layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    }}, null, &pipelines);
    const pipeline = pipelines[0];
    defer core.vkd.destroyPipeline(core.logical_device, pipeline, null);

    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_image, .descriptor_count = 1 },
        .{ .type = .uniform_buffer, .descriptor_count = 1 },
        .{ .type = .combined_image_sampler, .descriptor_count = 1 },
    };
    const pool = try core.vkd.createDescriptorPool(core.logical_device, &.{ .flags = .{}, .max_sets = 1, .pool_size_count = pool_sizes.len, .p_pool_sizes = &pool_sizes }, null);
    defer core.vkd.destroyDescriptorPool(core.logical_device, pool, null);

    var set: vk.DescriptorSet = .null_handle;
    _ = try core.vkd.allocateDescriptorSets(core.logical_device, &.{ .descriptor_pool = pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&set_layout) }, @ptrCast(&set));

    const out_descriptor = vk.DescriptorImageInfo{ .sampler = .null_handle, .image_view = out_view, .image_layout = .general };
    const ubo_descriptor = vk.DescriptorBufferInfo{ .buffer = ubo.handle, .offset = 0, .range = @sizeOf(Uniforms) };
    const in_descriptor = vk.DescriptorImageInfo{ .sampler = sampler, .image_view = input.view, .image_layout = .shader_read_only_optimal };
    core.vkd.updateDescriptorSets(core.logical_device, &[_]vk.WriteDescriptorSet{
        .{ .dst_set = set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_image, .p_image_info = @ptrCast(&out_descriptor), .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
        .{ .dst_set = set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .uniform_buffer, .p_buffer_info = @ptrCast(&ubo_descriptor), .p_image_info = undefined, .p_texel_buffer_view = undefined },
        .{ .dst_set = set, .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = @ptrCast(&in_descriptor), .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
    }, null);

    const subresource = vk.ImageSubresourceRange{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
    const cb = try core.beginSingleTimeCommands();

    core.vkd.cmdPipelineBarrier(cb, .{ .top_of_pipe_bit = true }, .{ .compute_shader_bit = true }, .{}, null, null, &[_]vk.ImageMemoryBarrier{.{
        .src_access_mask = .{},
        .dst_access_mask = .{ .shader_write_bit = true },
        .old_layout = .undefined,
        .new_layout = .general,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = out_image,
        .subresource_range = subresource,
    }});

    core.vkd.cmdBindPipeline(cb, .compute, pipeline);
    core.vkd.cmdBindDescriptorSets(cb, .compute, pipeline_layout, 0, &[_]vk.DescriptorSet{set}, null);
    core.vkd.cmdDispatch(cb, (width + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE, (height + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE, 1);

    core.vkd.cmdPipelineBarrier(cb, .{ .compute_shader_bit = true }, .{ .transfer_bit = true }, .{}, null, null, &[_]vk.ImageMemoryBarrier{.{
        .src_access_mask = .{ .shader_write_bit = true },
        .dst_access_mask = .{ .transfer_read_bit = true },
        .old_layout = .general,
        .new_layout = .transfer_src_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = out_image,
        .subresource_range = subresource,
    }});

    core.vkd.cmdCopyImageToBuffer(cb, out_image, .transfer_src_optimal, readback.handle, &[_]vk.BufferImageCopy{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    }});

    try core.endSingleTimeCommands(cb);

    @memcpy(output_pixels, readback.mapped_ptr.?[0..byte_len]);
}

pub const ComputeBacking = struct {
    width: u32,
    height: u32,

    image: vk.Image,
    allocation: c.VmaAllocation,
    view: vk.ImageView,
    tex_id: u32,
    layout: vk.ImageLayout,

    input: ?Texture,
    input_sampler: vk.Sampler,

    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
    ubo_buffers: [MAX_FRAMES_IN_FLIGHT]Buffer,

    uniforms: Uniforms,

    pub fn create(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        spirv: []const u32,
        input_image: ?InputImage,
    ) !*ComputeBacking {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        if (spirv.len == 0) return error.EmptyShader;

        const self = try allocator.create(ComputeBacking);
        errdefer allocator.destroy(self);

        self.width = width;
        self.height = height;
        self.layout = .undefined;
        self.input = null;
        self.input_sampler = .null_handle;
        self.uniforms = .{ .resolution = .{ @floatFromInt(width), @floatFromInt(height) } };

        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .storage_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .initial_layout = .undefined,
        };

        const alloc_info = c.VmaAllocationCreateInfo{
            .flags = 0,
            .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = @intCast(c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
            .preferredFlags = 0,
            .memoryTypeBits = 0,
            .pool = null,
            .pUserData = null,
            .priority = 0.0,
        };

        if (c.vmaCreateImage(core.vma_allocator, @ptrCast(&image_info), &alloc_info, @ptrCast(&self.image), &self.allocation, null) != c.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }
        errdefer {
            const handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.image))));
            c.vmaDestroyImage(core.vma_allocator, handle, self.allocation);
        }

        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = self.image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        };
        self.view = try core.vkd.createImageView(core.logical_device, &view_info, null);
        errdefer core.vkd.destroyImageView(core.logical_device, self.view, null);

        self.tex_id = try texture_registry.registerManagedView(core, self.view);
        errdefer texture_registry.releaseManagedView(self.tex_id);

        if (input_image) |img| {
            self.input = try Texture.init(core, img.width, img.height, img.pixels);
            const sampler_info = vk.SamplerCreateInfo{
                .flags = .{},
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_mode = .linear,
                .address_mode_u = .clamp_to_edge,
                .address_mode_v = .clamp_to_edge,
                .address_mode_w = .clamp_to_edge,
                .mip_lod_bias = 0.0,
                .anisotropy_enable = vk.Bool32.false,
                .max_anisotropy = 1.0,
                .compare_enable = vk.Bool32.false,
                .compare_op = .always,
                .min_lod = 0.0,
                .max_lod = 1.0,
                .border_color = .float_transparent_black,
                .unnormalized_coordinates = vk.Bool32.false,
            };
            self.input_sampler = try core.vkd.createSampler(core.logical_device, &sampler_info, null);
        }
        errdefer if (self.input) |*tex| {
            core.vkd.destroySampler(core.logical_device, self.input_sampler, null);
            tex.deinit(core);
        };

        const has_input = self.input != null;
        const all_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };
        const binding_count: u32 = if (has_input) 3 else 2;
        const set_layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = binding_count,
            .p_bindings = &all_bindings,
        };
        self.descriptor_set_layout = try core.vkd.createDescriptorSetLayout(core.logical_device, &set_layout_info, null);
        errdefer core.vkd.destroyDescriptorSetLayout(core.logical_device, self.descriptor_set_layout, null);

        const layout_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };
        self.pipeline_layout = try core.vkd.createPipelineLayout(core.logical_device, &layout_info, null);
        errdefer core.vkd.destroyPipelineLayout(core.logical_device, self.pipeline_layout, null);

        const module_info = vk.ShaderModuleCreateInfo{
            .flags = .{},
            .code_size = spirv.len * @sizeOf(u32),
            .p_code = spirv.ptr,
        };
        const module = try core.vkd.createShaderModule(core.logical_device, &module_info, null);
        defer core.vkd.destroyShaderModule(core.logical_device, module, null);

        const pipeline_info = [_]vk.ComputePipelineCreateInfo{.{
            .flags = .{},
            .stage = .{ .flags = .{}, .stage = .{ .compute_bit = true }, .module = module, .p_name = "main", .p_specialization_info = null },
            .layout = self.pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }};
        var pipelines: [1]vk.Pipeline = undefined;
        _ = try core.vkd.createComputePipelines(core.logical_device, .null_handle, &pipeline_info, null, &pipelines);
        self.pipeline = pipelines[0];
        errdefer core.vkd.destroyPipeline(core.logical_device, self.pipeline, null);

        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .storage_image, .descriptor_count = MAX_FRAMES_IN_FLIGHT },
            .{ .type = .uniform_buffer, .descriptor_count = MAX_FRAMES_IN_FLIGHT },
            .{ .type = .combined_image_sampler, .descriptor_count = MAX_FRAMES_IN_FLIGHT },
        };
        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = MAX_FRAMES_IN_FLIGHT,
            .pool_size_count = if (has_input) pool_sizes.len else pool_sizes.len - 1,
            .p_pool_sizes = &pool_sizes,
        };
        self.descriptor_pool = try core.vkd.createDescriptorPool(core.logical_device, &pool_info, null);
        errdefer core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);

        var set_layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout = undefined;
        for (&set_layouts) |*l| l.* = self.descriptor_set_layout;
        const set_alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = MAX_FRAMES_IN_FLIGHT,
            .p_set_layouts = &set_layouts,
        };
        _ = try core.vkd.allocateDescriptorSets(core.logical_device, &set_alloc_info, &self.descriptor_sets);

        var created_buffers: usize = 0;
        errdefer for (self.ubo_buffers[0..created_buffers]) |*buf| buf.deinit(core);
        for (&self.ubo_buffers) |*buf| {
            buf.* = try Buffer.init(core, @sizeOf(Uniforms), .{ .uniform_buffer_bit = true }, c.VMA_MEMORY_USAGE_CPU_TO_GPU, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT));
            created_buffers += 1;
        }

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const image_descriptor = vk.DescriptorImageInfo{
                .sampler = .null_handle,
                .image_view = self.view,
                .image_layout = .general,
            };
            const buffer_descriptor = vk.DescriptorBufferInfo{
                .buffer = self.ubo_buffers[i].handle,
                .offset = 0,
                .range = @sizeOf(Uniforms),
            };
            const input_descriptor = vk.DescriptorImageInfo{
                .sampler = self.input_sampler,
                .image_view = if (self.input) |tex| tex.view else .null_handle,
                .image_layout = .shader_read_only_optimal,
            };
            const writes = [_]vk.WriteDescriptorSet{
                .{ .dst_set = self.descriptor_sets[i], .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_image, .p_image_info = @ptrCast(&image_descriptor), .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
                .{ .dst_set = self.descriptor_sets[i], .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .uniform_buffer, .p_buffer_info = @ptrCast(&buffer_descriptor), .p_image_info = undefined, .p_texel_buffer_view = undefined },
                .{ .dst_set = self.descriptor_sets[i], .dst_binding = 2, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .combined_image_sampler, .p_image_info = @ptrCast(&input_descriptor), .p_buffer_info = undefined, .p_texel_buffer_view = undefined },
            };
            core.vkd.updateDescriptorSets(core.logical_device, if (has_input) writes[0..3] else writes[0..2], null);
        }

        return self;
    }

    pub fn destroy(self: *ComputeBacking, allocator: std.mem.Allocator, core: *const Core, texture_registry: *TextureRegistry) void {
        if (self.input) |*tex| {
            core.vkd.destroySampler(core.logical_device, self.input_sampler, null);
            tex.deinit(core);
        }
        for (&self.ubo_buffers) |*buf| buf.deinit(core);
        core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);
        core.vkd.destroyPipeline(core.logical_device, self.pipeline, null);
        core.vkd.destroyPipelineLayout(core.logical_device, self.pipeline_layout, null);
        core.vkd.destroyDescriptorSetLayout(core.logical_device, self.descriptor_set_layout, null);
        texture_registry.releaseManagedView(self.tex_id);
        core.vkd.destroyImageView(core.logical_device, self.view, null);
        const handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.image))));
        c.vmaDestroyImage(core.vma_allocator, handle, self.allocation);
        allocator.destroy(self);
    }

    pub fn setParam(self: *ComputeBacking, index: usize, value: [4]f32) void {
        if (index >= MAX_USER_PARAMS) return;
        self.uniforms.user[index] = value;
    }

    pub fn record(self: *ComputeBacking, core: *const Core, cb: vk.CommandBuffer, frame_index: usize, time: f32, frame: u32) void {
        const vkd = core.vkd;

        self.uniforms.delta = @max(0.0, time - self.uniforms.time);
        self.uniforms.time = time;
        self.uniforms.frame = frame;
        const ptr = self.ubo_buffers[frame_index].mapped_ptr.?;
        @memcpy(ptr[0..@sizeOf(Uniforms)], std.mem.asBytes(&self.uniforms));

        const subresource = vk.ImageSubresourceRange{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };

        const src_access: vk.AccessFlags = if (self.layout == .shader_read_only_optimal) .{ .shader_read_bit = true } else .{};
        const src_stage: vk.PipelineStageFlags = if (self.layout == .shader_read_only_optimal) .{ .fragment_shader_bit = true } else .{ .top_of_pipe_bit = true };
        const to_general = vk.ImageMemoryBarrier{
            .src_access_mask = src_access,
            .dst_access_mask = .{ .shader_write_bit = true },
            .old_layout = self.layout,
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = subresource,
        };
        vkd.cmdPipelineBarrier(cb, src_stage, .{ .compute_shader_bit = true }, .{}, null, null, &[_]vk.ImageMemoryBarrier{to_general});

        vkd.cmdBindPipeline(cb, .compute, self.pipeline);
        vkd.cmdBindDescriptorSets(cb, .compute, self.pipeline_layout, 0, &[_]vk.DescriptorSet{self.descriptor_sets[frame_index]}, null);
        const groups_x = (self.width + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
        const groups_y = (self.height + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
        vkd.cmdDispatch(cb, groups_x, groups_y, 1);

        const to_read = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = subresource,
        };
        vkd.cmdPipelineBarrier(cb, .{ .compute_shader_bit = true }, .{ .fragment_shader_bit = true }, .{}, null, null, &[_]vk.ImageMemoryBarrier{to_read});

        self.layout = .shader_read_only_optimal;
    }
};
