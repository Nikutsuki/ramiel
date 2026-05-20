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
- `-Dhot-reload=true` — build hot-reloadable examples as a swappable shared
  library + thin host (see below).

## Hot reload (dev)

Hot-reloadable examples (`pointer_capture`, `managed`) split into a thin host
that owns the window/GPU/state and a `libapp_<name>.so` holding the app's
`build`/`update` bodies. Run the host:

```sh
zig build run-pointer-capture-host -Dhot-reload   # or run-managed-host
```

Edit the app logic (e.g. `examples/pointer_capture/logic.zig`) and save. A
background watcher rebuilds the `.so` and the host swaps it in place, preserving
live state, the window, the GPU device, fonts and audio. Press **F5** to force a
reload. Two paths are chosen automatically by an ABI hash:

- **Logic edits** (`build`/`update` bodies) keep the same process; `State` stays
  in memory untouched.
- **Schema edits** (changing `State`/`Msg`/page shape) change the layout, so the
  host serializes state to JSON, re-execs the freshly built host, and restores —
  the window flashes but logical state is preserved.

Hot reload is a dev-only feature (Linux today). Release builds are single static
binaries and are unaffected.

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
