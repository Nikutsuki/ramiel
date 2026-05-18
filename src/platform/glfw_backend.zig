//! Capability metadata and Vulkan surface adapter for the current GLFW backend.
//!
//! Window creation still lives in `src/window/window.zig` during the refactor,
//! but GLFW-specific Vulkan WSI glue is kept here instead of in the generic
//! renderer surface interface.

const builtin = @import("builtin");
const std = @import("std");
const glfw = @import("glfw");
const vk = @import("../vk.zig");
const RenderSurface = @import("../renderer/vulkan/surface.zig").RenderSurface;
const RequiredExtensions = @import("../renderer/vulkan/surface.zig").RequiredExtensions;
const platform = @import("backend.zig");

pub const kind: platform.BackendKind = .glfw;

pub const Capabilities = struct {
    normal_windows: bool,
    transparent_windows: bool,
    legacy_overlay: bool,
    layer_shell: bool,
    global_hotkeys: bool,
    focused_hotkeys_only: bool,
    resident_popup_launcher: bool,
};

pub fn capabilities() Capabilities {
    return switch (builtin.os.tag) {
        .windows => .{
            .normal_windows = true,
            .transparent_windows = true,
            .legacy_overlay = true,
            .layer_shell = false,
            .global_hotkeys = true,
            .focused_hotkeys_only = false,
            .resident_popup_launcher = true,
        },
        .linux => .{
            .normal_windows = true,
            .transparent_windows = true,
            .legacy_overlay = true,
            .layer_shell = false,
            .global_hotkeys = true,
            .focused_hotkeys_only = false,
            .resident_popup_launcher = true,
        },
        else => .{
            .normal_windows = true,
            .transparent_windows = false,
            .legacy_overlay = false,
            .layer_shell = false,
            .global_hotkeys = false,
            .focused_hotkeys_only = true,
            .resident_popup_launcher = true,
        },
    };
}

pub fn supportsSurfaceKind(surface_kind: platform.SurfaceKind) bool {
    const caps = capabilities();
    return switch (surface_kind) {
        .normal => caps.normal_windows,
        .overlay => caps.legacy_overlay,
        .popup_launcher => caps.resident_popup_launcher,
        .layer_shell => caps.layer_shell,
    };
}

pub fn validateSurfaceKind(surface_kind: platform.SurfaceKind) !void {
    try platform.validateSurfaceKind(surface_kind);
    if (!supportsSurfaceKind(surface_kind)) return error.UnsupportedSurfaceKind;
}

pub fn renderSurface(window: *glfw.Window) RenderSurface {
    return .{
        .ctx = @ptrCast(window),
        .get_instance_proc_address = glfwGetInstanceProcAddress,
        .required_extensions_fn = glfwRequiredExtensions,
        .create_surface_fn = glfwCreateSurface,
        .framebuffer_size_fn = glfwFramebufferSize,
        .wait_events_fn = glfwWaitEvents,
        .time_seconds_fn = glfwTimeSeconds,
    };
}

fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) callconv(.c) vk.PfnVoidFunction {
    return @ptrCast(glfw.getInstanceProcAddress(@intFromEnum(instance), procname));
}

fn glfwRequiredExtensions(_: *anyopaque) !RequiredExtensions {
    var count: u32 = 0;
    const names = glfw.getRequiredInstanceExtensions(&count) orelse return error.ExtensionQueryFailed;
    return .{ .names = names, .count = count };
}

fn glfwCreateSurface(ctx: *anyopaque, instance: vk.Instance, _: *const vk.InstanceWrapper) !vk.SurfaceKHR {
    const window: *glfw.Window = @ptrCast(@alignCast(ctx));
    var raw_surface: u64 = undefined;
    const glfw_result = glfw.createWindowSurface(@intFromEnum(instance), window, null, &raw_surface);
    const vk_result: vk.Result = @enumFromInt(@intFromEnum(glfw_result));
    if (vk_result != .success) return error.SurfaceCreationFailed;
    return @enumFromInt(raw_surface);
}

fn glfwFramebufferSize(ctx: *anyopaque) vk.Extent2D {
    const window: *glfw.Window = @ptrCast(@alignCast(ctx));
    var w: i32 = 0;
    var h: i32 = 0;
    glfw.getFramebufferSize(window, &w, &h);
    return .{
        .width = if (w > 0) @intCast(w) else 0,
        .height = if (h > 0) @intCast(h) else 0,
    };
}

fn glfwWaitEvents(_: *anyopaque) void {
    glfw.waitEvents();
}

fn glfwTimeSeconds(_: *anyopaque) f64 {
    return glfw.getTime();
}

test "glfw backend rejects layer shell" {
    try std.testing.expectError(
        error.UnsupportedSurfaceKind,
        validateSurfaceKind(.{ .layer_shell = .{ .anchors = .{ .top = true } } }),
    );
}
