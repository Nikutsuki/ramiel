const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const tracy = @import("tracy");

pub const RenderTexture = struct {
    image: vk.Image,
    allocation: c.VmaAllocation,
    view: vk.ImageView,
    sampler: vk.Sampler,
    format: vk.Format,
    extent: vk.Extent2D,

    pub fn init(
        core: *Core,
        extent: vk.Extent2D,
        format: vk.Format,
        samples: vk.SampleCountFlags,
        sampled: bool,
    ) !RenderTexture {
        var usage: vk.ImageUsageFlags = .{
            .color_attachment_bit = true,
            .transfer_src_bit = true,
            .transfer_dst_bit = true,
        };
        if (sampled) usage.sampled_bit = true;
        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = samples,
            .tiling = .optimal,
            .usage = usage,
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

        var image: vk.Image = undefined;
        var allocation: c.VmaAllocation = undefined;
        var allocation_info: c.VmaAllocationInfo = undefined;

        if (c.vmaCreateImage(core.vma_allocator, @ptrCast(&image_info), &alloc_info, @ptrCast(&image), &allocation, &allocation_info) != c.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }

        tracy.alloc(.{
            .ptr = @ptrCast(allocation),
            .size = @intCast(@min(allocation_info.size, @as(vk.DeviceSize, std.math.maxInt(usize)))),
        });

        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const view = try core.vkd.createImageView(core.logical_device, &view_info, null);

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

        const sampler = try core.vkd.createSampler(core.logical_device, &sampler_info, null);

        return RenderTexture{
            .image = image,
            .allocation = allocation,
            .view = view,
            .sampler = sampler,
            .format = format,
            .extent = extent,
        };
    }

    pub fn deinit(self: *RenderTexture, core: *Core) void {
        core.vkd.destroySampler(core.logical_device, self.sampler, null);
        core.vkd.destroyImageView(core.logical_device, self.view, null);
        tracy.free(.{ .ptr = @ptrCast(self.allocation) });
        const c_image_handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.image))));
        c.vmaDestroyImage(core.vma_allocator, c_image_handle, self.allocation);
    }
};
