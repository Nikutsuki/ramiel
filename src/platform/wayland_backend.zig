//! Native Wayland client backend for Ramiel.
//!
//! Provides a self-contained Wayland client that can create xdg-shell toplevel
//! windows or wlr-layer-shell surfaces (bars, overlays, launchers). Integrates
//! with the Vulkan renderer through `WaylandSurfaceHandles`.
//!
//! Usage from an example or app:
//!
//!     var client = try WaylandClient.init(allocator, .{
//!         .surface_kind = .{ .layer_shell = .{
//!             .layer = .top,
//!             .anchors = .{ .top = true, .left = true, .right = true },
//!             .exclusive_zone = 32,
//!         }},
//!         .width = 0,  // 0 = let compositor decide (anchored)
//!         .height = 32,
//!     });
//!     defer client.deinit();
//!
//!     const render_surface = client.renderSurface();
//!     var engine = try Engine.initWithSurface(alloc, io, render_surface, null, false, .{});

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const platform = @import("backend.zig");
const vk = @import("../vk.zig");
const surface_mod = @import("../renderer/vulkan/surface.zig");
const RenderSurface = surface_mod.RenderSurface;
const RequiredExtensions = surface_mod.RequiredExtensions;
const GetInstanceProcAddressFn = surface_mod.GetInstanceProcAddressFn;

pub const WaylandSurfaceHandles = struct {
    display: *vk.wl_display,
    surface: *vk.wl_surface,
    get_instance_proc_address: GetInstanceProcAddressFn,
    width: u32,
    height: u32,
    wait_events: ?*const fn (ctx: ?*anyopaque) void = null,
    time_seconds: ?*const fn (ctx: ?*anyopaque) f64 = null,
    user_ctx: ?*anyopaque = null,

    pub fn setExtent(self: *WaylandSurfaceHandles, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }
};

const wayland_extensions = [_][*:0]const u8{
    vk.extensions.khr_surface.name,
    vk.extensions.khr_wayland_surface.name,
};

pub const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));

pub const Config = struct {
    surface_kind: platform.SurfaceKind = .normal,
    title: [:0]const u8 = "Ramiel",
    width: u32 = 800,
    height: u32 = 600,
    keyboard_interactivity: platform.KeyboardInteractivity = .none,

    pub fn fromBackendConfig(config: platform.AppBackendConfig) Config {
        return .{
            .surface_kind = config.surface_kind,
            .title = config.title,
            .width = config.width,
            .height = config.height,
            .keyboard_interactivity = switch (config.surface_kind) {
                .layer_shell => |opts| opts.keyboard_interactivity,
                else => .none,
            },
        };
    }
};

pub fn supportsSurfaceKind(surface_kind: platform.SurfaceKind) bool {
    return switch (surface_kind) {
        .normal, .overlay, .popup_launcher, .layer_shell => true,
    };
}

pub fn validateSurfaceKind(surface_kind: platform.SurfaceKind) !void {
    try platform.validateSurfaceKind(surface_kind);
    if (!supportsSurfaceKind(surface_kind)) return error.UnsupportedSurfaceKind;
}

