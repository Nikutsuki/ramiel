const std = @import("std");
const vk = @import("../../vk.zig");
const RenderSurface = @import("surface.zig").RenderSurface;

const vk_common = @import("vk_common.zig");
const c = vk_common.c;

pub const DeviceCandidate = struct {
    physical_device: vk.PhysicalDevice,
    graphics_family: u32,
    present_family: u32,
};

const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

const builtin = @import("builtin");
const enable_validation_layers = builtin.mode == .Debug;

pub const Core = struct {
    allocator: std.mem.Allocator,

    vkb: vk.BaseWrapper,

    instance: vk.Instance,
    vki: vk.InstanceWrapper,
    surface: vk.SurfaceKHR,
    surface_provider: RenderSurface,

    physical_device: vk.PhysicalDevice,
    logical_device: vk.Device,
    vkd: vk.DeviceWrapper,

    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    command_pool: vk.CommandPool,

    vma_allocator: c.VmaAllocator,

    pub fn init(allocator: std.mem.Allocator, surface_provider: RenderSurface) !Core {
        const vkb = vk.BaseWrapper.load(surface_provider.get_instance_proc_address);

        const appInfo = vk.ApplicationInfo{
            .p_application_name = "Ramiel",
            .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
            .api_version = vk.API_VERSION_1_2.toU32(),
        };

        const required_extensions = try surface_provider.requiredExtensions();

        if (enable_validation_layers and !try checkValidationLayerSupport(vkb, allocator)) {
            return error.ValidationLayersUnavailable;
        }

        var vk12_features = vk.PhysicalDeviceVulkan12Features{
            .descriptor_binding_partially_bound = vk.Bool32.true,
            .descriptor_binding_variable_descriptor_count = vk.Bool32.true,
            .descriptor_binding_sampled_image_update_after_bind = vk.Bool32.true,
            .runtime_descriptor_array = vk.Bool32.true,
            .shader_sampled_image_array_non_uniform_indexing = vk.Bool32.true,
        };

        const create_info = vk.InstanceCreateInfo{
            .p_next = null,
            .flags = .{},
            .p_application_info = &appInfo,
            .enabled_layer_count = if (enable_validation_layers) validation_layers.len else 0,
            .pp_enabled_layer_names = if (enable_validation_layers) &validation_layers else null,
            .enabled_extension_count = required_extensions.count,
            .pp_enabled_extension_names = required_extensions.names,
        };

        const instance = try vkb.createInstance(&create_info, null);

        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);

        const surface = try surface_provider.createSurface(instance, &vki);

        const candidate = try pickPhysicalDevice(allocator, vki, instance, surface);

        const props = vki.getPhysicalDeviceProperties(candidate.physical_device);
        std.log.debug("{s}", .{props.device_name});

        const priority = [_]f32{1.0};

        var q_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        var q_count: u32 = 0;

        q_infos[0] = .{
            .flags = .{},
            .queue_family_index = candidate.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        };
        q_count += 1;

        if (candidate.graphics_family != candidate.present_family) {
            q_infos[1] = .{
                .flags = .{},
                .queue_family_index = candidate.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            };
            q_count += 1;
        }

        const device_extensions = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name,
        };

        const device_create_info = vk.DeviceCreateInfo{
            .p_next = @ptrCast(&vk12_features),
            .flags = .{},
            .queue_create_info_count = q_count,
            .p_queue_create_infos = &q_infos,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .p_enabled_features = null,
        };

        const dev_handle = try vki.createDevice(candidate.physical_device, &device_create_info, null);
        const vkd = vk.DeviceWrapper.load(dev_handle, vki.dispatch.vkGetDeviceProcAddr.?);

        const graphics_queue = vkd.getDeviceQueue(dev_handle, candidate.graphics_family, 0);
        const present_queue = vkd.getDeviceQueue(dev_handle, candidate.present_family, 0);

        const pool_info = vk.CommandPoolCreateInfo{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = candidate.graphics_family,
        };

        const pool = try vkd.createCommandPool(dev_handle, &pool_info, null);

        const vma_allocator = try initVMA(vki, vkd, vkb, candidate.physical_device, dev_handle, instance);

        return Core{
            .allocator = allocator,

            .vkb = vkb,

            .instance = instance,
            .vki = vki,
            .surface = surface,
            .surface_provider = surface_provider,
            .physical_device = candidate.physical_device,
            .logical_device = dev_handle,
            .vkd = vkd,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .command_pool = pool,

            .vma_allocator = vma_allocator,
        };
    }

    fn initVMA(vki: vk.InstanceWrapper, vkd: vk.DeviceWrapper, vkb: vk.BaseWrapper, physical_device: vk.PhysicalDevice, logical_device: vk.Device, instance: vk.Instance) !c.VmaAllocator {
        const vma_vulkan_functions = c.VmaVulkanFunctions{
            .vkGetInstanceProcAddr = @ptrCast(vkb.dispatch.vkGetInstanceProcAddr),

            .vkGetDeviceProcAddr = @ptrCast(vki.dispatch.vkGetDeviceProcAddr),
            .vkGetPhysicalDeviceProperties = @ptrCast(vki.dispatch.vkGetPhysicalDeviceProperties),
            .vkGetPhysicalDeviceMemoryProperties = @ptrCast(vki.dispatch.vkGetPhysicalDeviceMemoryProperties),
            .vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(vki.dispatch.vkGetPhysicalDeviceMemoryProperties2),

            .vkAllocateMemory = @ptrCast(vkd.dispatch.vkAllocateMemory),
            .vkFreeMemory = @ptrCast(vkd.dispatch.vkFreeMemory),
            .vkMapMemory = @ptrCast(vkd.dispatch.vkMapMemory),
            .vkUnmapMemory = @ptrCast(vkd.dispatch.vkUnmapMemory),
            .vkFlushMappedMemoryRanges = @ptrCast(vkd.dispatch.vkFlushMappedMemoryRanges),
            .vkInvalidateMappedMemoryRanges = @ptrCast(vkd.dispatch.vkInvalidateMappedMemoryRanges),
            .vkBindBufferMemory = @ptrCast(vkd.dispatch.vkBindBufferMemory),
            .vkBindImageMemory = @ptrCast(vkd.dispatch.vkBindImageMemory),
            .vkGetBufferMemoryRequirements = @ptrCast(vkd.dispatch.vkGetBufferMemoryRequirements),
            .vkGetImageMemoryRequirements = @ptrCast(vkd.dispatch.vkGetImageMemoryRequirements),
            .vkCreateBuffer = @ptrCast(vkd.dispatch.vkCreateBuffer),
            .vkDestroyBuffer = @ptrCast(vkd.dispatch.vkDestroyBuffer),
            .vkCreateImage = @ptrCast(vkd.dispatch.vkCreateImage),
            .vkDestroyImage = @ptrCast(vkd.dispatch.vkDestroyImage),
            .vkCmdCopyBuffer = @ptrCast(vkd.dispatch.vkCmdCopyBuffer),
            .vkGetBufferMemoryRequirements2KHR = @ptrCast(vkd.dispatch.vkGetBufferMemoryRequirements2),
            .vkGetImageMemoryRequirements2KHR = @ptrCast(vkd.dispatch.vkGetImageMemoryRequirements2),
            .vkBindBufferMemory2KHR = @ptrCast(vkd.dispatch.vkBindBufferMemory2),
            .vkBindImageMemory2KHR = @ptrCast(vkd.dispatch.vkBindImageMemory2),
        };

        const allocator_info = c.VmaAllocatorCreateInfo{
            .physicalDevice = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(physical_device)))),
            .device = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(logical_device)))),
            .instance = @ptrCast(@as(*anyopaque, @ptrFromInt(@intFromEnum(instance)))),

            .vulkanApiVersion = c.VK_API_VERSION_1_2,
            .pVulkanFunctions = &vma_vulkan_functions,
            .flags = 0,
        };

        var vma_allocator: c.VmaAllocator = undefined;
        if (c.vmaCreateAllocator(&allocator_info, &vma_allocator) != c.VK_SUCCESS) {
            return error.VmaInitializationFailed;
        }

        return vma_allocator;
    }

    pub fn copyBuffer(self: *const Core, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
        const cb = try self.beginSingleTimeCommands();

        const copy_region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = size,
        };

        self.vkd.cmdCopyBuffer(cb, src, dst, &[_]vk.BufferCopy{copy_region});

        try self.endSingleTimeCommands(cb);
    }

    pub fn beginSingleTimeCommands(self: *const Core) !vk.CommandBuffer {
        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };

        var cb: vk.CommandBuffer = undefined;
        try self.vkd.allocateCommandBuffers(self.logical_device, &alloc_info, @ptrCast(&cb));

        const begin_info = vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        };

        try self.vkd.beginCommandBuffer(cb, &begin_info);
        return cb;
    }

    pub fn endSingleTimeCommands(self: *const Core, cb: vk.CommandBuffer) !void {
        try self.vkd.endCommandBuffer(cb);

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cb),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };

        try self.vkd.queueSubmit(self.graphics_queue, &[_]vk.SubmitInfo{submit_info}, .null_handle);
        try self.vkd.queueWaitIdle(self.graphics_queue);

        self.vkd.freeCommandBuffers(self.logical_device, self.command_pool, @ptrCast(&cb));
    }

    pub fn transitionImageLayoutCmd(self: *const Core, command_buffer: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
        var barrier = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        var source_stage: vk.PipelineStageFlags = .{};
        var destination_stage: vk.PipelineStageFlags = .{};

        if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .transfer_write_bit = true };

            source_stage = .{ .top_of_pipe_bit = true };
            destination_stage = .{ .transfer_bit = true };
        } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{ .transfer_write_bit = true };
            barrier.dst_access_mask = .{ .shader_read_bit = true };

            source_stage = .{ .transfer_bit = true };
            destination_stage = .{ .fragment_shader_bit = true };
        } else if (old_layout == .undefined and new_layout == .shader_read_only_optimal) {
            barrier.src_access_mask = .{};
            barrier.dst_access_mask = .{ .shader_read_bit = true };

            source_stage = .{ .top_of_pipe_bit = true };
            destination_stage = .{ .fragment_shader_bit = true };
        } else if (old_layout == .shader_read_only_optimal and new_layout == .transfer_dst_optimal) {
            barrier.src_access_mask = .{ .shader_read_bit = true };
            barrier.dst_access_mask = .{ .transfer_write_bit = true };

            source_stage = .{ .fragment_shader_bit = true };
            destination_stage = .{ .transfer_bit = true };
        } else {
            return error.UnsupportedLayoutTransition;
        }

        self.vkd.cmdPipelineBarrier(
            command_buffer,
            source_stage,
            destination_stage,
            .{},
            null,
            null,
            &[_]vk.ImageMemoryBarrier{barrier},
        );
    }

    pub fn transitionImageLayout(self: *const Core, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) !void {
        const command_buffer = try self.beginSingleTimeCommands();

        try self.transitionImageLayoutCmd(command_buffer, image, old_layout, new_layout);

        try self.endSingleTimeCommands(command_buffer);
    }

    pub fn copyBufferToImage(self: *const Core, buffer: vk.Buffer, image: vk.Image, width: u32, height: u32) !void {
        const command_buffer = try self.beginSingleTimeCommands();

        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
            .image_extent = vk.Extent3D{
                .width = width,
                .height = height,
                .depth = 1,
            },
        };

        self.vkd.cmdCopyBufferToImage(command_buffer, buffer, image, .transfer_dst_optimal, &[_]vk.BufferImageCopy{region});

        try self.endSingleTimeCommands(command_buffer);
    }

    /// Destroy the old Vulkan surface and create a new one from the current
    /// surface provider state. Used after re-creating the native Wayland surface.
    pub fn recreateSurface(self: *Core) !void {
        _ = self.vkd.deviceWaitIdle(self.logical_device) catch {};
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.surface = try self.surface_provider.createSurface(self.instance, &self.vki);
    }

    pub fn deinit(self: *Core) void {
        c.vmaDestroyAllocator(self.vma_allocator);

        self.vkd.destroyCommandPool(self.logical_device, self.command_pool, null);

        self.vkd.destroyDevice(self.logical_device, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }
};

