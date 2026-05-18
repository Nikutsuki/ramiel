//! Win32-specific backend helpers used by the current GLFW platform path.
//!
//! This module is a thin compatibility layer over `src/window/win32.zig` so the
//! platform refactor can move native operations out of the generic window module
//! incrementally without changing behavior.

const builtin = @import("builtin");

pub const available = builtin.os.tag == .windows;

const native = if (available) @import("../window/win32.zig") else struct {
    pub const HWND = *anyopaque;
    pub const WNDPROC = *const anyopaque;
    pub const UINT = u32;
    pub const WPARAM = usize;
    pub const LPARAM = isize;
    pub const LRESULT = isize;
    pub const LONG_PTR = isize;
    pub const MARGINS = extern struct {
        cxLeftWidth: c_int = 0,
        cxRightWidth: c_int = 0,
        cyTopHeight: c_int = 0,
        cyBottomHeight: c_int = 0,
    };
};

pub const HWND = native.HWND;
pub const WNDPROC = native.WNDPROC;
pub const UINT = native.UINT;
pub const WPARAM = native.WPARAM;
pub const LPARAM = native.LPARAM;
pub const LRESULT = native.LRESULT;
pub const LONG_PTR = native.LONG_PTR;
pub const MARGINS = native.MARGINS;

pub const GWLP_WNDPROC = if (available) native.GWLP_WNDPROC else -4;
pub const WM_HOTKEY = if (available) native.WM_HOTKEY else 0x0312;

pub const MOD_ALT = if (available) native.MOD_ALT else 0x0001;
pub const MOD_CONTROL = if (available) native.MOD_CONTROL else 0x0002;
pub const MOD_SHIFT = if (available) native.MOD_SHIFT else 0x0004;
pub const MOD_WIN = if (available) native.MOD_WIN else 0x0008;
pub const MOD_NOREPEAT = if (available) native.MOD_NOREPEAT else 0x4000;

pub const getWindowLongPtrW = if (available) native.getWindowLongPtrW else unavailableGetWindowLongPtrW;
pub const setWindowLongPtrW = if (available) native.setWindowLongPtrW else unavailableSetWindowLongPtrW;
pub const getPropW = if (available) native.getPropW else unavailableGetPropW;
pub const setPropW = if (available) native.setPropW else unavailableSetPropW;
pub const removePropW = if (available) native.removePropW else unavailableRemovePropW;
pub const callWindowProcW = if (available) native.callWindowProcW else unavailableCallWindowProcW;
pub const defWindowProcW = if (available) native.defWindowProcW else unavailableDefWindowProcW;
pub const registerHotKey = if (available) native.registerHotKey else unavailableRegisterHotKey;
pub const unregisterHotKey = if (available) native.unregisterHotKey else unavailableUnregisterHotKey;
pub const dwmExtendFrameIntoClientArea = if (available) native.dwmExtendFrameIntoClientArea else unavailableDwmExtendFrameIntoClientArea;

pub fn configureAsOverlay(hwnd: HWND) void {
    if (!available) return;

    var ex_style = native.getWindowLongPtrW(hwnd, native.GWL_EXSTYLE);
    ex_style &= ~@as(native.LONG_PTR, @intCast(native.WS_EX_APPWINDOW));
    ex_style |= @as(native.LONG_PTR, @intCast(native.WS_EX_TOOLWINDOW));
    _ = native.setWindowLongPtrW(hwnd, native.GWL_EXSTYLE, ex_style);

    _ = native.setWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        native.SWP_NOMOVE | native.SWP_NOSIZE | native.SWP_NOZORDER | native.SWP_NOACTIVATE | native.SWP_FRAMECHANGED,
    );
}

fn unavailableGetWindowLongPtrW(_: HWND, _: i32) callconv(.c) LONG_PTR {
    return 0;
}
fn unavailableSetWindowLongPtrW(_: HWND, _: i32, _: LONG_PTR) callconv(.c) LONG_PTR {
    return 0;
}
fn unavailableGetPropW(_: HWND, _: [*:0]const u16) callconv(.c) ?*anyopaque {
    return null;
}
fn unavailableSetPropW(_: HWND, _: [*:0]const u16, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}
fn unavailableRemovePropW(_: HWND, _: [*:0]const u16) callconv(.c) ?*anyopaque {
    return null;
}
fn unavailableCallWindowProcW(_: WNDPROC, _: HWND, _: UINT, _: WPARAM, _: LPARAM) callconv(.c) LRESULT {
    return 0;
}
fn unavailableDefWindowProcW(_: HWND, _: UINT, _: WPARAM, _: LPARAM) callconv(.c) LRESULT {
    return 0;
}
fn unavailableRegisterHotKey(_: ?HWND, _: i32, _: UINT, _: UINT) callconv(.c) c_int {
    return 0;
}
fn unavailableUnregisterHotKey(_: ?HWND, _: i32) callconv(.c) c_int {
    return 0;
}
fn unavailableDwmExtendFrameIntoClientArea(_: HWND, _: *const MARGINS) callconv(.c) c_long {
    return 0;
}
