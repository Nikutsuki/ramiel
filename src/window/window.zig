const glfw = @import("glfw");
const std = @import("std");
const builtin = @import("builtin");
const layout = @import("../ui/layout.zig");
const platform = @import("../platform/backend.zig");
const glfw_backend = @import("../platform/glfw_backend.zig");
const RenderSurface = @import("../renderer/vulkan/surface.zig").RenderSurface;
const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const win32 = @import("../platform/win32_backend.zig");
const x11 = @import("../platform/x11_backend.zig");

const glfwGetX11Display = if (is_linux)
    struct {
        extern fn glfwGetX11Display() ?*x11.Display;
    }.glfwGetX11Display
else
    struct {
        fn stub() ?*anyopaque {
            return null;
        }
    }.stub;

const glfwGetX11Window = if (is_linux)
    struct {
        extern fn glfwGetX11Window(window: *glfw.Window) c_ulong;
    }.glfwGetX11Window
else
    struct {
        fn stub(_: *glfw.Window) c_ulong {
            return 0;
        }
    }.stub;

pub const Cursor = layout.Cursor;

pub const KeyFn = *const fn (ptr: *anyopaque, key: i32, action: i32) void;
pub const CharFn = *const fn (ptr: *anyopaque, codepoint: u21) void;
pub const ResizeFn = *const fn (ptr: *anyopaque) void;

pub const HotkeyFn = *const fn (user_ptr: ?*anyopaque) void;


const PROP_NAME = std.unicode.utf8ToUtf16LeStringLiteral("ZigWindowContext");

// glfwGetWin32Window: provided by GLFW when built with -D_GLFW_WIN32
const glfwGetWin32Window = if (is_windows)
    struct {
        extern fn glfwGetWin32Window(window: *glfw.Window) ?win32.HWND;
    }.glfwGetWin32Window
else
    struct {
        fn stub(_: *glfw.Window) ?win32.HWND {
            return null;
        }
    }.stub;

const HotkeyEntry = struct {
    callback: HotkeyFn,
    user_ptr: ?*anyopaque,
    x11_keycode: u32 = 0,
    x11_mods: u32 = 0,
};

