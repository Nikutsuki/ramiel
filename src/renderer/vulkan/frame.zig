const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;

pub const FrameData = struct {
    command_buffer: vk.CommandBuffer,
    image_available_semaphore: vk.Semaphore,
    in_flight_fence: vk.Fence,

    pub fn init(core: *Core) !FrameData {
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = core.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var buffer: [1]vk.CommandBuffer = undefined;
        _ = try core.vkd.allocateCommandBuffers(core.logical_device, &alloc_info, &buffer);

        const image_available = try core.vkd.createSemaphore(core.logical_device, &.{ .flags = .{} }, null);
        const in_flight = try core.vkd.createFence(core.logical_device, &.{ .flags = .{ .signaled_bit = true } }, null);

        return FrameData{
            .command_buffer = buffer[0],
            .image_available_semaphore = image_available,
            .in_flight_fence = in_flight,
        };
    }

    pub fn deinit(self: *FrameData, core: *Core) void {
        const vkd = core.vkd;
        const dev = core.logical_device;

        vkd.destroyFence(dev, self.in_flight_fence, null);
        vkd.destroySemaphore(dev, self.image_available_semaphore, null);

        const buffers = [1]vk.CommandBuffer{self.command_buffer};
        vkd.freeCommandBuffers(dev, core.command_pool, @ptrCast(&buffers));
    }
};
