//! X11-specific backend helpers used by the current GLFW platform path.
//!
//! This module is the migration seam for moving Linux/X11 native operations out
//! of `src/window/window.zig` while preserving existing behavior. It wraps the
//! lower-level declarations in `src/window/x11_native.zig` behind names that are
//! backend-oriented rather than window-module-oriented.

const builtin = @import("builtin");

pub const available = builtin.os.tag == .linux;

const native = if (available) @import("../window/x11_native.zig") else struct {};

pub const Display = if (available) native.Display else opaque {};
pub const XEvent = if (available) native.XEvent else opaque {};
pub const XKeyEvent = if (available) native.XKeyEvent else opaque {};

pub const KeyPress = if (available) native.KeyPress else 2;
pub const KeyPressMask = if (available) native.KeyPressMask else 0;
pub const GrabModeAsync = if (available) native.GrabModeAsync else 1;
pub const LockMask = if (available) native.LockMask else 0;
pub const Mod2Mask = if (available) native.Mod2Mask else 0;

pub fn configureAsOverlay(dpy: *Display, window: c_ulong) void {
    if (!available) return;
    native.configureAsOverlay(dpy, window);
}

pub fn openDisplay() ?*Display {
    if (!available) return null;
    return native.XOpenDisplay(null);
}

pub fn closeDisplay(dpy: *Display) c_int {
    if (!available) return 0;
    return native.XCloseDisplay(dpy);
}

pub fn keysymForVirtualKey(key: u32) c_ulong {
    if (!available) return 0;
    return native.vkToKeysym(key);
}

pub fn modifiersForHotkey(modifier: u32) c_uint {
    if (!available) return 0;
    return native.modToX11(modifier);
}

pub fn keysymToKeycode(dpy: *Display, keysym: c_ulong) c_uint {
    if (!available) return 0;
    return native.XKeysymToKeycode(dpy, keysym);
}

pub fn defaultRootWindow(dpy: *Display) c_ulong {
    if (!available) return 0;
    return native.XDefaultRootWindow(dpy);
}

pub fn grabKey(dpy: *Display, keycode: c_int, mods: c_uint, root: c_ulong) void {
    if (!available) return;
    _ = native.XGrabKey(dpy, keycode, mods, root, 0, native.GrabModeAsync, native.GrabModeAsync);
}

pub fn selectRootKeyPress(dpy: *Display, root: c_ulong) void {
    if (!available) return;
    _ = native.XSelectInput(dpy, root, native.KeyPressMask);
}

pub fn sync(dpy: *Display) void {
    if (!available) return;
    _ = native.XSync(dpy, 0);
}

pub fn pending(dpy: *Display) c_int {
    if (!available) return 0;
    return native.XPending(dpy);
}

pub fn nextEvent(dpy: *Display, ev: *XEvent) void {
    if (!available) return;
    _ = native.XNextEvent(dpy, ev);
}
