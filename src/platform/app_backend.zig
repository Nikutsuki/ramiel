//! Unified application backend wrapper.
//!
//! This is the transition seam for moving `Application` from storing a GLFW
//! `WindowContext` directly to storing one backend value. It intentionally wraps
//! the existing GLFW window implementation and the native Wayland client without
//! changing either call site all at once.

const std = @import("std");
const build_options = @import("build_options");
const platform = @import("backend.zig");
const glfw = @import("glfw");
const RenderSurface = @import("../renderer/vulkan/surface.zig").RenderSurface;
const window_mod = @import("../window/window.zig");
const WindowContext = window_mod.WindowContext;
const wayland_backend = if (build_options.native_wayland) @import("wayland_backend.zig") else struct {};

pub const MonitorWorkarea = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Backend = union(platform.BackendKind) {
    glfw: WindowContext,
    wayland: if (build_options.native_wayland) wayland_backend.WaylandClient else void,

    pub fn init(allocator: std.mem.Allocator, config: platform.AppBackendConfig) !Backend {
        switch (config.backend) {
            .glfw => return .{ .glfw = try window_mod.initWindow(allocator, config) },
            .wayland => {
                if (!build_options.native_wayland) return error.UnsupportedBackend;
                var client = wayland_backend.WaylandClient.init(wayland_backend.Config.fromBackendConfig(config));
                try client.setup();
                return .{ .wayland = client };
            },
        }
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.deinit(),
            .wayland => |*client| if (build_options.native_wayland) client.deinit(),
        }
    }

    pub fn kind(self: *const Backend) platform.BackendKind {
        return self.*;
    }

    pub fn renderSurface(self: *Backend) RenderSurface {
        return switch (self.*) {
            .glfw => |*win| win.renderSurface(),
            .wayland => |*client| if (build_options.native_wayland) client.renderSurface() else unreachable,
        };
    }

    pub fn show(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.show(),
            .wayland => |*client| if (build_options.native_wayland) client.show(),
        }
    }

    pub fn hide(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.hide(),
            .wayland => |*client| if (build_options.native_wayland) client.hide(),
        }
    }

    pub fn isVisible(self: *const Backend) bool {
        return switch (self.*) {
            .glfw => |*win| win.isVisible(),
            .wayland => |*client| if (build_options.native_wayland) client.isVisible() else false,
        };
    }

    pub fn inputRegionMode(self: *const Backend) platform.InputRegionMode {
        return switch (self.*) {
            .glfw => .default,
            .wayland => |*client| if (build_options.native_wayland) client.inputRegionMode() else .default,
        };
    }

    pub fn setInputRegion(self: *Backend, rects: []const platform.InputRegionRect) void {
        switch (self.*) {
            .glfw => {},
            .wayland => |*client| if (build_options.native_wayland) client.setInputRegion(rects),
        }
    }

    pub fn setKeyboardInteractivity(self: *Backend, mode: platform.KeyboardInteractivity) void {
        switch (self.*) {
            .glfw => {},
            .wayland => |*client| if (build_options.native_wayland) client.setKeyboardInteractivity(mode),
        }
    }

    pub fn shouldClose(self: *const Backend) bool {
        return switch (self.*) {
            .glfw => |*win| win.shouldClose(),
            .wayland => |*client| if (build_options.native_wayland) client.shouldClose() else true,
        };
    }

    pub fn pollEvents(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.pollEvents(),
            .wayland => |*client| if (build_options.native_wayland) client.pollEvents(),
        }
    }

    pub fn waitEvents(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.waitEvents(),
            .wayland => |*client| if (build_options.native_wayland) client.waitEvents(),
        }
    }

    pub fn waitEventsTimeout(self: *Backend, timeout_s: f64) void {
        switch (self.*) {
            .glfw => |*win| win.waitEventsTimeout(timeout_s),
            .wayland => |*client| if (build_options.native_wayland) {
                client.waitEventsTimeout(timeout_s);
            },
        }
    }

    pub fn postEmptyEvent(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.postEmptyEvent(),
            .wayland => |*client| if (build_options.native_wayland) client.postEmptyEvent(),
        }
    }

    pub fn timeSeconds(self: *const Backend) f64 {
        return switch (self.*) {
            .glfw => |*win| win.timeSeconds(),
            .wayland => |*client| if (build_options.native_wayland) client.timeSeconds() else 0,
        };
    }

    pub fn getFramebufferSize(self: *const Backend) platform.FramebufferSize {
        return switch (self.*) {
            .glfw => |*win| blk: {
                const fb = win.getFramebufferSize();
                break :blk .{ .width = fb.width, .height = fb.height };
            },
            .wayland => |*client| if (build_options.native_wayland) blk: {
                const fb = client.getFramebufferSize();
                break :blk .{ .width = fb.width, .height = fb.height };
            } else .{ .width = 0, .height = 0 },
        };
    }

    pub fn primaryRefreshRateHz(self: *const Backend) ?f64 {
        return switch (self.*) {
            .glfw => |*win| win.primaryRefreshRateHz(),
            .wayland => null,
        };
    }

    pub fn getCursorPos(self: *const Backend) platform.CursorPosition {
        return switch (self.*) {
            .glfw => |*win| blk: {
                const pos = win.getCursorPos();
                break :blk .{ .x = pos.x, .y = pos.y };
            },
            .wayland => |*client| if (build_options.native_wayland) .{ .x = client.pointer_x, .y = client.pointer_y } else .{ .x = 0, .y = 0 },
        };
    }

    pub fn isMouseButtonDown(self: *const Backend, button: i32) bool {
        return switch (self.*) {
            .glfw => |*win| win.isMouseButtonDown(button),
            .wayland => |*client| if (build_options.native_wayland) switch (button) {
                0 => client.left_button_down,
                1 => client.right_button_down,
                else => false,
            } else false,
        };
    }

    pub fn isKeyDown(self: *const Backend, key: i32) bool {
        return switch (self.*) {
            .glfw => |*win| win.isKeyDown(key),
            .wayland => false or key == -1,
        };
    }

    pub fn configureAsOverlay(self: *Backend) void {
        switch (self.*) {
            .glfw => |*win| win.configureAsOverlay(),
            .wayland => {},
        }
    }

    pub fn pointerInputSnapshot(self: *Backend) platform.PointerInputSnapshot {
        return switch (self.*) {
            .glfw => |*win| win.pointerInputSnapshot(),
            .wayland => |*client| if (build_options.native_wayland) client.pointerInputSnapshot() else .{},
        };
    }

    pub fn drainQueuedInputEvents(
        self: *Backend,
        comptime MessageT: type,
        root: *@import("../ui/node.zig").Node(MessageT),
        registry: *@import("../ui/interaction.zig").InteractionRegistry(MessageT),
        raw_key_handler: ?*const fn (key: u32, state: u32) void,
    ) void {
        switch (self.*) {
            .glfw => {},
            .wayland => |*client| if (build_options.native_wayland) {
                _ = client.pumpKeyRepeat();
                for (client.key_queue[0..client.key_queue_len]) |kev| {
                    var is_ctrl = false;
                    var is_shift = false;
                    if (client.xkb_state) |xs| {
                        is_ctrl = wayland_backend.xkb.xkb_state_mod_name_is_active(xs, "Control", wayland_backend.xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
                        is_shift = wayland_backend.xkb.xkb_state_mod_name_is_active(xs, "Shift", wayland_backend.xkb.XKB_STATE_MODS_EFFECTIVE) == 1;
                    }
                    if (raw_key_handler) |handler| handler(kev.evdev_key, kev.state);
                    registry.pushKey(root, @intCast(kev.key), @intCast(kev.state), is_ctrl, is_shift);
                }
                client.key_queue_len = 0;

                for (client.char_queue[0..client.char_queue_len]) |cev| {
                    registry.pushChar(cev.codepoint);
                }
                client.char_queue_len = 0;
            },
        }
    }

    pub fn getClipboardString(self: *const Backend) ?[:0]const u8 {
        return switch (self.*) {
            .glfw => |*win| win.getClipboardString(),
            .wayland => null, // TODO: wl_data_device clipboard
        };
    }

    pub fn setClipboardString(self: *Backend, str: [:0]const u8) void {
        switch (self.*) {
            .glfw => |*win| win.setClipboardString(str),
            .wayland => {}, // TODO: wl_data_device clipboard
        }
    }

    /// Re-register Wayland listeners after the Backend has been moved to its
    /// final memory location. No-op for GLFW.
    pub fn rebindListeners(self: *Backend) void {
        switch (self.*) {
            .glfw => {},
            .wayland => |*client| if (build_options.native_wayland) client.rebindListeners(),
        }
    }

    pub fn registerCallbacks(self: *Backend, user_ptr: *anyopaque, on_key: *const fn (*anyopaque, i32, i32) void, on_char: *const fn (*anyopaque, u21) void, on_resize: *const fn (*anyopaque) void) void {
        switch (self.*) {
            .glfw => |*win| win.registerCallbacks(user_ptr, on_key, on_char, on_resize),
            .wayland => {}, // Wayland uses queue-draining instead of callbacks
        }
    }

    pub fn registerGlobalHotkey(self: *Backend, modifier: u32, key: u32, user_ptr: ?*anyopaque, callback: @import("../window/window.zig").HotkeyFn) !void {
        return switch (self.*) {
            .glfw => |*win| win.registerGlobalHotkey(modifier, key, user_ptr, callback),
            .wayland => error.Unsupported,
        };
    }

    pub fn setCursor(self: *Backend, cursor: @import("../ui/layout.zig").Cursor) void {
        switch (self.*) {
            .glfw => |*win| win.setCursor(cursor),
            .wayland => |*client| if (build_options.native_wayland) {
                const name: [*:0]const u8 = switch (cursor) {
                    .default => "default",
                    .pointer => "pointer",
                    .text => "text",
                    .crosshair => "crosshair",
                    .ns_resize => "ns-resize",
                    .ew_resize => "ew-resize",
                };
                client.setCursor(name);
            },
        }
    }

    pub fn setCursorPos(self: *Backend, x: f64, y: f64) void {
        switch (self.*) {
            .glfw => |*win| win.setCursorPos(x, y),
            .wayland => {},
        }
    }

    pub fn setCursorModeDisabled(self: *Backend, disabled: bool) void {
        switch (self.*) {
            .glfw => |*win| win.setCursorModeDisabled(disabled),
            .wayland => {},
        }
    }

    /// Returns the primary monitor's workarea if the backend exposes one. Native
    /// Wayland does not allow programmatic positioning, so returns null there.
    pub fn primaryMonitorWorkarea(self: *const Backend) ?MonitorWorkarea {
        return switch (self.*) {
            .glfw => blk: {
                const mon = glfw.getPrimaryMonitor();
                var x: c_int = 0;
                var y: c_int = 0;
                var w: c_int = 0;
                var h: c_int = 0;
                glfw.getMonitorWorkarea(mon, &x, &y, &w, &h);
                break :blk .{ .x = x, .y = y, .width = w, .height = h };
            },
            .wayland => null,
        };
    }

    /// Position the toplevel window. No-op on backends that do not support
    /// programmatic positioning (e.g. native Wayland).
    pub fn setPosition(self: *Backend, x: i32, y: i32) void {
        switch (self.*) {
            .glfw => |*win| glfw.setWindowPos(win.window, x, y),
            .wayland => {},
        }
    }

    /// Center the window of the given size on the primary monitor's workarea.
    /// No-op on backends without programmatic positioning.
    pub fn centerOnPrimaryMonitor(self: *Backend, width: u32, height: u32) void {
        const area = self.primaryMonitorWorkarea() orelse return;
        const w_i: i32 = @intCast(width);
        const h_i: i32 = @intCast(height);
        self.setPosition(
            area.x + @divTrunc(area.width - w_i, 2),
            area.y + @divTrunc(area.height - h_i, 2),
        );
    }

    /// Escape hatch: returns the underlying GLFW `*glfw.Window` when the GLFW
    /// backend is active. The renderer needs this for DXGI transparent
    /// composition on Windows. Avoid using this from application code; prefer
    /// the neutral methods on `Backend` and add new ones if necessary.
    pub fn nativeGlfwWindow(self: *Backend) ?*glfw.Window {
        return switch (self.*) {
            .glfw => |*win| win.window,
            .wayland => null,
        };
    }
};
