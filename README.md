# Ramiel

> *“A solid of pure thought.”*

Retained-mode 2D UI runtime for Zig. Vulkan renderer, GLFW windowing, MSDF
text, flex/grid layout, animations, virtual lists, plots, audio + video.

> Status: alpha. API may change before `0.1.0` is tagged. Windows + Linux
> (X11 / XWayland). Wayland-native and macOS not yet supported.

## What you get

- **Renderer** — Vulkan, transparent windows, kawase blur, MSDF glyphs, image
  + video uploads, custom canvas elements.
- **Layout** — full box model + flex + grid + absolute, transforms,
  shadows, borders.
- **UI** — buttons, sliders, dropdowns, color picker, virtual lists,
  trees, file dialogs, plots (line / bar / scatter, LOD pyramid for
  large series).
- **Interaction** — captured drags, drag-cursor lock, global hotkeys
  (Win32 `RegisterHotKey` / X11 `XGrabKey`), shortcut handlers.
- **Animation** — CSS-style transitions, `Transform`, animation registry,
  hover-blend, looping.
- **Audio / video** — miniaudio + ffmpeg + plotted FFT spectrum.
- **Examples** — 13 runnable examples (see below).

## Quick start

```sh
zig fetch --save=ramiel git+https://github.com/Nikutsuki/Ramiel.git
```

`build.zig`:

```zig
const dep = b.dependency("ramiel", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ramiel", dep.module("ramiel"));
```

A minimal app uses `lib.Runtime` + `app.setRootBuilder(build_fn)`. See
`examples/canvas_app/` for the smallest non-trivial example.

## Build & run examples

```sh
zig build                       # build the library
zig build check                 # compile-only check across all targets
zig build test                  # unit + integration tests
zig build run-canvas-app        # baseline window + canvas
zig build run-components-showcase   # all UI components
zig build run-tree              # virtual tree + drag/drop
zig build run-file-explorer     # file explorer with native dialogs
zig build run-overlay           # taskbar-skip overlay + global hotkey
zig build run-plot              # plots: line / bar / scatter
zig build run-audio-player      # audio + FFT spectrum
zig build run-video-player      # ffmpeg video decode
zig build run-discord-client    # WebSocket gateway client (zig-wss)
zig build run-animation         # transitions / animations
zig build run-pointer-capture   # drag interactions
zig build run-box-sizing        # layout demo
zig build bench                 # microbenchmarks
```

Build options:
- `-Dtracy=true` — enable Tracy profiler integration.
- `-Ddevtools=true` — enable in-app DevTools overlay.

## Platform support

| Feature                       | Windows  | Linux X11 | Linux Wayland (XWayland) |
|-------------------------------|----------|-----------|--------------------------|
| Window + Vulkan                | yes      | yes       | yes                      |
| Transparent window             | yes (DXGI overlay path) | yes (Vulkan composite-alpha) | yes |
| `configureAsOverlay`           | yes      | yes       | partial (XWayland layer) |
| `registerGlobalHotkey`         | yes      | yes       | only when window focused |
| Audio (miniaudio)              | yes      | yes       | yes                      |
| Video (ffmpeg)                 | yes      | yes       | yes                      |

Native Wayland (layer-shell + GlobalShortcuts portal) is on the roadmap.

## Pre-reqs

- **Zig 0.16+** (see `build.zig.zon` `minimum_zig_version`).
- **`glslc`** on `PATH` (Vulkan shader compiler).
- **Linux**: `libgtk-3-dev libssl-dev libvulkan-dev libglfw3-dev libx11-dev`.
- **Windows**: Vulkan SDK + MSYS2 UCRT64 toolchain (for OpenSSL via
  `discord_client`); see `docs/dev/`.

## Repo layout

- `src/` — library (renderer, layout, UI components, interaction, app loop).
- `examples/` — runnable examples; one directory per example.
- `docs/` — architecture + user guides.
  - `docs/dev/` — internals for contributors.
  - `docs/user/` — public API guides.

## License

MIT — see [LICENSE](LICENSE).
