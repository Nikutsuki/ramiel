const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const DynamicTexture = @import("dynamic_texture.zig").DynamicTexture;
const TextureRegistry = @import("texture_registry.zig").TextureRegistry;

pub const YuvTexture = struct {
    y_plane: *DynamicTexture,
    u_plane: *DynamicTexture,
    v_plane: *DynamicTexture,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    sampler: vk.Sampler,

    pub fn createDescriptorSetLayout(core: *const Core) !vk.DescriptorSetLayout {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        const bindings = [_]vk.DescriptorSetLayoutBinding{
            binding,
            .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        };

        const layout_info = vk.DescriptorSetLayoutCreateInfo{
            .flags = .{},
            .binding_count = bindings.len,
            .p_bindings = @ptrCast(&bindings),
        };

        return try core.vkd.createDescriptorSetLayout(core.logical_device, &layout_info, null);
    }

    pub fn create(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        descriptor_set_layout: vk.DescriptorSetLayout,
        width: u32,
        height: u32,
        frame_slots: usize,
    ) !*YuvTexture {
        if (width == 0 or height == 0) return error.InvalidTextureSize;
        if ((width & 1) != 0 or (height & 1) != 0) return error.InvalidYuvDimensions;

        const self = try allocator.create(YuvTexture);
        errdefer allocator.destroy(self);

        self.y_plane = try DynamicTexture.createWithFormat(
            allocator,
            core,
            texture_registry,
            width,
            height,
            frame_slots,
            .r8_unorm,
        );
        errdefer self.y_plane.destroy(allocator, core, texture_registry);

        self.u_plane = try DynamicTexture.createWithFormat(
            allocator,
            core,
            texture_registry,
            width / 2,
            height / 2,
            frame_slots,
            .r8_unorm,
        );
        errdefer self.u_plane.destroy(allocator, core, texture_registry);

        self.v_plane = try DynamicTexture.createWithFormat(
            allocator,
            core,
            texture_registry,
            width / 2,
            height / 2,
            frame_slots,
            .r8_unorm,
        );
        errdefer self.v_plane.destroy(allocator, core, texture_registry);

        const sampler_info = vk.SamplerCreateInfo{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .anisotropy_enable = vk.Bool32.false,
            .max_anisotropy = 1.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vk.Bool32.false,
            .compare_enable = vk.Bool32.false,
            .compare_op = .always,
            .mipmap_mode = .linear,
            .mip_lod_bias = 0.0,
            .min_lod = 0.0,
            .max_lod = 0.0,
        };
        self.sampler = try core.vkd.createSampler(core.logical_device, &sampler_info, null);
        errdefer core.vkd.destroySampler(core.logical_device, self.sampler, null);

        const pool_sizes = [_]vk.DescriptorPoolSize{.{
            .type = .combined_image_sampler,
            .descriptor_count = 3,
        }};

        const pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @ptrCast(&pool_sizes),
        };
        self.descriptor_pool = try core.vkd.createDescriptorPool(core.logical_device, &pool_info, null);
        errdefer core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);

        const set_layouts = [_]vk.DescriptorSetLayout{descriptor_set_layout};
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &set_layouts,
        };

        var descriptor_sets: [1]vk.DescriptorSet = undefined;
        _ = try core.vkd.allocateDescriptorSets(core.logical_device, &alloc_info, @ptrCast(&descriptor_sets));
        self.descriptor_set = descriptor_sets[0];

        const image_infos = [_]vk.DescriptorImageInfo{
            .{ .image_layout = .shader_read_only_optimal, .image_view = self.y_plane.view, .sampler = self.sampler },
            .{ .image_layout = .shader_read_only_optimal, .image_view = self.u_plane.view, .sampler = self.sampler },
            .{ .image_layout = .shader_read_only_optimal, .image_view = self.v_plane.view, .sampler = self.sampler },
        };

        var writes: [3]vk.WriteDescriptorSet = undefined;
        for (0..writes.len) |i| {
            writes[i] = .{
                .dst_set = self.descriptor_set,
                .dst_binding = @intCast(i),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = @ptrCast(&image_infos[i]),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        }

        core.vkd.updateDescriptorSets(core.logical_device, writes[0..], null);

        return self;
    }

    pub fn destroy(
        self: *YuvTexture,
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
    ) void {
        self.y_plane.destroy(allocator, core, texture_registry);
        self.u_plane.destroy(allocator, core, texture_registry);
        self.v_plane.destroy(allocator, core, texture_registry);
        core.vkd.destroyDescriptorPool(core.logical_device, self.descriptor_pool, null);
        core.vkd.destroySampler(core.logical_device, self.sampler, null);
        allocator.destroy(self);
    }

    pub fn upload(
        self: *YuvTexture,
        frame_index: usize,
        yuv_data: []const u8,
        y_size: usize,
        u_size: usize,
    ) !void {
        if (y_size + u_size >= yuv_data.len) return error.InvalidYuvBufferSize;

        try self.y_plane.copyShadowToStaging(frame_index, yuv_data[0..y_size]);
        try self.u_plane.copyShadowToStaging(frame_index, yuv_data[y_size .. y_size + u_size]);
        try self.v_plane.copyShadowToStaging(frame_index, yuv_data[y_size + u_size ..]);
    }

    pub fn recordUpload(self: *const YuvTexture, frame_index: usize, vkd: vk.DeviceWrapper, cb: vk.CommandBuffer) void {
        self.y_plane.recordUpload(frame_index, vkd, cb);
        self.u_plane.recordUpload(frame_index, vkd, cb);
        self.v_plane.recordUpload(frame_index, vkd, cb);
    }
};
