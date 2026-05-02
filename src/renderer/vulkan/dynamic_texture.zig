const std = @import("std");
const vk = @import("../../vk.zig");
const vk_common = @import("vk_common.zig");
const c = vk_common.c;
const Core = @import("core.zig").Core;
const Buffer = @import("buffer.zig").Buffer;
const TextureRegistry = @import("texture_registry.zig").TextureRegistry;

pub const DynamicTexture = struct {
    image: vk.Image,
    allocation: c.VmaAllocation,
    view: vk.ImageView,
    staging_buffers: []Buffer,
    tex_id: u32,
    format: vk.Format,
    bytes_per_pixel: usize,
    width: u32,
    height: u32,

    pub fn create(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        frame_slots: usize,
    ) !*DynamicTexture {
        return createWithFormat(
            allocator,
            core,
            texture_registry,
            width,
            height,
            frame_slots,
            .r8g8b8a8_unorm,
        );
    }

    pub fn createWithFormat(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        frame_slots: usize,
        format: vk.Format,
    ) !*DynamicTexture {
        if (width == 0 or height == 0) return error.InvalidTextureSize;
        if (frame_slots == 0) return error.InvalidFrameSlotCount;
        const bytes_per_pixel = bytesPerPixel(format) orelse return error.UnsupportedTextureFormat;

        const self = try allocator.create(DynamicTexture);
        errdefer allocator.destroy(self);

        const pixel_count = try std.math.mul(usize, @as(usize, width), @as(usize, height));
        const byte_len = try std.math.mul(usize, pixel_count, bytes_per_pixel);

        self.staging_buffers = try allocator.alloc(Buffer, frame_slots);
        errdefer allocator.free(self.staging_buffers);

        var initialized_buffers: usize = 0;
        errdefer {
            for (self.staging_buffers[0..initialized_buffers]) |*buf| {
                buf.deinit(core);
            }
        }

        for (self.staging_buffers) |*buf| {
            buf.* = try Buffer.init(
                core,
                @intCast(byte_len),
                .{ .transfer_src_bit = true },
                c.VMA_MEMORY_USAGE_CPU_ONLY,
                @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT),
            );
            initialized_buffers += 1;
        }

        const image_info = vk.ImageCreateInfo{
            .flags = .{},
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
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
            .flags = 0,
            .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = @intCast(c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
            .preferredFlags = 0,
            .memoryTypeBits = 0,
            .pool = null,
            .pUserData = null,
            .priority = 0.0,
        };

        if (c.vmaCreateImage(
            core.vma_allocator,
            @ptrCast(&image_info),
            &alloc_info,
            @ptrCast(&self.image),
            &self.allocation,
            null,
        ) != c.VK_SUCCESS) {
            return error.ImageCreationFailed;
        }
        errdefer {
            const c_image_handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.image))));
            c.vmaDestroyImage(core.vma_allocator, c_image_handle, self.allocation);
        }

        const view_info = vk.ImageViewCreateInfo{
            .flags = .{},
            .image = self.image,
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

        self.view = try core.vkd.createImageView(core.logical_device, &view_info, null);
        errdefer core.vkd.destroyImageView(core.logical_device, self.view, null);

        try core.transitionImageLayout(self.image, .undefined, .shader_read_only_optimal);

        self.tex_id = try texture_registry.registerManagedView(core, self.view);

        self.format = format;
        self.bytes_per_pixel = bytes_per_pixel;
        self.width = width;
        self.height = height;

        return self;
    }

    pub fn destroy(
        self: *DynamicTexture,
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
    ) void {
        texture_registry.releaseManagedView(self.tex_id);
        core.vkd.destroyImageView(core.logical_device, self.view, null);
        for (self.staging_buffers) |*buf| {
            buf.deinit(core);
        }
        allocator.free(self.staging_buffers);
        const c_image_handle: c.VkImage = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.image))));
        c.vmaDestroyImage(core.vma_allocator, c_image_handle, self.allocation);
        allocator.destroy(self);
    }

    pub fn byteLen(self: *const DynamicTexture) usize {
        return @as(usize, self.width) * @as(usize, self.height) * self.bytes_per_pixel;
    }

    pub fn copyShadowToStaging(self: *DynamicTexture, frame_index: usize, pixels: []const u8) !void {
        const bytes = self.byteLen();
        if (pixels.len != bytes) return error.InvalidCanvasPixelData;

        const staging = &self.staging_buffers[frame_index % self.staging_buffers.len];
        const mapped = staging.mapped_ptr orelse return error.StagingBufferNotMapped;
        @memcpy(mapped[0..bytes], pixels);
    }

    pub fn recordUpload(self: *const DynamicTexture, frame_index: usize, vkd: vk.DeviceWrapper, cb: vk.CommandBuffer) void {
        const staging = self.staging_buffers[frame_index % self.staging_buffers.len];

        const to_transfer = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .shader_read_only_optimal,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        vkd.cmdPipelineBarrier(
            cb,
            .{ .fragment_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            null,
            null,
            &[_]vk.ImageMemoryBarrier{to_transfer},
        );

        const copy_region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = self.width, .height = self.height, .depth = 1 },
        };
        vkd.cmdCopyBufferToImage(
            cb,
            staging.handle,
            self.image,
            .transfer_dst_optimal,
            &[_]vk.BufferImageCopy{copy_region},
        );

        const to_shader_read = vk.ImageMemoryBarrier{
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        vkd.cmdPipelineBarrier(
            cb,
            .{ .transfer_bit = true },
            .{ .fragment_shader_bit = true },
            .{},
            null,
            null,
            &[_]vk.ImageMemoryBarrier{to_shader_read},
        );
    }
};

fn bytesPerPixel(format: vk.Format) ?usize {
    return switch (format) {
        .r8_unorm => 1,
        .r8g8b8a8_unorm => 4,
        else => null,
    };
}
