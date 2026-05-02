const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const Swapchain = @import("swapchain.zig").Swapchain;
const FrameData = @import("frame.zig").FrameData;

pub const MAX_FRAMES_IN_FLIGHT = 2;

pub const FrameManager = struct {
    frames: [MAX_FRAMES_IN_FLIGHT]FrameData,
    render_finished_semaphores: []vk.Semaphore,
    current_frame_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, core: *Core, swapchain: *const Swapchain) !FrameManager {
        var frames: [MAX_FRAMES_IN_FLIGHT]FrameData = undefined;
        for (&frames) |*frame| {
            frame.* = try FrameData.init(core);
        }

        const render_finished_semaphores = try allocator.alloc(vk.Semaphore, swapchain.image_views.len);
        errdefer allocator.free(render_finished_semaphores);

        for (render_finished_semaphores) |*sem| {
            sem.* = try core.vkd.createSemaphore(core.logical_device, &.{ .flags = .{} }, null);
        }

        return FrameManager{
            .frames = frames,
            .render_finished_semaphores = render_finished_semaphores,
        };
    }

    pub fn deinit(self: *FrameManager, allocator: std.mem.Allocator, core: *Core) void {
        for (&self.frames) |*frame| {
            frame.deinit(core);
        }
        for (self.render_finished_semaphores) |sem| {
            core.vkd.destroySemaphore(core.logical_device, sem, null);
        }
        allocator.free(self.render_finished_semaphores);
    }

    pub fn beginFrame(self: *FrameManager, swapchain: vk.SwapchainKHR, core: *Core) !FrameContext {
        const vkd = core.vkd;
        const dev = core.logical_device;
        const frame = &self.frames[self.current_frame_index];

        _ = try vkd.waitForFences(dev, &[_]vk.Fence{frame.in_flight_fence}, vk.Bool32.true, std.math.maxInt(u64));

        const result = vkd.acquireNextImageKHR(
            dev,
            swapchain,
            std.math.maxInt(u64),
            frame.image_available_semaphore,
            .null_handle,
        ) catch |err| return err;

        if (result.result == .suboptimal_khr) {
            return error.SuboptimalKHR;
        }

        try vkd.resetFences(dev, &[_]vk.Fence{frame.in_flight_fence});

        const cb = frame.command_buffer;
        try vkd.resetCommandBuffer(cb, .{});
        try vkd.beginCommandBuffer(cb, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        return FrameContext{
            .command_buffer = cb,
            .image_index = result.image_index,
            .frame_index = self.current_frame_index,
        };
    }

    pub fn beginFrameNoPresent(self: *FrameManager, core: *Core) !FrameContext {
        const vkd = core.vkd;
        const dev = core.logical_device;
        const frame = &self.frames[self.current_frame_index];

        _ = try vkd.waitForFences(dev, &[_]vk.Fence{frame.in_flight_fence}, vk.Bool32.true, std.math.maxInt(u64));
        try vkd.resetFences(dev, &[_]vk.Fence{frame.in_flight_fence});

        const cb = frame.command_buffer;
        try vkd.resetCommandBuffer(cb, .{});
        try vkd.beginCommandBuffer(cb, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        return FrameContext{
            .command_buffer = cb,
            .image_index = 0,
            .frame_index = self.current_frame_index,
        };
    }

    pub fn endFrame(self: *FrameManager, ctx: FrameContext, swapchain: vk.SwapchainKHR, core: *Core) !void {
        const vkd = core.vkd;
        const frame = &self.frames[ctx.frame_index];
        const render_finished = self.render_finished_semaphores[ctx.image_index];

        const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        const command_buffers = [1]vk.CommandBuffer{ctx.command_buffer};

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.image_available_semaphore),
            .p_wait_dst_stage_mask = &wait_stages,
            .command_buffer_count = 1,
            .p_command_buffers = &command_buffers,
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&render_finished),
        };

        try vkd.queueSubmit(core.graphics_queue, &[_]vk.SubmitInfo{submit_info}, frame.in_flight_fence);

        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain),
            .p_image_indices = @ptrCast(&ctx.image_index),
            .p_results = null,
        };

        const present_result = try vkd.queuePresentKHR(core.present_queue, &present_info);
        if (present_result == .suboptimal_khr) {
            return error.SuboptimalKHR;
        }

        self.current_frame_index = (self.current_frame_index + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn endFrameNoPresent(self: *FrameManager, ctx: FrameContext, core: *Core) !void {
        const vkd = core.vkd;
        const frame = &self.frames[ctx.frame_index];

        const command_buffers = [1]vk.CommandBuffer{ctx.command_buffer};

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = &command_buffers,
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };

        try vkd.queueSubmit(core.graphics_queue, &[_]vk.SubmitInfo{submit_info}, frame.in_flight_fence);
        _ = try vkd.waitForFences(core.logical_device, &[_]vk.Fence{frame.in_flight_fence}, vk.Bool32.true, std.math.maxInt(u64));

        self.current_frame_index = (self.current_frame_index + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    pub fn resize(self: *FrameManager, allocator: std.mem.Allocator, new_swapchain_len: usize, core: *Core) !void {
        for (self.render_finished_semaphores) |sem| {
            core.vkd.destroySemaphore(core.logical_device, sem, null);
        }
        allocator.free(self.render_finished_semaphores);

        self.render_finished_semaphores = try allocator.alloc(vk.Semaphore, new_swapchain_len);
        for (self.render_finished_semaphores) |*sem| {
            sem.* = try core.vkd.createSemaphore(core.logical_device, &.{ .flags = .{} }, null);
        }
    }

    pub fn currentFrame(self: *const FrameManager) *const FrameData {
        return &self.frames[self.current_frame_index];
    }
};

pub const FrameContext = struct {
    command_buffer: vk.CommandBuffer,
    image_index: u32,
    frame_index: usize,
};
