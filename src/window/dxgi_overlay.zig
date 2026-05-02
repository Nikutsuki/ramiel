const builtin = @import("builtin");
const glfw = @import("glfw");
const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {
    pub const HWND = *anyopaque;
};

pub const DxgiOverlay = if (is_windows) WindowsDxgiOverlay else StubDxgiOverlay;

const WindowsDxgiOverlay = struct {
    handle: *anyopaque,

    extern fn glfwGetWin32Window(window: *glfw.Window) ?win32.HWND;

    extern fn dxgi_overlay_create(hwnd: win32.HWND, width: c_int, height: c_int) ?*anyopaque;
    extern fn dxgi_overlay_resize(ctx: *anyopaque, width: c_int, height: c_int) c_long;
    extern fn dxgi_overlay_present_bgra_straight(
        ctx: *anyopaque,
        pixels: [*]const u8,
        width: c_int,
        height: c_int,
        stride_bytes: c_int,
    ) c_long;
    extern fn dxgi_overlay_destroy(ctx: *anyopaque) void;

    pub fn init(window: *glfw.Window, width: i32, height: i32) !WindowsDxgiOverlay {
        const hwnd = glfwGetWin32Window(window) orelse return error.NoNativeWindowHandle;
        const ctx = dxgi_overlay_create(hwnd, width, height) orelse return error.DxgiOverlayInitFailed;
        return .{ .handle = ctx };
    }

    pub fn resize(self: *WindowsDxgiOverlay, width: i32, height: i32) !void {
        const hr = dxgi_overlay_resize(self.handle, width, height);
        if (hr < 0) return error.DxgiOverlayResizeFailed;
    }

    pub fn presentBgraStraight(
        self: *WindowsDxgiOverlay,
        pixels: [*]const u8,
        width: i32,
        height: i32,
        stride_bytes: i32,
    ) !void {
        const hr = dxgi_overlay_present_bgra_straight(self.handle, pixels, width, height, stride_bytes);
        if (hr < 0) return error.DxgiOverlayPresentFailed;
    }

    pub fn deinit(self: *WindowsDxgiOverlay) void {
        dxgi_overlay_destroy(self.handle);
        self.handle = undefined;
    }
};

const StubDxgiOverlay = struct {
    pub fn init(_: *glfw.Window, _: i32, _: i32) !StubDxgiOverlay {
        return error.UnsupportedPlatform;
    }

    pub fn resize(_: *StubDxgiOverlay, _: i32, _: i32) !void {
        return error.UnsupportedPlatform;
    }

    pub fn presentBgraStraight(
        _: *StubDxgiOverlay,
        _: [*]const u8,
        _: i32,
        _: i32,
        _: i32,
    ) !void {
        return error.UnsupportedPlatform;
    }

    pub fn deinit(_: *StubDxgiOverlay) void {}
};
