//! Unified application backend wrapper.
//!
//! This is the transition seam for moving `Application` from storing a GLFW
//! `WindowContext` directly to storing one backend value. It intentionally wraps
//! the existing GLFW window implementation and the native Wayland client without
//! changing either call site all at once.

const std = @import("std");
const build_options = @import("build_options");
const platform = @import("backend.zig");
const RenderSurface = @import("../renderer/vulkan/surface.zig").RenderSurface;
const WindowContext = @import("../window/window.zig").WindowContext;
const WindowConfig = @import("../window/window.zig").WindowConfig;
const wayland_backend = if (build_options.native_wayland) @import("wayland_backend.zig") else struct {};

pub const Backend = union(platform.BackendKind) {
    glfw: WindowContext,
    wayland: if (build_options.native_wayland) wayland_backend.WaylandClient else void,

    pub fn initWindowConfig(allocator: std.mem.Allocator, config: WindowConfig) !Backend {
        return init(allocator, .{
            .backend = config.backend,
            .surface_kind = config.surface_kind,
            .width = @intCast(config.width),
            .height = @intCast(config.height),
            .title = config.title,
            .transparent = config.transparent,
            .borderless = config.borderless,
            .topmost = config.topmost,
            .visible_on_start = config.visible_on_start,
        });
    }

    pub fn init(allocator: std.mem.Allocator, config: platform.AppBackendConfig) !Backend {
        switch (config.backend) {
            .glfw => {
                const win_config = WindowConfig.fromBackendConfig(config);
                return .{ .glfw = try @import("../window/window.zig").initWindow(allocator, win_config) };
            },
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

    pub fn setCursorForHoveredNode(self: *Backend, hovered_node: anytype) void {
        switch (self.*) {
            .glfw => {},
            .wayland => |*client| if (build_options.native_wayland) {
                const cursor_name: [*:0]const u8 = if (hovered_node) |node| blk: {
                    const c = node.style.cursor orelse break :blk @as([*:0]const u8, "default");
                    break :blk switch (c) {
                        .default => "default",
                        .pointer => "pointer",
                        .text => "text",
                        .crosshair => "crosshair",
                        .ns_resize => "ns-resize",
                        .ew_resize => "ew-resize",
                    };
                } else "default";
                client.setCursor(cursor_name);
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

    pub fn glfwWindow(self: *Backend) ?*WindowContext {
        return switch (self.*) {
            .glfw => |*win| win,
            .wayland => null,
        };
    }
};
