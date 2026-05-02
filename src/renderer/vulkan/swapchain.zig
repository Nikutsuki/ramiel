const std = @import("std");

const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;

fn compositeAlphaName(mode: vk.CompositeAlphaFlagsKHR) []const u8 {
    if (mode.inherit_bit_khr) return "inherit";
    if (mode.pre_multiplied_bit_khr) return "pre_multiplied";
    if (mode.post_multiplied_bit_khr) return "post_multiplied";
    if (mode.opaque_bit_khr) return "opaque";
    return "unknown";
}

pub const Swapchain = struct {
    handle: vk.SwapchainKHR,
    format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    images: []vk.Image,
    image_views: []vk.ImageView,
    transparent: bool,
    has_alpha_compositing: bool,

    pub fn init(core: *Core, old_handle: vk.SwapchainKHR, transparent: bool, fallback_extent: vk.Extent2D) !Swapchain {
        const caps = try core.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(core.physical_device, core.surface);
        const extent = if (caps.current_extent.width != 0xFFFF_FFFF) caps.current_extent else blk: {
            // Wayland reports 0xFFFFFFFF current_extent: caller picks within min..max.
            const min = caps.min_image_extent;
            const max = caps.max_image_extent;
            const clamp_w = @min(@max(fallback_extent.width, min.width), max.width);
            const clamp_h = @min(@max(fallback_extent.height, min.height), max.height);
            break :blk vk.Extent2D{ .width = clamp_w, .height = clamp_h };
        };

        const present_mode: vk.PresentModeKHR = blk: {
            const supported = core.vki.getPhysicalDeviceSurfacePresentModesAllocKHR(
                core.physical_device,
                core.surface,
                core.allocator,
            ) catch break :blk .fifo_khr;
            defer core.allocator.free(supported);

            var has_mailbox = false;
            var has_immediate = false;
            for (supported) |m| {
                if (m == .mailbox_khr) has_mailbox = true;
                if (m == .immediate_khr) has_immediate = true;
            }
            if (has_mailbox) break :blk .mailbox_khr;
            if (has_immediate) break :blk .immediate_khr;
            break :blk .fifo_khr;
        };
        std.log.info("swapchain present mode selected: {s}", .{@tagName(present_mode)});

        const composite_alpha: vk.CompositeAlphaFlagsKHR = blk: {
            if (transparent) {
                const a = caps.supported_composite_alpha;
                if (a.inherit_bit_khr) break :blk .{ .inherit_bit_khr = true };
                if (a.pre_multiplied_bit_khr) break :blk .{ .pre_multiplied_bit_khr = true };
                if (a.post_multiplied_bit_khr) break :blk .{ .post_multiplied_bit_khr = true };
            }
            break :blk .{ .opaque_bit_khr = true };
        };

        const supported_alpha = caps.supported_composite_alpha;
        std.log.info(
            "swapchain alpha support: opaque={} pre_multiplied={} post_multiplied={} inherit={} transparent_requested={}",
            .{
                supported_alpha.opaque_bit_khr,
                supported_alpha.pre_multiplied_bit_khr,
                supported_alpha.post_multiplied_bit_khr,
                supported_alpha.inherit_bit_khr,
                transparent,
            },
        );
        std.log.info("swapchain composite alpha selected: {s}", .{compositeAlphaName(composite_alpha)});

        if (transparent and
            !supported_alpha.inherit_bit_khr and
            !supported_alpha.pre_multiplied_bit_khr and
            !supported_alpha.post_multiplied_bit_khr)
        {
            std.log.warn(
                "transparent window requested, but surface supports only opaque composite alpha; desktop passthrough will appear black",
                .{},
            );
        }

        const create_info = vk.SwapchainCreateInfoKHR{
            .flags = .{},
            .surface = core.surface,
            .min_image_count = caps.min_image_count + 1,
            .image_format = .b8g8r8a8_unorm,
            .image_color_space = .srgb_nonlinear_khr,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = composite_alpha,
            .present_mode = present_mode,
            .clipped = vk.Bool32.true,
            .old_swapchain = old_handle,
        };

        const handle = try core.vkd.createSwapchainKHR(core.logical_device, &create_info, null);

        var count: u32 = 0;
        _ = try core.vkd.getSwapchainImagesKHR(core.logical_device, handle, &count, null);
        const images = try core.allocator.alloc(vk.Image, count);
        errdefer core.allocator.free(images);

        _ = try core.vkd.getSwapchainImagesKHR(core.logical_device, handle, &count, images.ptr);

        const image_views = try core.allocator.alloc(vk.ImageView, count);
        errdefer core.allocator.free(image_views);

        for (images, 0..) |img, i| {
            const view_info = vk.ImageViewCreateInfo{
                .flags = .{},
                .image = img,
                .view_type = .@"2d",
                .format = .b8g8r8a8_unorm,
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

            image_views[i] = try core.vkd.createImageView(core.logical_device, &view_info, null);
        }

        return Swapchain{
            .handle = handle,
            .format = .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear_khr },
            .extent = extent,
            .images = images,
            .image_views = image_views,
            .transparent = transparent,
            .has_alpha_compositing = !composite_alpha.opaque_bit_khr,
        };
    }

    pub fn recreate(self: *Swapchain, core: *Core, fallback_extent: vk.Extent2D) !void {
        try core.vkd.deviceWaitIdle(core.logical_device);

        const old_handle = self.handle;
        const new_swapchain = try Swapchain.init(core, old_handle, self.transparent, fallback_extent);

        for (self.image_views) |view| {
            core.vkd.destroyImageView(core.logical_device, view, null);
        }

        core.vkd.destroySwapchainKHR(core.logical_device, old_handle, null);
        core.allocator.free(self.images);
        core.allocator.free(self.image_views);

        self.* = new_swapchain;
    }

    pub fn deinit(self: *Swapchain, core: *Core) void {
        for (self.image_views) |view| {
            core.vkd.destroyImageView(core.logical_device, view, null);
        }

        core.allocator.free(self.images);
        core.allocator.free(self.image_views);

        core.vkd.destroySwapchainKHR(core.logical_device, self.handle, null);
    }
};