pub const WindowContext = struct {
    pub const ScrollDelta = struct {
        x: f64,
        y: f64,
    };

    window: *glfw.Window,
    backend: platform.BackendKind = .glfw,
    surface_kind: platform.SurfaceKind = .normal,

    user_ptr: ?*anyopaque = null,
    key_fn: ?KeyFn = null,
    char_fn: ?CharFn = null,
    resize_fn: ?ResizeFn = null,

    scroll_accum_x: f64 = 0.0,
    scroll_accum_y: f64 = 0.0,

    cursor_arrow: ?*glfw.CursorHandle = null,
    cursor_ibeam: ?*glfw.CursorHandle = null,
    cursor_hand: ?*glfw.CursorHandle = null,
    cursor_crosshair: ?*glfw.CursorHandle = null,
    cursor_ns_resize: ?*glfw.CursorHandle = null,
    cursor_ew_resize: ?*glfw.CursorHandle = null,
    active_cursor: Cursor = .default,

    allocator: std.mem.Allocator,
    hotkeys: std.AutoHashMap(i32, HotkeyEntry),
    hotkeys_mutex: std.Io.Mutex = .init,
    next_hotkey_id: i32 = 1,
    original_wndproc: ?win32.WNDPROC = null,

    // dedicated X11 connection for the hotkey listener thread; lazy on first registerGlobalHotkey
    x11_hotkey_display: ?*anyopaque = null,
    x11_hotkey_thread: ?std.Thread = null,
    x11_hotkey_should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn registerCallbacks(
        self: *WindowContext,
        user_ptr: *anyopaque,
        key_fn: KeyFn,
        char_fn: CharFn,
        resize_fn: ResizeFn,
    ) void {
        self.user_ptr = user_ptr;
        self.key_fn = key_fn;
        self.char_fn = char_fn;
        self.resize_fn = resize_fn;
        glfw.setWindowUserPointer(self.window, self);
        _ = glfw.setKeyCallback(self.window, glfwKeyCallback);
        _ = glfw.setCharCallback(self.window, glfwCharCallback);
        _ = glfw.setScrollCallback(self.window, glfwScrollCallback);
        _ = glfw.setFramebufferSizeCallback(self.window, glfwResizeCallback);
    }

    pub fn backendKind(self: *const WindowContext) platform.BackendKind {
        return self.backend;
    }

    pub fn surfaceKind(self: *const WindowContext) platform.SurfaceKind {
        return self.surface_kind;
    }

    pub fn shouldClose(self: *const WindowContext) bool {
        return glfw.windowShouldClose(self.window);
    }

    pub fn pollEvents(_: *WindowContext) void {
        glfw.pollEvents();
    }

    pub fn waitEvents(_: *WindowContext) void {
        glfw.waitEvents();
    }

    pub fn waitEventsTimeout(_: *WindowContext, timeout_s: f64) void {
        glfw.waitEventsTimeout(timeout_s);
    }

    pub fn postEmptyEvent(_: *WindowContext) void {
        glfw.postEmptyEvent();
    }

    pub fn timeSeconds(_: *const WindowContext) f64 {
        return glfw.getTime();
    }

    pub fn renderSurface(self: *WindowContext) RenderSurface {
        return glfw_backend.renderSurface(self.window);
    }

    pub fn isVisible(self: *const WindowContext) bool {
        return glfw.getWindowAttrib(self.window, glfw.Visible) != 0;
    }

    pub fn primaryRefreshRateHz(_: *const WindowContext) ?f64 {
        const monitor = glfw.getPrimaryMonitor();
        if (glfw.getVideoMode(monitor)) |mode| {
            return @as(f64, @floatFromInt(mode.refreshRate));
        }
        return null;
    }

    pub fn setCursorPos(self: *WindowContext, x: f64, y: f64) void {
        glfw.setCursorPos(self.window, x, y);
    }

    pub fn getFramebufferSize(self: *const WindowContext) struct { width: i32, height: i32 } {
        var w: i32 = 0;
        var h: i32 = 0;
        glfw.getFramebufferSize(self.window, &w, &h);
        return .{ .width = w, .height = h };
    }

    pub fn getCursorPos(self: *const WindowContext) struct { x: f64, y: f64 } {
        var x: f64 = 0;
        var y: f64 = 0;
        glfw.getCursorPos(self.window, &x, &y);
        return .{ .x = x, .y = y };
    }

    pub fn consumeScrollDelta(self: *WindowContext) ScrollDelta {
        const delta = ScrollDelta{ .x = self.scroll_accum_x, .y = self.scroll_accum_y };
        self.scroll_accum_x = 0.0;
        self.scroll_accum_y = 0.0;
        return delta;
    }

    pub fn pointerInputSnapshot(self: *WindowContext) platform.PointerInputSnapshot {
        const cursor = self.getCursorPos();
        const scroll = self.consumeScrollDelta();
        return .{
            .x = cursor.x,
            .y = cursor.y,
            .left_down = self.isMouseButtonDown(glfw.MouseButtonLeft),
            .right_down = self.isMouseButtonDown(glfw.MouseButtonRight),
            .scroll_dx = scroll.x,
            .scroll_dy = scroll.y,
            .mods = self.getMods(),
        };
    }

    pub fn isMouseButtonDown(self: *const WindowContext, button: i32) bool {
        return glfw.getMouseButton(self.window, button) == glfw.Press;
    }

    pub fn isKeyDown(self: *const WindowContext, key: i32) bool {
        return glfw.getKey(self.window, key) == glfw.Press;
    }

    pub fn getMods(self: *const WindowContext) i32 {
        var mods: i32 = 0;
        if (self.isKeyDown(glfw.KeyLeftShift) or self.isKeyDown(glfw.KeyRightShift)) mods |= glfw.ModifierShift;
        if (self.isKeyDown(glfw.KeyLeftControl) or self.isKeyDown(glfw.KeyRightControl)) mods |= glfw.ModifierControl;
        if (self.isKeyDown(glfw.KeyLeftAlt) or self.isKeyDown(glfw.KeyRightAlt)) mods |= glfw.ModifierAlt;
        if (self.isKeyDown(glfw.KeyLeftSuper) or self.isKeyDown(glfw.KeyRightSuper)) mods |= glfw.ModifierSuper;
        return mods;
    }

    pub fn getClipboardString(self: *const WindowContext) ?[:0]const u8 {
        return glfw.getClipboardString(self.window);
    }

    pub fn setClipboardString(self: *const WindowContext, str: [:0]const u8) void {
        glfw.setClipboardString(self.window, str);
    }

    pub fn setCursor(self: *WindowContext, cursor: Cursor) void {
        if (self.active_cursor == cursor) return;
        self.active_cursor = cursor;
        const handle: ?*glfw.CursorHandle = switch (cursor) {
            .default => self.cursor_arrow,
            .pointer => self.cursor_hand,
            .text => self.cursor_ibeam,
            .crosshair => self.cursor_crosshair,
            .ns_resize => self.cursor_ns_resize,
            .ew_resize => self.cursor_ew_resize,
        };
        glfw.setCursor(self.window, handle);
    }

    pub fn setCursorModeDisabled(self: *WindowContext, disabled: bool) void {
        const mode = if (disabled) glfw.CursorDisabled else glfw.CursorNormal;
        glfw.setInputMode(self.window, glfw.Cursor, mode);
    }

    pub fn show(self: *WindowContext) void {
        glfw.showWindow(self.window);
        glfw.focusWindow(self.window);
    }

    pub fn hide(self: *WindowContext) void {
        glfw.hideWindow(self.window);
    }

    // Win32: clear WS_EX_APPWINDOW + set WS_EX_TOOLWINDOW to drop from taskbar/Alt-Tab.
    // SWP_FRAMECHANGED forces the shell to re-read GWL_EXSTYLE.
    pub fn configureAsOverlay(self: *WindowContext) void {
        if (comptime is_linux) {
            const dpy = glfwGetX11Display() orelse return;
            const win = glfwGetX11Window(self.window);
            if (win == 0) return;
            x11.configureAsOverlay(dpy, win);
            return;
        }
        if (comptime !is_windows) {
            return;
        } else {
            const hwnd = glfwGetWin32Window(self.window) orelse return;
            win32.configureAsOverlay(hwnd);
        }
    }

    // Win32: subclasses the wndproc on first call to intercept WM_HOTKEY.
    // X11: spawns a listener thread with its own Display for root-window key grabs.
    pub fn registerGlobalHotkey(
        self: *WindowContext,
        modifier: u32,
        key: u32,
        user_ptr: ?*anyopaque,
        callback: HotkeyFn,
    ) !void {
        if (comptime is_linux) {
            return registerGlobalHotkeyX11(self, modifier, key, user_ptr, callback);
        }
        if (comptime !is_windows) {
            return error.Unsupported;
        } else {
            const hwnd = glfwGetWin32Window(self.window) orelse return error.NoNativeHandle;

            // GLFW discards WM_HOTKEY; subclass to intercept before that.
            if (self.original_wndproc == null) {
                _ = win32.setPropW(hwnd, PROP_NAME, @ptrCast(self));
                const prev = win32.getWindowLongPtrW(hwnd, win32.GWLP_WNDPROC);
                self.original_wndproc = @ptrFromInt(@as(usize, @bitCast(prev)));
                _ = win32.setWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&hookedWndProc)));
            }

            const id = self.next_hotkey_id;
            self.next_hotkey_id += 1;

            if (win32.registerHotKey(hwnd, id, modifier, key) == 0) {
                return error.HotkeyRegistrationFailed;
            }

            try self.hotkeys.put(id, .{ .callback = callback, .user_ptr = user_ptr });
        }
    }

    pub fn deinit(self: *WindowContext) void {
        if (comptime is_windows) {
            if (glfwGetWin32Window(self.window)) |hwnd| {
                var it = self.hotkeys.keyIterator();
                while (it.next()) |id| {
                    _ = win32.unregisterHotKey(hwnd, id.*);
                }

                if (self.original_wndproc) |orig| {
                    _ = win32.setWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(orig)));
                    _ = win32.removePropW(hwnd, PROP_NAME);
                }
            }
        }
        if (comptime is_linux) {
            if (self.x11_hotkey_thread) |t| {
                self.x11_hotkey_should_stop.store(true, .release);
                t.join();
                self.x11_hotkey_thread = null;
            }
            if (self.x11_hotkey_display) |dpy| {
                _ = x11.closeDisplay(@ptrCast(dpy));
                self.x11_hotkey_display = null;
            }
        }
        self.hotkeys.deinit();

        glfw.destroyCursor(self.cursor_arrow);
        glfw.destroyCursor(self.cursor_ibeam);
        glfw.destroyCursor(self.cursor_hand);
        glfw.destroyCursor(self.cursor_crosshair);
        glfw.destroyCursor(self.cursor_ns_resize);
        glfw.destroyCursor(self.cursor_ew_resize);
        glfw.destroyWindow(self.window);
        glfw.terminate();
    }

    fn glfwKeyCallback(win: *glfw.Window, key: i32, scancode: i32, action: i32, mods: i32) callconv(.c) void {
        _ = scancode;
        _ = mods;
        const ctx: *WindowContext = @ptrCast(@alignCast(glfw.getWindowUserPointer(win) orelse return));
        if (ctx.key_fn) |f| if (ctx.user_ptr) |p| f(p, key, action);
    }

    fn glfwCharCallback(win: *glfw.Window, codepoint: u32) callconv(.c) void {
        const ctx: *WindowContext = @ptrCast(@alignCast(glfw.getWindowUserPointer(win) orelse return));
        if (ctx.char_fn) |f| if (ctx.user_ptr) |p| f(p, @intCast(codepoint));
    }

    fn glfwScrollCallback(win: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
        const ctx: *WindowContext = @ptrCast(@alignCast(glfw.getWindowUserPointer(win) orelse return));
        ctx.scroll_accum_x += xoffset;
        ctx.scroll_accum_y += yoffset;
    }

    fn glfwResizeCallback(win: *glfw.Window, width: i32, height: i32) callconv(.c) void {
        _ = width;
        _ = height;
        const ctx: *WindowContext = @ptrCast(@alignCast(glfw.getWindowUserPointer(win) orelse return));
        if (ctx.resize_fn) |f| if (ctx.user_ptr) |p| f(p);
    }
};

