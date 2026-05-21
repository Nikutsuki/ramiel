# Changelog

## [Unreleased]

### Added
- User GPU shaders, compiled from GLSL to SPIR-V at runtime via vendored
  libshaderc (`ramiel.ShaderCompiler` / `ShaderStage`). Three `Application`
  entry points, all reusing one uniform ABI (`resolution`, `time`, `delta`,
  `frame`, `user[8]`):
  - `createComputeCanvas` — compute shader writes a storage image displayed
    as a `Canvas`; optional input image at `binding 2`.
  - `runComputeFilter` — one-shot compute pixels-in/pixels-out with readback.
  - `createShaderCanvas` — fragment shader rendered to an offscreen texture
    (library supplies the fullscreen-triangle vertex shader); `resizeShaderCanvas`
    re-targets it to the window.
  - `Canvas` gains compute and fragment backings alongside the CPU pixel buffer.
  - libshaderc vendored per platform under `src/thirdparty/shaderc_<platform>/`,
    linked like FFmpeg. Docs: `docs/user/gpu-shaders.md`.
  - Examples: `shader_canvas`, `shader_background`; GPU filters added to
    `canvas_app` next to the CPU ones.
- Native Linux backend (X11 / XWayland).
  - `configureAsOverlay` via `_NET_WM_STATE_SKIP_TASKBAR / SKIP_PAGER / ABOVE`.
  - `registerGlobalHotkey` via `XGrabKey` on a dedicated X11 connection +
    listener thread. Win32 VK code → X11 keysym mapping for letters, digits,
    F-keys, and common control keys.
  - `src/window/x11_native.zig` Xlib bindings module.
- `LICENSE` (MIT), `README.md`, `CHANGELOG.md`.

### Changed
- `src/window/window.zig`: Win32-only code (taskbar styles, hotkey
  registration, `WndProc` subclassing, DWM transparent frame extension)
  comptime-gated so the file compiles on Linux. GLFW init forces the X11
  backend on Linux for XWayland compatibility under Wayland compositors.
- `src/window/dxgi_overlay.zig`: stub returns `error.UnsupportedPlatform`
  on non-Windows; `win32` import is comptime-conditional.
- `examples/overlay/everything.zig`: kernel32/shell32 references
  comptime-gated so non-Windows builds don't pull in those symbols.
- `build.zig.zon`: pin all `#HEAD` dependencies to specific commits;
  switch `zig_wss` from local path to `github.com/Nikutsuki/zig-wss`.

### Notes
- Wayland session: works under XWayland (window, render, transparency,
  taskbar-skip flags). Global hotkeys fire only when the window is
  focused — Wayland does not permit root-level key grabs. Native
  Wayland support (`wlr-layer-shell` + GlobalShortcuts portal) is
  planned.
- DXGI overlay fast path is Windows-only by design; Linux uses the
  Vulkan composite-alpha path.