pub const WaylandClient = struct {
    pub const KeyEvent = struct { key: u32, evdev_key: u32, state: u32 };
    pub const CharEvent = struct { codepoint: u21 };

    // Wayland globals
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    seat: ?*wl.Seat = null,
    shm: ?*wl.Shm = null,

    // Surface objects
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    xdg_toplevel: ?*xdg.Toplevel = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,

    // State
    config: Config,
    width: u32,
    height: u32,
    configured: bool = false,
    running: bool = true,
    visible: bool = true,

    // Input
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_button: u32 = 0,
    left_button_down: bool = false,
    right_button_down: bool = false,
    left_pressed_sticky: bool = false,
    right_pressed_sticky: bool = false,
    pointer_serial: u32 = 0,

    // Cursor
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_surface: ?*wl.Surface = null,
    current_cursor_name: ?[*:0]const u8 = null,
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,

    // Vulkan integration
    handles: WaylandSurfaceHandles = undefined,

    // xkb state for keycode → keysym/UTF-32 translation
    xkb_context: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Queued keyboard events (drained each frame)
    key_queue: [64]KeyEvent = undefined,
    key_queue_len: usize = 0,
    char_queue: [64]CharEvent = undefined,
    char_queue_len: usize = 0,

    // Key repeat state (client-side, per Wayland protocol)
    repeat_key: ?u32 = null,
    repeat_rate: i32 = 25,  // keys per second
    repeat_delay: i32 = 600, // ms before first repeat
    repeat_deadline_ns: i96 = 0,

    // Callbacks
    on_key: ?*const fn (key: u32, state: u32) void = null,
    on_pointer_motion: ?*const fn (x: f64, y: f64) void = null,
    on_pointer_button: ?*const fn (button: u32, state: u32) void = null,
    on_scroll: ?*const fn (dx: f64, dy: f64) void = null,
    on_configure: ?*const fn (width: u32, height: u32) void = null,

    /// Initialize the Wayland client. Must be called on a stable (non-moving)
    /// pointer — allocate or declare as `var` at the call site, then call `setup()`.
    pub fn init(config: Config) WaylandClient {
        return .{
            .display = undefined,
            .registry = undefined,
            .config = config,
            .width = config.width,
            .height = config.height,
        };
    }

    /// Connect to the Wayland display, bind globals, create the surface.
    /// Must be called after `init` on a pointer that won't move.
    pub fn setup(self: *WaylandClient) !void {
        const display = try wl.Display.connect(null);
        self.display = display;
        const registry = try display.getRegistry();
        self.registry = registry;

        registry.setListener(*WaylandClient, registryListener, self);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        if (self.compositor == null) return error.NoCompositor;

        switch (self.config.surface_kind) {
            .layer_shell => {
                if (self.layer_shell == null) return error.NoLayerShell;
            },
            .normal, .overlay, .popup_launcher => {
                if (self.wm_base == null) return error.NoXdgWmBase;
            },
        }

        // Create wl_surface
        self.surface = try self.compositor.?.createSurface();

        // Bind seat listeners if we have a seat
        if (self.seat) |seat| {
            seat.setListener(*WaylandClient, seatListener, self);
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }

        // Create role
        switch (self.config.surface_kind) {
            .layer_shell => |opts| try self.createLayerSurface(opts),
            .normal, .overlay, .popup_launcher => try self.createXdgToplevel(),
        }

        // Init cursor theme
        if (self.shm) |shm| {
            self.cursor_theme = wl.CursorTheme.load(null, 24, shm) catch null;
            if (self.compositor) |comp| {
                self.cursor_surface = comp.createSurface() catch null;
            }
        }

        // Initial commit
        self.surface.?.commit();

        // Wait for configure
        while (!self.configured) {
            if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }

        // Set up Vulkan handles
        self.handles = .{
            .display = @ptrCast(self.display),
            .surface = @ptrCast(self.surface.?),
            .get_instance_proc_address = @ptrCast(&vkGetInstanceProcAddrLoader),
            .width = self.width,
            .height = self.height,
            .wait_events = waylandWaitCb,
            .time_seconds = waylandTimeCb,
            .user_ctx = @ptrCast(self.display),
        };
    }

    /// Update all Wayland listener userdata pointers to the current `self`.
    /// Must be called after the WaylandClient has been moved to its final memory
    /// location (e.g. after being copied into a Backend union or Application struct).
    /// Wayland proxies only allow setting a listener once, so we update the
    /// userdata pointer directly via the C API.
    pub fn rebindListeners(self: *WaylandClient) void {
        const self_ptr: ?*anyopaque = @ptrCast(self);
        setProxyUserData(self.registry, self_ptr);
        if (self.seat) |seat| setProxyUserData(seat, self_ptr);
        if (self.keyboard) |kb| setProxyUserData(kb, self_ptr);
        if (self.pointer) |ptr| setProxyUserData(ptr, self_ptr);
        if (self.layer_surface) |ls| setProxyUserData(ls, self_ptr);
        if (self.xdg_surface) |xs| setProxyUserData(xs, self_ptr);
        if (self.xdg_toplevel) |tl| setProxyUserData(tl, self_ptr);
        if (self.wm_base) |wm| setProxyUserData(wm, self_ptr);
    }

    fn setProxyUserData(proxy: anytype, data: ?*anyopaque) void {
        const raw: *wl.Proxy = @ptrCast(proxy);
        wl_proxy_set_user_data(raw, data);
    }

    extern fn wl_proxy_set_user_data(proxy: *wl.Proxy, data: ?*anyopaque) void;

    pub fn deinit(self: *WaylandClient) void {
        if (self.keyboard) |kb| kb.release();
        if (self.pointer) |ptr| ptr.release();
        if (self.layer_surface) |ls| ls.destroy();
        if (self.xdg_toplevel) |tl| tl.destroy();
        if (self.xdg_surface) |xs| xs.destroy();
        if (self.surface) |s| s.destroy();
        self.display.disconnect();
    }

    pub fn renderSurface(self: *WaylandClient) RenderSurface {
        return .{
            .ctx = @ptrCast(&self.handles),
            .get_instance_proc_address = self.handles.get_instance_proc_address,
            .required_extensions_fn = waylandRequiredExtensions,
            .create_surface_fn = waylandCreateSurface,
            .framebuffer_size_fn = waylandFramebufferSize,
            .wait_events_fn = waylandWaitEvents,
            .time_seconds_fn = waylandTimeSeconds,
        };
    }

    /// Dispatch pending events. Returns false if the client should exit.
    pub fn dispatch(self: *WaylandClient) bool {
        if (self.display.dispatch() != .SUCCESS) return false;
        self.handles.setExtent(self.width, self.height);
        return self.running;
    }

    /// Flush outgoing requests.
    pub fn flush(self: *WaylandClient) void {
        _ = self.display.flush();
    }

    pub fn close(self: *WaylandClient) void {
        self.running = false;
    }

    pub fn shouldClose(self: *const WaylandClient) bool {
        return !self.running;
    }

    pub fn getFramebufferSize(self: *const WaylandClient) struct { width: i32, height: i32 } {
        return .{ .width = @intCast(self.width), .height = @intCast(self.height) };
    }

    pub fn timeSeconds(_: *const WaylandClient) f64 {
        return waylandTimeCb(null);
    }

    pub fn waitEvents(self: *WaylandClient) void {
        _ = self.display.flush();
        _ = self.display.dispatch();
        self.handles.setExtent(self.width, self.height);
    }

    pub fn waitEventsTimeout(self: *WaylandClient, timeout_s: f64) void {
        _ = self.display.flush();
        const timeout_ms: i32 = if (timeout_s <= 0) 0 else @intFromFloat(@max(timeout_s * 1000.0, 1.0));
        var pfds = [_]std.os.linux.pollfd{.{
            .fd = self.display.getFd(),
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};
        _ = std.os.linux.poll(&pfds, 1, timeout_ms);
        if (pfds[0].revents & std.os.linux.POLL.IN != 0) {
            _ = self.display.dispatch();
        } else {
            _ = self.display.dispatchPending();
        }
        self.handles.setExtent(self.width, self.height);
    }

    pub fn pollEvents(self: *WaylandClient) void {
        _ = self.display.dispatchPending();
        self.handles.setExtent(self.width, self.height);
    }

    pub fn postEmptyEvent(_: *WaylandClient) void {
        // Wayland has no GLFW-style process-wide empty event. The unified
        // backend will use a pipe/eventfd wakeup for resident runners.
    }

    pub fn pointerInputSnapshot(self: *WaylandClient) platform.PointerInputSnapshot {
        // Use sticky flags to avoid missing clicks where press+release arrive
        // in the same dispatch batch (the button_down field would already be
        // false by the time we snapshot).
        const left_down = self.left_button_down or self.left_pressed_sticky;
        const right_down = self.right_button_down or self.right_pressed_sticky;
        self.left_pressed_sticky = false;
        self.right_pressed_sticky = false;

        const snapshot = platform.PointerInputSnapshot{
            .x = self.pointer_x,
            .y = self.pointer_y,
            .left_down = left_down,
            .right_down = right_down,
            .scroll_dx = self.scroll_x,
            .scroll_dy = self.scroll_y,
            .mods = 0,
        };
        self.scroll_x = 0;
        self.scroll_y = 0;
        return snapshot;
    }

    pub fn isVisible(self: *const WaylandClient) bool {
        return self.visible;
    }

    /// Hide the surface by destroying the role and detaching the buffer.
    pub fn hide(self: *WaylandClient) void {
        if (!self.visible) return;
        self.visible = false;

        if (self.layer_surface) |ls| {
            ls.destroy();
            self.layer_surface = null;
        }
        if (self.xdg_toplevel) |tl| {
            tl.destroy();
            self.xdg_toplevel = null;
        }
        if (self.xdg_surface) |xs| {
            xs.destroy();
            self.xdg_surface = null;
        }
        if (self.surface) |sfc| {
            sfc.attach(null, 0, 0);
            sfc.commit();
            sfc.destroy();
            self.surface = null;
        }
        _ = self.display.flush();
    }

    /// Show the surface by recreating it with the original configuration.
    pub fn show(self: *WaylandClient) void {
        if (self.visible) return;
        self.visible = true;
        self.configured = false;

        self.surface = self.compositor.?.createSurface() catch return;
        switch (self.config.surface_kind) {
            .layer_shell => |opts| self.createLayerSurface(opts) catch return,
            .normal, .overlay, .popup_launcher => self.createXdgToplevel() catch return,
        }
        self.surface.?.commit();

        // Wait for configure before rendering
        while (!self.configured) {
            if (self.display.roundtrip() != .SUCCESS) return;
        }

        // Re-bind Vulkan surface handles
        self.handles.surface = @ptrCast(self.surface.?);
        self.handles.setExtent(self.width, self.height);

        _ = self.display.flush();
    }

    pub fn setVisibility(self: *WaylandClient, vis: bool) void {
        if (vis) self.show() else self.hide();
    }

    /// Pump key repeat: if a key is held and the repeat deadline has passed,
    /// re-fire the key and character events. Returns the ms until next repeat
    /// or null if no repeat is pending.
    pub fn pumpKeyRepeat(self: *WaylandClient) ?i32 {
        const rk = self.repeat_key orelse return null;
        if (self.repeat_rate <= 0) return null;

        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const now_ns: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);

        if (now_ns < self.repeat_deadline_ns) {
            const remaining_ms: i96 = @divTrunc(self.repeat_deadline_ns - now_ns, 1_000_000);
            return @intCast(@max(remaining_ms, 1));
        }

        // Fire repeat
        const glfw_key = evdevToGlfw(rk);
        if (self.key_queue_len < self.key_queue.len) {
            self.key_queue[self.key_queue_len] = .{ .key = glfw_key, .evdev_key = rk, .state = 2 }; // 2 = repeat
            self.key_queue_len += 1;
        }
        // Character repeat
        if (self.xkb_state) |_| {
            const keycode = rk + 8;
            var buf: [8]u8 = undefined;
            const xs = self.xkb_state;
            const n = xkb.xkb_state_key_get_utf8(xs, keycode, &buf, buf.len);
            if (n > 0) {
                const slice = buf[0..@intCast(n)];
                const cp = std.unicode.utf8Decode(slice) catch null;
                if (cp) |codepoint| {
                    if (codepoint >= 0x20 and codepoint != 0x7F) {
                        if (self.char_queue_len < self.char_queue.len) {
                            self.char_queue[self.char_queue_len] = .{ .codepoint = @intCast(codepoint) };
                            self.char_queue_len += 1;
                        }
                    }
                }
            }
        }
        if (self.on_key) |cb| cb(rk, 2);

        // Schedule next repeat
        const interval_ns: i96 = @divTrunc(1_000_000_000, @as(i96, self.repeat_rate));
        self.repeat_deadline_ns = now_ns + interval_ns;

        const next_ms: i96 = @divTrunc(interval_ns, 1_000_000);
        return @intCast(@max(next_ms, 1));
    }

    pub fn setCursor(self: *WaylandClient, name: [*:0]const u8) void {
        if (self.current_cursor_name == name) return;
        self.current_cursor_name = name;

        const theme = self.cursor_theme orelse return;
        const cursor_surface = self.cursor_surface orelse return;
        const ptr = self.pointer orelse return;

        const cursor = theme.getCursor(name) orelse theme.getCursor("default") orelse return;
        if (cursor.image_count == 0) return;
        const image = cursor.images[0];
        const buffer = wl.CursorImage.getBuffer(image) catch return;

        cursor_surface.attach(buffer, 0, 0);
        cursor_surface.damage(0, 0, @intCast(image.width), @intCast(image.height));
        cursor_surface.commit();
        ptr.setCursor(self.pointer_serial, cursor_surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    }

    // --- Surface creation ---

    fn createLayerSurface(self: *WaylandClient, opts: platform.LayerShellOptions) !void {
        const ls = self.layer_shell.?;
        const sfc = self.surface.?;

        const layer: zwlr.LayerShellV1.Layer = switch (opts.layer) {
            .background => .background,
            .bottom => .bottom,
            .top => .top,
            .overlay => .overlay,
        };

        // namespace must be sentinel-terminated for the Wayland protocol
        const ns: [*:0]const u8 = @ptrCast(opts.namespace.ptr);
        const layer_surface = try ls.getLayerSurface(sfc, null, layer, ns);
        self.layer_surface = layer_surface;

        layer_surface.setListener(*WaylandClient, layerSurfaceListener, self);

        // Size — 0 means let compositor decide (must anchor opposite edges)
        layer_surface.setSize(self.width, self.height);

        // Anchors
        var anchor: zwlr.LayerSurfaceV1.Anchor = .{};
        if (opts.anchors.top) anchor.top = true;
        if (opts.anchors.bottom) anchor.bottom = true;
        if (opts.anchors.left) anchor.left = true;
        if (opts.anchors.right) anchor.right = true;
        layer_surface.setAnchor(anchor);

        // Exclusive zone
        layer_surface.setExclusiveZone(opts.exclusive_zone);

        // Margin
        layer_surface.setMargin(opts.margin.top, opts.margin.right, opts.margin.bottom, opts.margin.left);

        // Keyboard interactivity
        const kb: zwlr.LayerSurfaceV1.KeyboardInteractivity = switch (opts.keyboard_interactivity) {
            .none => .none,
            .exclusive => .exclusive,
            .on_demand => .on_demand,
        };
        layer_surface.setKeyboardInteractivity(kb);
    }

    fn createXdgToplevel(self: *WaylandClient) !void {
        const wm_base = self.wm_base.?;
        wm_base.setListener(*WaylandClient, wmBaseListener, self);

        const xdg_surface = try wm_base.getXdgSurface(self.surface.?);
        self.xdg_surface = xdg_surface;
        xdg_surface.setListener(*WaylandClient, xdgSurfaceListener, self);

        const toplevel = try xdg_surface.getToplevel();
        self.xdg_toplevel = toplevel;
        toplevel.setListener(*WaylandClient, toplevelListener, self);
        toplevel.setTitle(self.config.title);
    }

    // --- Wayland listeners ---

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *WaylandClient) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    self.compositor = registry.bind(global.name, wl.Compositor, 6) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    self.wm_base = registry.bind(global.name, xdg.WmBase, 6) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    self.seat = registry.bind(global.name, wl.Seat, 9) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                    self.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                    self.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 5) catch return;
                }
            },
            .global_remove => {},
        }
    }

    fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *WaylandClient) void {
        switch (event) {
            .ping => |ping| wm_base.pong(ping.serial),
        }
    }

    fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *WaylandClient) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                self.configured = true;
                if (self.surface) |sfc| sfc.commit();
            },
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *WaylandClient) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width > 0) self.width = @intCast(configure.width);
                if (configure.height > 0) self.height = @intCast(configure.height);
                if (self.on_configure) |cb| cb(self.width, self.height);
            },
            .close => self.running = false,
            else => {},
        }
    }

    fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *WaylandClient) void {
        switch (event) {
            .configure => |configure| {
                if (configure.width > 0) self.width = configure.width;
                if (configure.height > 0) self.height = configure.height;
                layer_surface.ackConfigure(configure.serial);
                self.configured = true;
                if (self.surface) |sfc| sfc.commit();
                if (self.on_configure) |cb| cb(self.width, self.height);
            },
            .closed => self.running = false,
        }
    }

    fn seatListener(_: *wl.Seat, event: wl.Seat.Event, self: *WaylandClient) void {
        switch (event) {
            .capabilities => |caps| {
                if (caps.capabilities.keyboard and self.keyboard == null) {
                    self.keyboard = self.seat.?.getKeyboard() catch return;
                    self.keyboard.?.setListener(*WaylandClient, keyboardListener, self);
                }
                if (caps.capabilities.pointer and self.pointer == null) {
                    self.pointer = self.seat.?.getPointer() catch return;
                    self.pointer.?.setListener(*WaylandClient, pointerListener, self);
                }
            },
            .name => {},
        }
    }

    fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *WaylandClient) void {
        switch (event) {
            .keymap => |keymap_ev| {
                if (keymap_ev.format != .xkb_v1) return;
                const map_shm = std.posix.mmap(
                    null,
                    keymap_ev.size,
                    .{ .READ = true },
                    .{ .TYPE = .SHARED },
                    keymap_ev.fd,
                    0,
                ) catch return;
                defer std.posix.munmap(map_shm);

                if (self.xkb_context == null)
                    self.xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);
                const ctx = self.xkb_context orelse return;

                if (self.xkb_state) |s| xkb.xkb_state_unref(s);
                if (self.xkb_keymap) |k| xkb.xkb_keymap_unref(k);

                self.xkb_keymap = xkb.xkb_keymap_new_from_buffer(
                    ctx,
                    @ptrCast(map_shm.ptr),
                    keymap_ev.size - 1,
                    xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
                    xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
                );
                if (self.xkb_keymap) |km|
                    self.xkb_state = xkb.xkb_state_new(km);
            },
            .key => |key| {
                const evdev_key = key.key;
                // Map evdev scancode to GLFW-like keycode
                const glfw_key = evdevToGlfw(evdev_key);
                const state_val: u32 = @intCast(@intFromEnum(key.state));

                // Queue key event
                if (self.key_queue_len < self.key_queue.len) {
                    self.key_queue[self.key_queue_len] = .{ .key = glfw_key, .evdev_key = evdev_key, .state = state_val };
                    self.key_queue_len += 1;
                }

                // On press/repeat, try xkb character translation
                if (state_val == 1) {
                    if (self.xkb_state) |xs| {
                        const keycode = evdev_key + 8; // evdev → xkb offset
                        const sym = xkb.xkb_state_key_get_one_sym(xs, keycode);
                        var buf: [8]u8 = undefined;
                        const n = xkb.xkb_state_key_get_utf8(xs, keycode, &buf, buf.len);
                        if (n > 0) {
                            // Decode first UTF-8 codepoint
                            const slice = buf[0..@intCast(n)];
                            const cp = std.unicode.utf8Decode(slice) catch null;
                            if (cp) |codepoint| {
                                // Filter control characters
                                if (codepoint >= 0x20 and codepoint != 0x7F) {
                                    if (self.char_queue_len < self.char_queue.len) {
                                        self.char_queue[self.char_queue_len] = .{ .codepoint = @intCast(codepoint) };
                                        self.char_queue_len += 1;
                                    }
                                }
                            }
                        }
                        _ = sym;
                    }
                }

                // Set up key repeat on press, cancel on release
                if (state_val == 1 and self.repeat_rate > 0) {
                    self.repeat_key = evdev_key;
                    var ts: std.os.linux.timespec = undefined;
                    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                    const now_ns: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
                    self.repeat_deadline_ns = now_ns + @as(i96, self.repeat_delay) * 1_000_000;
                } else if (state_val == 0) {
                    if (self.repeat_key) |rk| {
                        if (rk == evdev_key) self.repeat_key = null;
                    }
                }

                if (self.on_key) |cb| cb(evdev_key, state_val);
            },
            .modifiers => |mods| {
                if (self.xkb_state) |xs| {
                    _ = xkb.xkb_state_update_mask(
                        xs,
                        mods.mods_depressed,
                        mods.mods_latched,
                        mods.mods_locked,
                        0,
                        0,
                        mods.group,
                    );
                }
            },
            .repeat_info => |info| {
                self.repeat_rate = info.rate;
                self.repeat_delay = info.delay;
            },
            else => {},
        }
    }

    /// Map Linux evdev scancodes to GLFW-compatible keycodes.
    fn evdevToGlfw(evdev: u32) u32 {
        return switch (evdev) {
            1 => 256,   // ESC -> GLFW_KEY_ESCAPE
            14 => 259,  // BACKSPACE
            15 => 258,  // TAB
            28 => 257,  // ENTER
            103 => 265, // UP
            108 => 264, // DOWN
            105 => 263, // LEFT
            106 => 262, // RIGHT
            110 => 268, // HOME
            111 => 269, // END (actually DELETE on some keyboards)
            119 => 261, // DELETE
            else => evdev + 8,
        };
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *WaylandClient) void {
        switch (event) {
            .enter => |enter| {
                self.pointer_serial = enter.serial;
                self.pointer_x = enter.surface_x.toDouble();
                self.pointer_y = enter.surface_y.toDouble();
                self.setCursor("default");
            },
            .leave => {
                // Move pointer off-screen so hover detection clears
                self.pointer_x = -1;
                self.pointer_y = -1;
                self.left_button_down = false;
                self.right_button_down = false;
                self.left_pressed_sticky = false;
                self.right_pressed_sticky = false;
                self.current_cursor_name = null;
            },
            .motion => |motion| {
                self.pointer_x = motion.surface_x.toDouble();
                self.pointer_y = motion.surface_y.toDouble();
                if (self.on_pointer_motion) |cb| cb(self.pointer_x, self.pointer_y);
            },
            .button => |button| {
                self.pointer_button = button.button;
                const pressed = @intFromEnum(button.state) == 1; // WL_POINTER_BUTTON_STATE_PRESSED
                if (button.button == 0x110) { // BTN_LEFT
                    self.left_button_down = pressed;
                    if (pressed) self.left_pressed_sticky = true;
                }
                if (button.button == 0x111) { // BTN_RIGHT
                    self.right_button_down = pressed;
                    if (pressed) self.right_pressed_sticky = true;
                }
                if (self.on_pointer_button) |cb| cb(button.button, @as(u32, @intCast(@intFromEnum(button.state))));
            },
            .axis => |axis| {
                const val = axis.value.toDouble();
                switch (axis.axis) {
                    .vertical_scroll => self.scroll_y += val,
                    .horizontal_scroll => self.scroll_x += val,
                    _ => {},
                }
                if (self.on_scroll) |cb| cb(self.scroll_x, self.scroll_y);
            },
            else => {},
        }
    }

    // --- Vulkan surface adapter ---

    fn waylandRequiredExtensions(_: *anyopaque) !RequiredExtensions {
        return .{ .names = &wayland_extensions, .count = wayland_extensions.len };
    }

    fn waylandCreateSurface(ctx: *anyopaque, instance: vk.Instance, vki: *const vk.InstanceWrapper) !vk.SurfaceKHR {
        const handles: *WaylandSurfaceHandles = @ptrCast(@alignCast(ctx));
        const create_info = vk.WaylandSurfaceCreateInfoKHR{
            .display = handles.display,
            .surface = handles.surface,
        };
        return vki.createWaylandSurfaceKHR(instance, &create_info, null);
    }

    fn waylandFramebufferSize(ctx: *anyopaque) vk.Extent2D {
        const handles: *WaylandSurfaceHandles = @ptrCast(@alignCast(ctx));
        return .{ .width = handles.width, .height = handles.height };
    }

    fn waylandWaitEvents(ctx: *anyopaque) void {
        const handles: *WaylandSurfaceHandles = @ptrCast(@alignCast(ctx));
        if (handles.wait_events) |wait| wait(handles.user_ctx);
    }

    fn waylandTimeSeconds(ctx: *anyopaque) f64 {
        const handles: *WaylandSurfaceHandles = @ptrCast(@alignCast(ctx));
        if (handles.time_seconds) |now| return now(handles.user_ctx);
        return 0;
    }

    // --- Vulkan loader ---

    var vk_lib: ?std.DynLib = null;

    const VkProcFn = ?*const fn () callconv(.c) void;
    const VkGetProcFn = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) VkProcFn;
    var vk_get_proc: ?VkGetProcFn = null;

    fn vkGetInstanceProcAddrLoader(instance: ?*anyopaque, procname: [*:0]const u8) callconv(.c) VkProcFn {
        if (vk_get_proc) |proc| return proc(instance, procname);
        vk_lib = std.DynLib.open("libvulkan.so.1") catch return null;
        vk_get_proc = vk_lib.?.lookup(VkGetProcFn, "vkGetInstanceProcAddr");
        if (vk_get_proc) |proc| return proc(instance, procname);
        return null;
    }

    fn waylandWaitCb(ctx: ?*anyopaque) void {
        const display: *wl.Display = @ptrCast(@alignCast(ctx.?));
        _ = display.dispatch();
    }

    pub fn waylandTimeCb(_: ?*anyopaque) f64 {
        var ts: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        if (rc != 0) return 0;
        return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
    }
};
