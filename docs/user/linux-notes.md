# Linux Notes

Quirks specific to the Linux build path.

## libdecor disabled

GLFW Wayland's libdecor backend pulls libdecor-gtk → libpango → harfbuzz, which collides with our statically-linked harfbuzz at `hb_ot_metrics` alignment. We disable libdecor at GLFW init:

```zig
glfw.initHint(0x00053001, 0x00038002); // GLFW_WAYLAND_LIBDECOR=GLFW_WAYLAND_DISABLE_LIBDECOR
```

`src/window/window.zig:465`. Practical effect: no client-side decorations on Wayland — GNOME shell will draw none, KDE will use server-side.

## GLFW_SCALE_FRAMEBUFFER off

```zig
glfw.windowHint(0x0002200D, 0); // GLFW_SCALE_FRAMEBUFFER
```

`window.zig:478`. Keeps `framebuffer_size == window_size`, matching Win32/X11 behavior. The compositor upscales for HiDPI. Without this hint, Wayland would hand us a framebuffer scaled by `output_scale`, and our layout code would need to track two coordinate systems.

## X11 hotkey backend

`registerGlobalHotkey` on Linux opens a *dedicated* `Display` via `XOpenDisplay(null)` for the hotkey listener thread. The main `Display` is owned by GLFW's event thread and Xlib is not safe to share across threads without `XInitThreads` (which has its own stability issues with Vulkan).

The listener thread polls with `XPending` + `XNextEvent`, sleeps 50ms otherwise. `XGrabKey` is registered for all `LockMask`/`Mod2Mask` (NumLock/CapsLock) variants so hotkeys fire regardless of lock state. `src/window/window.zig:374`, `src/window/x11_native.zig`.

## Wayland global hotkey limitation

`XGrabKey` over XWayland only fires while the window has input focus. There is no compositor-agnostic global hotkey protocol. Document this and route the user toward `org.freedesktop.portal.GlobalShortcuts` on their side.

## ffmpeg version mismatch

We dynamically link system ffmpeg (`libavcodec`, `libavformat`, `libswscale`, `libswresample`, `libavutil`). Distros ship different majors — videos may fail to decode if the headers we built against and the runtime libs disagree on struct layouts. Prefer ffmpeg 6.x.

## GTK file dialog symbol collision

`nfd` (Native File Dialog) uses GTK on Linux. GTK pulls libpango → harfbuzz → same `hb_ot_metrics` alignment issue. We mitigate by building our static harfbuzz with `-fvisibility=hidden`, which keeps the symbol off the global namespace and lets the dynamic loader resolve GTK's harfbuzz independently.

## References

- `src/window/window.zig:462`
- `src/window/x11_native.zig`
