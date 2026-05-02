const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("core.zig").Core;
const tracy = @import("tracy");

const vk_common = @import("vk_common.zig");
const c = vk_common.c;

pub const Buffer = struct {
    handle: vk.Buffer,
    allocation: c.VmaAllocation,
    size: vk.DeviceSize,
    mapped_ptr: ?[*]u8 = null,

    pub fn init(
        core: *const Core,
        size: vk.DeviceSize,
        usage: vk.BufferUsageFlags,
        memory_usage: c.VmaMemoryUsage,
        alloc_flags: c.VmaAllocationCreateFlags,
    ) !Buffer {
        const buffer_info = vk.BufferCreateInfo{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .flags = .{},
            .p_next = null,
        };

        const alloc_info = c.VmaAllocationCreateInfo{
            .usage = memory_usage,
            .flags = alloc_flags,
            .memoryTypeBits = 0,
            .requiredFlags = 0,
            .preferredFlags = 0,
            .pool = null,
            .priority = 0.0,
            .pUserData = null,
        };

        var buffer: vk.Buffer = .null_handle;
        var allocation: c.VmaAllocation = undefined;
        var allocation_info: c.VmaAllocationInfo = undefined;

        if (c.vmaCreateBuffer(core.vma_allocator, @ptrCast(&buffer_info), &alloc_info, @ptrCast(&buffer), &allocation, &allocation_info) != c.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }

        tracy.alloc(.{
            .ptr = @ptrCast(allocation),
            .size = @intCast(@min(allocation_info.size, @as(vk.DeviceSize, std.math.maxInt(usize)))),
        });

        const mapped_ptr: ?[*]u8 = if ((alloc_flags & @as(u32, @intCast(c.VMA_ALLOCATION_CREATE_MAPPED_BIT))) != 0)
            @ptrCast(allocation_info.pMappedData)
        else
            null;

        return Buffer{
            .handle = buffer,
            .allocation = allocation,
            .size = size,
            .mapped_ptr = mapped_ptr,
        };
    }

    pub fn deinit(self: *Buffer, core: *const Core) void {
        tracy.free(.{ .ptr = @ptrCast(self.allocation) });
        const c_buffer_handle: c.VkBuffer = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(self.handle))));
        c.vmaDestroyBuffer(core.vma_allocator, c_buffer_handle, self.allocation);
    }
};
