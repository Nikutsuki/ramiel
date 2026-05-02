const std = @import("std");
const vk = @import("../../vk.zig");
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const Core = @import("core.zig").Core;
const Buffer = @import("buffer.zig").Buffer;
const tracy = @import("tracy");

pub const Texture = struct {
    image: vk.Image,
    allocation: c.VmaAllocation,
    view: vk.ImageView,
    width: u32,
    height: u32,

    pub fn init(core: *const Core, width: u32, height: u32, pixels: []const u8) !Texture {
        const image_size = width * height * 4;

        var staging_buffer = try Buffer.init(core, image_size, .{ .transfer_src_bit = true }, c.VMA_MEMORY_USAGE_CPU_ONLY, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT));
        defer staging_buffer.deinit(core);

        @memcpy(staging_buffer.mapped_ptr.?[0..image_size], pixels);

        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = vk.Extent3D{
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .initial_layout = .undefined,
        };

        const alloc_info = c.VmaAllocationCreateInfo{
            .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = 0,
            .preferredFlags = 0,
            .memoryTypeBits = 0,
            .pool = null,
            .pUserData = null,
            .priority = 0,
            .flags = 0,
        };

        var image: vk.Image = .null_handle;
        var allocation: c.VmaAllocation = undefined;
        var allocation_info: c.VmaAllocationInfo = undefined;

        if (c.vmaCreateImage(core.vma_allocator, @ptrCast(&image_info), &alloc_info, @ptrCast(&image), &allocation, &allocation_info) != c.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }

        tracy.alloc(.{
            .ptr = @ptrCast(allocation),
            .size = @intCast(@min(allocation_info.size, @as(vk.DeviceSize, std.math.maxInt(usize)))),
        });

        try core.transitionImageLayout(image, .undefined, .transfer_dst_optimal);
        try core.copyBufferToImage(staging_buffer.handle, image, width, height);
        try core.transitionImageLayout(image, .transfer_dst_optimal, .shader_read_only_optimal);

        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = vk.ImageSubresourceRange{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const view = try core.vkd.createImageView(core.logical_device, &view_info, null);

        return Texture{
            .image = image,
            .allocation = allocation,
            .view = view,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Texture, core: *const Core) void {
        core.vkd.destroyImageView(core.logical_device, self.view, null);
        tracy.free(.{ .ptr = @ptrCast(self.allocation) });
        const c_image_handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.image))));
        c.vmaDestroyImage(core.vma_allocator, c_image_handle, self.allocation);
    }
};
