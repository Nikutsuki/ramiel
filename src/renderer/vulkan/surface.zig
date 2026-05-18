const vk = @import("../../vk.zig");

pub const RequiredExtensions = struct {
    names: [*]const [*:0]const u8,
    count: u32,
};

pub const GetInstanceProcAddressFn = *const fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.c) vk.PfnVoidFunction;
pub const RequiredExtensionsFn = *const fn (ctx: *anyopaque) anyerror!RequiredExtensions;
pub const CreateSurfaceFn = *const fn (ctx: *anyopaque, instance: vk.Instance, vki: *const vk.InstanceWrapper) anyerror!vk.SurfaceKHR;
pub const FramebufferSizeFn = *const fn (ctx: *anyopaque) vk.Extent2D;
pub const WaitEventsFn = *const fn (ctx: *anyopaque) void;
pub const TimeSecondsFn = *const fn (ctx: *anyopaque) f64;

/// Backend-neutral Vulkan presentation target.
///
/// Ramiel owns rendering to a `VkSurfaceKHR`; platform backends own native
/// window/surface creation, event lifecycle, and construction of this adapter.
pub const RenderSurface = struct {
    ctx: *anyopaque,
    get_instance_proc_address: GetInstanceProcAddressFn,
    required_extensions_fn: RequiredExtensionsFn,
    create_surface_fn: CreateSurfaceFn,
    framebuffer_size_fn: FramebufferSizeFn,
    wait_events_fn: WaitEventsFn,
    time_seconds_fn: TimeSecondsFn,

    pub fn requiredExtensions(self: RenderSurface) !RequiredExtensions {
        return self.required_extensions_fn(self.ctx);
    }

    pub fn createSurface(self: RenderSurface, instance: vk.Instance, vki: *const vk.InstanceWrapper) !vk.SurfaceKHR {
        return self.create_surface_fn(self.ctx, instance, vki);
    }

    pub fn framebufferSize(self: RenderSurface) vk.Extent2D {
        return self.framebuffer_size_fn(self.ctx);
    }

    pub fn waitEvents(self: RenderSurface) void {
        self.wait_events_fn(self.ctx);
    }

    pub fn timeSeconds(self: RenderSurface) f64 {
        return self.time_seconds_fn(self.ctx);
    }
};
