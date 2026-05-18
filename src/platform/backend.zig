//! Shared platform capability/configuration types.
//!
//! This module intentionally contains backend-neutral platform configuration
//! and validation types. Concrete GLFW/Wayland implementations live in sibling
//! modules and construct renderer surfaces from these shared roles.

const std = @import("std");

pub const BackendKind = enum {
    /// Existing GLFW path. On Linux this is X11/XWayland-oriented today.
    glfw,

    /// Future native Wayland path using xdg-shell/layer-shell directly.
    wayland,
};

pub const Insets = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
};

pub const Anchors = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,

    pub fn any(self: Anchors) bool {
        return self.top or self.right or self.bottom or self.left;
    }
};

pub const Layer = enum {
    background,
    bottom,
    top,
    overlay,
};

pub const KeyboardInteractivity = enum {
    none,
    exclusive,
    on_demand,
};

pub const LayerShellOptions = struct {
    layer: Layer = .top,
    anchors: Anchors = .{},
    exclusive_zone: i32 = -1,
    margin: Insets = .{},
    keyboard_interactivity: KeyboardInteractivity = .none,
    namespace: []const u8 = "ramiel",
};

pub const PopupLauncherOptions = struct {
    /// If true, show/focus should target the first text input when the backend
    /// receives an activation request.
    focus_search_on_show: bool = true,

    /// Hide the launcher when it loses focus, where the compositor/backend can
    /// report that reliably.
    hide_on_focus_loss: bool = true,
};

pub const SurfaceKind = union(enum) {
    /// Normal toplevel application window.
    normal,

    /// Legacy overlay intent: taskbar skip/topmost/transparent where supported.
    overlay,

    /// Native layer-shell role for bars/panels/wallpaper widgets.
    layer_shell: LayerShellOptions,

    /// Hidden/resident app-runner surface that is activated by IPC/compositor
    /// keybinds rather than by in-process global shortcuts.
    popup_launcher: PopupLauncherOptions,
};

pub const FramebufferSize = struct { width: i32, height: i32 };
pub const CursorPosition = struct { x: f64, y: f64 };

pub const PointerInputSnapshot = struct {
    x: f64 = 0,
    y: f64 = 0,
    left_down: bool = false,
    right_down: bool = false,
    scroll_dx: f64 = 0,
    scroll_dy: f64 = 0,
    mods: i32 = 0,
};

pub const AppBackendConfig = struct {
    backend: BackendKind = .glfw,
    surface_kind: SurfaceKind = .normal,
    width: u32 = 800,
    height: u32 = 600,
    title: [:0]const u8 = "Ramiel",
    transparent: bool = false,
    borderless: bool = false,
    topmost: bool = false,
    visible_on_start: bool = true,
};

pub fn waylandLayerShell(options: LayerShellOptions) AppBackendConfig {
    return .{
        .backend = .wayland,
        .surface_kind = .{ .layer_shell = options },
        .transparent = true,
        .borderless = true,
    };
}

pub fn popupLauncher(options: PopupLauncherOptions) AppBackendConfig {
    return .{
        .backend = .wayland,
        .surface_kind = .{ .popup_launcher = options },
        .transparent = true,
        .borderless = true,
        .visible_on_start = false,
    };
}

pub const ActivationRequest = union(enum) {
    show,
    hide,
    toggle,
    focus_search,
    custom: []const u8,
};

pub fn surfaceKindRequiresNativeWayland(kind: SurfaceKind) bool {
    return switch (kind) {
        .layer_shell => true,
        .normal, .overlay, .popup_launcher => false,
    };
}

pub fn validateSurfaceKind(kind: SurfaceKind) !void {
    switch (kind) {
        .layer_shell => |opts| {
            if (!opts.anchors.any()) return error.LayerShellRequiresAnchor;
            if (opts.namespace.len == 0) return error.LayerShellRequiresNamespace;
        },
        else => {},
    }
}

test "layer shell surface validation" {
    try std.testing.expectError(error.LayerShellRequiresAnchor, validateSurfaceKind(.{ .layer_shell = .{} }));
    try validateSurfaceKind(.{ .layer_shell = .{ .anchors = .{ .top = true } } });
}