const hookedWndProc = if (is_windows) struct {
    fn impl(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wParam: win32.WPARAM,
        lParam: win32.LPARAM,
    ) callconv(.c) win32.LRESULT {
        const prop = win32.getPropW(hwnd, PROP_NAME);
        if (prop) |p| {
            const ctx: *WindowContext = @ptrCast(@alignCast(p));

            if (msg == win32.WM_HOTKEY) {
                const hotkey_id: i32 = @intCast(wParam);
                if (ctx.hotkeys.get(hotkey_id)) |entry| {
                    entry.callback(entry.user_ptr);
                }
                return 0;
            }

            return win32.callWindowProcW(ctx.original_wndproc.?, hwnd, msg, wParam, lParam);
        }

        return win32.defWindowProcW(hwnd, msg, wParam, lParam);
    }
}.impl else void;

fn registerGlobalHotkeyX11(
    self: *WindowContext,
    modifier: u32,
    key: u32,
    user_ptr: ?*anyopaque,
    callback: HotkeyFn,
) !void {
    if (comptime !is_linux) return error.Unsupported;

    if (self.x11_hotkey_display == null) {
        const dpy = x11.openDisplay() orelse return error.NoNativeHandle;
        self.x11_hotkey_display = dpy;
    }
    const dpy: *x11.Display = @ptrCast(self.x11_hotkey_display.?);

    const keysym = x11.keysymForVirtualKey(key);
    if (keysym == 0) return error.HotkeyRegistrationFailed;
    const keycode = x11.keysymToKeycode(dpy, keysym);
    if (keycode == 0) return error.HotkeyRegistrationFailed;

    const root = x11.defaultRootWindow(dpy);
    const mods = x11.modifiersForHotkey(modifier);

    const lock_variants = [_]c_uint{
        0,
        x11.LockMask,
        x11.Mod2Mask,
        x11.LockMask | x11.Mod2Mask,
    };
    for (lock_variants) |lv| {
        x11.grabKey(dpy, @intCast(keycode), mods | lv, root);
    }
    x11.selectRootKeyPress(dpy, root);
    x11.sync(dpy);

    self.hotkeys_mutex.lockUncancelable(std.Options.debug_io);
    const id = self.next_hotkey_id;
    self.next_hotkey_id += 1;
    try self.hotkeys.put(id, .{
        .callback = callback,
        .user_ptr = user_ptr,
        .x11_keycode = keycode,
        .x11_mods = mods,
    });
    self.hotkeys_mutex.unlock(std.Options.debug_io);

    if (self.x11_hotkey_thread == null) {
        self.x11_hotkey_should_stop.store(false, .release);
        self.x11_hotkey_thread = try std.Thread.spawn(.{}, x11HotkeyLoop, .{self});
    }
}

