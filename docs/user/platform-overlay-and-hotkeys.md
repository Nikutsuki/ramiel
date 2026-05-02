# Platform: Overlay and Global Hotkeys

Cross-platform overlay configuration and OS-level hotkey registration.

## WindowConfig flags

```zig
.{
    .title = "My Overlay",
    .width = 1100,
    .height = 620,
    .borderless = true,
    .topmost = true,
    .transparent = true,
    .visible_on_start = false,
}
```

`src/window/window.zig:47`.

## Visibility

- `app.setVisibility(true)` — show + focus
- `app.setVisibility(false)` — hide; resets stale interaction state

## configureAsOverlay

`window.configureAsOverlay()` — drops the window from the taskbar / Alt-Tab style switcher.

| Platform | Mechanism |
|---|---|
| Win32 | clears `WS_EX_APPWINDOW`, sets `WS_EX_TOOLWINDOW`, `SetWindowPos(SWP_FRAMECHANGED)` |
| Linux X11 | `_NET_WM_STATE_SKIP_TASKBAR`, `_NET_WM_STATE_SKIP_PAGER`, `_NET_WM_STATE_ABOVE` via `XChangeProperty` |
| Wayland | not implemented (no compositor protocol exposes this) |

## Global hotkeys

```zig
try app.registerGlobalHotkey(modifier, key, callback);
```

Callback receives `user_ptr` — the `Application*` you passed implicitly. Toggle visibility or post a message from there.

| Platform | Mechanism |
|---|---|
| Win32 | `RegisterHotKey(hwnd, ...)`; first registration installs a wndproc subclass to intercept `WM_HOTKEY` (GLFW discards it) |
| Linux X11 | `XGrabKey` on root window via a dedicated `Display` connection + listener thread |
| Wayland | `XGrabKey` only fires when the window has focus — global hotkeys do not work |

Modifier/key constants come from `lib.win32` (e.g. `MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT`, `0x20` for VK_SPACE). On X11 the same numeric values are translated via `vkToKeysym` and `modToX11` in `src/window/x11_native.zig`.

```zig
try app.registerGlobalHotkey(
    lib.win32.MOD_CONTROL | lib.win32.MOD_SHIFT | lib.win32.MOD_NOREPEAT,
    0x20, // VK_SPACE
    onOverlayHotkey,
);
```

## Limitations

- Wayland has no working global hotkey path. Use a portal / DBus shortcut on the user's side.
- Win32 transparent path may route through the DXGI bridge where blur / backdrop-blur passes are not yet supported.

## References

- `src/window/window.zig`
- `src/window/x11_native.zig`
- `src/window/win32.zig`
- `examples/overlay/main.zig`
