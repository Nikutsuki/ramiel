# Transparent and Overlay (Win32 + Linux X11)

Per-pixel-alpha windows + system-tray-free always-on-top behavior. Win32 and X11 both supported; Wayland partial.

## WindowConfig

`src/window/window.zig:47` — `transparent`, `borderless`, `topmost`, `visible_on_start`. Applied via GLFW hints in `initWindow` (`window.zig:462`).

## Win32 transparent

GLFW `TransparentFramebuffer` hint sets `WS_EX_LAYERED` indirectly. To get per-pixel alpha through Vulkan's `VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR`, we also call `DwmExtendFrameIntoClientArea(hwnd, {-1, -1, -1, -1})` (`window.zig:493`). Without that, the swapchain composites against an opaque DWM background.

## X11 transparent

GLFW handles the visual + colormap. No extra dance — relying on the compositor (picom, kwin, mutter).

## configureAsOverlay

`window.zig:219`.

- Win32: clears `WS_EX_APPWINDOW`, sets `WS_EX_TOOLWINDOW`. `SetWindowPos(SWP_FRAMECHANGED)` to make the shell re-read the style.
- X11: sets `_NET_WM_STATE_SKIP_TASKBAR`, `_NET_WM_STATE_SKIP_PAGER`, `_NET_WM_STATE_ABOVE` via `XChangeProperty`. See `x11_native.zig::configureAsOverlay`.

## Global hotkeys

`Application.registerGlobalHotkey` -> `WindowContext.registerGlobalHotkey` (`window.zig:251`).

### Win32

`RegisterHotKey(hwnd, id, mod, vk)`. First registration subclasses the GLFW wndproc with `hookedWndProc` (`window.zig:348`) because GLFW discards `WM_HOTKEY`. The subclass dispatches by ID into the `hotkeys` map and forwards everything else to the original wndproc.

### X11

`registerGlobalHotkeyX11` (`window.zig:374`):

- Opens a dedicated `Display` connection (the GLFW one is owned by GLFW's event thread).
- Translates `vk` -> keysym -> keycode (`x11_native.zig::vkToKeysym`).
- `XGrabKey` on the root window with all `LockMask`/`Mod2Mask` (NumLock/CapsLock) variants.
- Spawns a listener thread (`x11HotkeyLoop`) that pulls events with `XPending` + `XNextEvent` and matches keycode + masked state against the registered entries.

### Wayland caveat

`XGrabKey` on Wayland's XWayland surface only fires when the window has input focus — it is not a global grab. Document this and route the user toward a portal-based shortcut.

## DXGI bridge (Win32 transparent fallback)

For some compositor configurations the engine routes through an offscreen Vulkan render + CPU readback + DXGI present (see `src/window/dxgi_overlay.zig`). The path currently does not support blur / backdrop-blur passes; the engine emits a one-time warning.

## References

- `examples/overlay/main.zig`
- `src/window/window.zig`
- `src/window/x11_native.zig`
- `src/window/win32.zig`
- `src/window/dxgi_overlay.zig`
