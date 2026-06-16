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
pub const WM_NCCALCSIZE: u32 = 0x0083;
pub const WM_NCHITTEST: u32 = 0x0084;
pub const WM_GETMINMAXINFO: u32 = 0x0024;
pub const WM_CLOSE: u32 = 0x0010;

pub const GWL_STYLE: i32 = -16;
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_CAPTION: u32 = 0x00C00000;
pub const WS_THICKFRAME: u32 = 0x00040000;

pub const HTNOWHERE: LRESULT = 0;
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTLEFT: LRESULT = 10;
pub const HTRIGHT: LRESULT = 11;
pub const HTTOP: LRESULT = 12;
pub const HTTOPLEFT: LRESULT = 13;
pub const HTTOPRIGHT: LRESULT = 14;
pub const HTBOTTOM: LRESULT = 15;
pub const HTBOTTOMLEFT: LRESULT = 16;
pub const HTBOTTOMRIGHT: LRESULT = 17;

pub const SM_CXSIZEFRAME: i32 = 32;
pub const SM_CYSIZEFRAME: i32 = 33;
pub const SM_CXPADDEDBORDER: i32 = 92;

pub const MONITOR_DEFAULTTONEAREST: u32 = 0x00000002;

pub const SW_MINIMIZE: c_int = 6;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_RESTORE: c_int = 9;

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const WINDOWPOS = extern struct {
    hwnd: HWND,
    hwndInsertAfter: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
};

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*WINDOWPOS,
};

pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT = .{},
    ptMaxSize: POINT = .{},
    ptMaxPosition: POINT = .{},
    ptMinTrackSize: POINT = .{},
    ptMaxTrackSize: POINT = .{},
};

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
extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.c) i32;
extern "user32" fn IsZoomed(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.c) BOOL;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.c) BOOL;
extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) BOOL;
extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: UINT) callconv(.c) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(hMonitor: ?*anyopaque, lpmi: *MONITORINFO) callconv(.c) BOOL;

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

pub const DWMWA_BORDER_COLOR: u32 = 34;
pub const DWMWA_COLOR_NONE: u32 = 0xFFFFFFFE;
extern "dwmapi" fn DwmSetWindowAttribute(hWnd: HWND, dwAttribute: u32, pvAttribute: *const anyopaque, cbAttribute: u32) callconv(.c) c_long;
pub const dwmSetWindowAttribute = DwmSetWindowAttribute;

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
pub const getSystemMetrics = GetSystemMetrics;
pub const isZoomed = IsZoomed;
pub const showWindow = ShowWindow;
pub const postMessageW = PostMessageW;

pub const HitTester = struct {
    ctx: ?*anyopaque = null,
    is_caption: ?*const fn (?*anyopaque, x: i32, y: i32) callconv(.c) bool = null,
};

fn resizeBorderPx() i32 {
    const frame = GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
    return if (frame > 0) frame else 8;
}

pub fn handleCustomFrame(
    hwnd: HWND,
    msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    tester: HitTester,
) ?LRESULT {
    switch (msg) {
        WM_NCCALCSIZE => {
            if (wParam == 0) return null;
            const params: *NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (IsZoomed(hwnd) != 0) {
                const mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
                var mi: MONITORINFO = .{};
                if (GetMonitorInfoW(mon, &mi) != 0) {
                    params.rgrc[0] = mi.rcWork;
                }
            }
            return 0;
        },
        WM_GETMINMAXINFO => {
            const mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            var mi: MONITORINFO = .{};
            if (GetMonitorInfoW(mon, &mi) == 0) return null;
            const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
            mmi.ptMaxPosition = .{ .x = mi.rcWork.left - mi.rcMonitor.left, .y = mi.rcWork.top - mi.rcMonitor.top };
            mmi.ptMaxSize = .{ .x = mi.rcWork.right - mi.rcWork.left, .y = mi.rcWork.bottom - mi.rcWork.top };
            mmi.ptMaxTrackSize = mmi.ptMaxSize;
            return 0;
        },
        WM_NCHITTEST => {
            const lp: usize = @bitCast(lParam);
            const screen_x: i32 = @as(i16, @bitCast(@as(u16, @truncate(lp & 0xFFFF))));
            const screen_y: i32 = @as(i16, @bitCast(@as(u16, @truncate((lp >> 16) & 0xFFFF))));

            var win_rect: RECT = .{};
            if (GetWindowRect(hwnd, &win_rect) == 0) return HTCLIENT;

            const maximized = IsZoomed(hwnd) != 0;
            if (!maximized) {
                const b = resizeBorderPx();
                const on_left = screen_x < win_rect.left + b;
                const on_right = screen_x >= win_rect.right - b;
                const on_top = screen_y < win_rect.top + b;
                const on_bottom = screen_y >= win_rect.bottom - b;
                if (on_top and on_left) return HTTOPLEFT;
                if (on_top and on_right) return HTTOPRIGHT;
                if (on_bottom and on_left) return HTBOTTOMLEFT;
                if (on_bottom and on_right) return HTBOTTOMRIGHT;
                if (on_left) return HTLEFT;
                if (on_right) return HTRIGHT;
                if (on_top) return HTTOP;
                if (on_bottom) return HTBOTTOM;
            }

            var pt: POINT = .{ .x = screen_x, .y = screen_y };
            _ = ScreenToClient(hwnd, &pt);
            if (tester.is_caption) |is_caption| {
                if (is_caption(tester.ctx, pt.x, pt.y)) return HTCAPTION;
            }
            return HTCLIENT;
        },
        else => return null,
    }
}

pub fn enableCustomFrame(hwnd: HWND) void {
    const margins = MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 1, .cyBottomHeight = 0 };
    _ = DwmExtendFrameIntoClientArea(hwnd, &margins);
    const border_none: u32 = DWMWA_COLOR_NONE;
    _ = DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &border_none, @sizeOf(u32));
    _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}
