// Win32 bindings for wndproc subclassing and global hotkeys.

pub const HWND = *anyopaque;
pub const HANDLE = ?*anyopaque;
pub const BOOL = c_int;
pub const UINT = u32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG_PTR = isize;

pub const WNDPROC = *const fn (
    hwnd: HWND,
    msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.c) LRESULT;

pub const GWLP_WNDPROC: i32 = -4;
pub const GWL_EXSTYLE: i32 = -20;

pub const WS_EX_TOOLWINDOW: u32 = 0x00000080;
pub const WS_EX_APPWINDOW: u32 = 0x00040000;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;
/// Required after GWL_EXSTYLE writes; forces the shell to re-query.
pub const SWP_FRAMECHANGED: u32 = 0x0020;

pub const WM_HOTKEY: u32 = 0x0312;
pub const WM_DESTROY: u32 = 0x0002;

pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;
pub const MOD_NOREPEAT: u32 = 0x4000;

extern "user32" fn GetWindowLongPtrW(hwnd: HWND, nIndex: i32) callconv(.c) LONG_PTR;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, nIndex: i32, dwNewLong: LONG_PTR) callconv(.c) LONG_PTR;
extern "user32" fn GetPropW(hwnd: HWND, lpString: [*:0]const u16) callconv(.c) HANDLE;
extern "user32" fn SetPropW(hwnd: HWND, lpString: [*:0]const u16, hData: ?*anyopaque) callconv(.c) BOOL;
extern "user32" fn RemovePropW(hwnd: HWND, lpString: [*:0]const u16) callconv(.c) HANDLE;
extern "user32" fn CallWindowProcW(
    lpPrevWndFunc: WNDPROC,
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.c) LRESULT;
extern "user32" fn DefWindowProcW(
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.c) LRESULT;
extern "user32" fn RegisterHotKey(hWnd: ?HWND, id: i32, fsModifiers: UINT, vk: UINT) callconv(.c) BOOL;
extern "user32" fn UnregisterHotKey(hWnd: ?HWND, id: i32) callconv(.c) BOOL;
extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: c_int,
    Y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: UINT,
) callconv(.c) BOOL;

// DwmExtendFrameIntoClientArea(-1...) is the reliable per-pixel alpha path for Vulkan
// surfaces on Win10/11; DwmEnableBlurBehindWindow (what GLFW uses) is flaky.
pub const MARGINS = extern struct {
    cxLeftWidth: c_int = 0,
    cxRightWidth: c_int = 0,
    cyTopHeight: c_int = 0,
    cyBottomHeight: c_int = 0,
};
extern "dwmapi" fn DwmExtendFrameIntoClientArea(hWnd: HWND, pMarInset: *const MARGINS) callconv(.c) c_long;
pub const dwmExtendFrameIntoClientArea = DwmExtendFrameIntoClientArea;

pub const getWindowLongPtrW = GetWindowLongPtrW;
pub const setWindowLongPtrW = SetWindowLongPtrW;
pub const getPropW = GetPropW;
pub const setPropW = SetPropW;
pub const removePropW = RemovePropW;
pub const callWindowProcW = CallWindowProcW;
pub const defWindowProcW = DefWindowProcW;
pub const registerHotKey = RegisterHotKey;
pub const unregisterHotKey = UnregisterHotKey;
pub const setWindowPos = SetWindowPos;