fn pickPhysicalDevice(allocator: std.mem.Allocator, vki: vk.InstanceWrapper, inst: vk.Instance, surface: vk.SurfaceKHR) !DeviceCandidate {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(inst, &device_count, null);
    if (device_count == 0) {
        return error.NoSuitableDevice;
    }

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    _ = try vki.enumeratePhysicalDevices(inst, &device_count, devices.ptr);

    for (devices) |phys_device| {
        if (try checkDeviceSuitability(allocator, phys_device, vki, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkDeviceSuitability(allocator: std.mem.Allocator, phys_device: vk.PhysicalDevice, vki: vk.InstanceWrapper, surface: vk.SurfaceKHR) !?DeviceCandidate {
    var q_family_count: u32 = 0;

    vki.getPhysicalDeviceQueueFamilyProperties(phys_device, &q_family_count, null);
    const q_families: []vk.QueueFamilyProperties = try allocator.alloc(vk.QueueFamilyProperties, q_family_count);
    defer allocator.free(q_families);

    vki.getPhysicalDeviceQueueFamilyProperties(phys_device, &q_family_count, q_families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (q_families, 0..) |q_family, i| {
        const idx: u32 = @intCast(i);

        if (q_family.queue_flags.graphics_bit) {
            graphics_family = idx;
        }

        const present_support = try vki.getPhysicalDeviceSurfaceSupportKHR(phys_device, idx, surface);
        const vkResult: vk.Bool32 = @enumFromInt(@intFromEnum(present_support));
        if (vkResult == vk.Bool32.true) {
            present_family = idx;
        }

        if (graphics_family != null and present_family != null) break;
    }

    if (graphics_family != null and present_family != null) {
        return DeviceCandidate{
            .physical_device = phys_device,
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkValidationLayerSupport(vkb: vk.BaseWrapper, allocator: std.mem.Allocator) !bool {
    var layer_count: u32 = 0;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    const available_layers = try allocator.alloc(vk.LayerProperties, layer_count);
    defer allocator.free(available_layers);

    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, available_layers.ptr);

    for (validation_layers) |layer_name| {
        var found = false;
        for (available_layers) |layer_properties| {
            const name_slice = std.mem.sliceTo(&layer_properties.layer_name, 0);

            const target_slice = std.mem.span(layer_name);

            if (std.mem.eql(u8, name_slice, target_slice)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return false;
        }
    }
    return true;
}