fn x11HotkeyLoop(self: *WindowContext) void {
    if (comptime !is_linux) return;
    const dpy: *x11.Display = @ptrCast(self.x11_hotkey_display orelse return);

    const ignore_mask: c_uint = x11.LockMask | x11.Mod2Mask;
    const match_mask: c_uint = ~ignore_mask;

    while (!self.x11_hotkey_should_stop.load(.acquire)) {
        if (x11.pending(dpy) > 0) {
            var ev: x11.XEvent = undefined;
            x11.nextEvent(dpy, &ev);
            if (ev.type == x11.KeyPress) {
                const ke: *x11.XKeyEvent = @ptrCast(&ev);
                const ev_keycode: u32 = ke.keycode;
                const ev_state: c_uint = ke.state & match_mask;

                self.hotkeys_mutex.lockUncancelable(std.Options.debug_io);
                var fire_cb: ?HotkeyFn = null;
                var fire_ptr: ?*anyopaque = null;
                var it = self.hotkeys.valueIterator();
                while (it.next()) |entry| {
                    if (entry.x11_keycode == ev_keycode and entry.x11_mods == ev_state) {
                        fire_cb = entry.callback;
                        fire_ptr = entry.user_ptr;
                        break;
                    }
                }
                self.hotkeys_mutex.unlock(std.Options.debug_io);
                if (fire_cb) |cb| cb(fire_ptr);
            }
        } else {
            _ = std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
    }
}

pub fn initWindow(allocator: std.mem.Allocator, config: platform.AppBackendConfig) !WindowContext {
    if (config.backend != .glfw) return error.UnsupportedBackend;
    try glfw_backend.validateSurfaceKind(config.surface_kind);

    // Disable libdecor on Wayland: libdecor-gtk -> libpango -> hb_ot_metrics alignment crash.
    // GLFW_WAYLAND_LIBDECOR=0x00053001, GLFW_WAYLAND_DISABLE_LIBDECOR=0x00038002.
    if (comptime is_linux) {
        glfw.initHint(@as(c_int, 0x00053001), @as(c_int, 0x00038002));
    }
    try glfw.init();
    errdefer glfw.terminate();

    glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);
    glfw.windowHint(glfw.TransparentFramebuffer, if (config.transparent) 1 else 0);
    glfw.windowHint(glfw.Decorated, if (config.borderless) 0 else 1);
    glfw.windowHint(glfw.Floating, if (config.topmost) 1 else 0);
    glfw.windowHint(glfw.Visible, if (config.visible_on_start) 1 else 0);

    // GLFW_SCALE_FRAMEBUFFER=0x0002200D off; matches X11/Windows behaviour, compositor upscales.
    if (comptime is_linux) {
        glfw.windowHint(@as(c_int, 0x0002200D), 0);
    }

    const win = try glfw.createWindow(@intCast(config.width), @intCast(config.height), config.title, null, null);
    std.log.info(
        "window transparency request={} glfw_transparent_framebuffer_attrib={d}",
        .{ config.transparent, glfw.getWindowAttrib(win, glfw.TransparentFramebuffer) },
    );

    // Win32: DwmExtendFrameIntoClientArea(-1...) needed alongside transparent FB hint
    // so VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR yields per-pixel alpha.
    if (comptime is_windows) {
        if (config.transparent) {
            if (glfwGetWin32Window(win)) |hwnd| {
                const margins = win32.MARGINS{
                    .cxLeftWidth = -1,
                    .cxRightWidth = -1,
                    .cyTopHeight = -1,
                    .cyBottomHeight = -1,
                };
                const hr = win32.dwmExtendFrameIntoClientArea(hwnd, &margins);
                if (hr < 0) {
                    std.log.warn("DwmExtendFrameIntoClientArea failed with HRESULT={d}", .{hr});
                } else {
                    std.log.info("DwmExtendFrameIntoClientArea succeeded with HRESULT={d}", .{hr});
                }
            } else {
                std.log.warn("transparent window requested but no native Win32 handle is available", .{});
            }
        }
    }

    return WindowContext{
        .window = win,
        .backend = config.backend,
        .surface_kind = config.surface_kind,
        .allocator = allocator,
        .hotkeys = std.AutoHashMap(i32, HotkeyEntry).init(allocator),
        .cursor_arrow = glfw.createStandardCursor(glfw.Arrow),
        .cursor_ibeam = glfw.createStandardCursor(glfw.IBeam),
        .cursor_hand = glfw.createStandardCursor(glfw.Hand),
        .cursor_crosshair = glfw.createStandardCursor(glfw.Crosshair),
        .cursor_ns_resize = glfw.createStandardCursor(glfw.VResize),
        .cursor_ew_resize = glfw.createStandardCursor(glfw.HResize),
    };
}
