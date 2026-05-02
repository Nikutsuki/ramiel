// Xlib bindings for overlay window state and global hotkeys; mirrors win32.zig.

const std = @import("std");

pub const Display = opaque {};
pub const XID = c_ulong;
pub const Window = XID;
pub const Atom = XID;
pub const KeySym = XID;
pub const KeyCode = u8;
pub const Bool = c_int;
pub const Status = c_int;

pub const KeyPressMask: c_long = 1 << 0;
pub const KeyReleaseMask: c_long = 1 << 1;
pub const SubstructureNotifyMask: c_long = 1 << 19;
pub const SubstructureRedirectMask: c_long = 1 << 20;

pub const ShiftMask: c_uint = 1 << 0;
pub const LockMask: c_uint = 1 << 1;
pub const ControlMask: c_uint = 1 << 2;
pub const Mod1Mask: c_uint = 1 << 3; // Alt
pub const Mod2Mask: c_uint = 1 << 4; // NumLock typically
pub const Mod4Mask: c_uint = 1 << 6; // Super/Win

pub const GrabModeSync: c_int = 0;
pub const GrabModeAsync: c_int = 1;

pub const PropModeReplace: c_int = 0;
pub const PropModeAppend: c_int = 2;

pub const XA_ATOM: Atom = 4;

pub const KeyPress: c_int = 2;
pub const KeyRelease: c_int = 3;
pub const ClientMessage: c_int = 33;

// XEvent is a 24*sizeof(long) buffer in Xlib.
pub const XEvent = extern union {
    type: c_int,
    pad: [24]c_long,
};

pub const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

pub extern "X11" fn XOpenDisplay(display_name: ?[*:0]const u8) ?*Display;
pub extern "X11" fn XCloseDisplay(display: *Display) c_int;
pub extern "X11" fn XDefaultScreen(display: *Display) c_int;
pub extern "X11" fn XRootWindow(display: *Display, screen_number: c_int) Window;
pub fn XDefaultRootWindow(display: *Display) Window {
    return XRootWindow(display, XDefaultScreen(display));
}
pub extern "X11" fn XInternAtom(display: *Display, atom_name: [*:0]const u8, only_if_exists: Bool) Atom;
pub extern "X11" fn XChangeProperty(
    display: *Display,
    window: Window,
    property: Atom,
    type_: Atom,
    format: c_int,
    mode: c_int,
    data: [*]const u8,
    nelements: c_int,
) c_int;
pub extern "X11" fn XGrabKey(
    display: *Display,
    keycode: c_int,
    modifiers: c_uint,
    grab_window: Window,
    owner_events: Bool,
    pointer_mode: c_int,
    keyboard_mode: c_int,
) c_int;
pub extern "X11" fn XUngrabKey(
    display: *Display,
    keycode: c_int,
    modifiers: c_uint,
    grab_window: Window,
) c_int;
pub extern "X11" fn XKeysymToKeycode(display: *Display, keysym: KeySym) KeyCode;
pub extern "X11" fn XSelectInput(display: *Display, window: Window, event_mask: c_long) c_int;
pub extern "X11" fn XNextEvent(display: *Display, event_return: *XEvent) c_int;
pub extern "X11" fn XPending(display: *Display) c_int;
pub extern "X11" fn XFlush(display: *Display) c_int;
pub extern "X11" fn XSync(display: *Display, discard: Bool) c_int;
pub extern "X11" fn XConnectionNumber(display: *Display) c_int;

pub fn configureAsOverlay(dpy: *Display, win: Window) void {
    const wm_state = XInternAtom(dpy, "_NET_WM_STATE", 0);
    const skip_taskbar = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", 0);
    const skip_pager = XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", 0);
    const above = XInternAtom(dpy, "_NET_WM_STATE_ABOVE", 0);

    var atoms = [_]Atom{ skip_taskbar, skip_pager, above };
    _ = XChangeProperty(
        dpy,
        win,
        wm_state,
        XA_ATOM,
        32,
        PropModeReplace,
        @ptrCast(&atoms),
        @intCast(atoms.len),
    );
    _ = XFlush(dpy);
}

/// VK_* -> X11 KeySym; 0 if unmapped.
pub fn vkToKeysym(vk: u32) KeySym {
    if (vk >= 0x41 and vk <= 0x5A) return @intCast(vk + 0x20); // A-Z -> a-z
    if (vk >= 0x30 and vk <= 0x39) return @intCast(vk); // 0-9
    if (vk >= 0x70 and vk <= 0x87) return @as(KeySym, 0xFFBE) + (vk - 0x70); // F1-F24
    return switch (vk) {
        0x08 => 0xFF08, // VK_BACK → XK_BackSpace
        0x09 => 0xFF09, // VK_TAB
        0x0D => 0xFF0D, // VK_RETURN
        0x1B => 0xFF1B, // VK_ESCAPE
        0x20 => 0x0020, // VK_SPACE → XK_space
        0x21 => 0xFF55, // VK_PRIOR → XK_Page_Up
        0x22 => 0xFF56, // VK_NEXT  → XK_Page_Down
        0x23 => 0xFF57, // VK_END
        0x24 => 0xFF50, // VK_HOME
        0x25 => 0xFF51, // VK_LEFT
        0x26 => 0xFF52, // VK_UP
        0x27 => 0xFF53, // VK_RIGHT
        0x28 => 0xFF54, // VK_DOWN
        0x2D => 0xFF63, // VK_INSERT
        0x2E => 0xFFFF, // VK_DELETE
        else => 0,
    };
}

/// MOD_ALT=1, MOD_CONTROL=2, MOD_SHIFT=4, MOD_WIN=8.
pub fn modToX11(mods: u32) c_uint {
    var out: c_uint = 0;
    if (mods & 0x01 != 0) out |= Mod1Mask; // ALT
    if (mods & 0x02 != 0) out |= ControlMask;
    if (mods & 0x04 != 0) out |= ShiftMask;
    if (mods & 0x08 != 0) out |= Mod4Mask; // WIN/Super
    return out;
}
