# Architecture Overview

Retained-mode UI runtime over Vulkan. App provides `build_fn` + reducer; library owns everything else.

## Layout

- `src/app.zig` — `Application(StateType, MessageType)`, frame loop, fans out to subsystems.
- `src/ui/` — retained tree, `UIContext`, layout (`layout.zig`), reconcile (`context.zig`), interaction (`interaction.zig`), components (`components/`).
- `src/animation/` — registry + easing.
- `src/renderer/` — Vulkan engine, font system, image ingress, canvas, icons, MSDF text.
- `src/window/` — GLFW + Win32 + X11 helpers, overlay/hotkey backends.
- `src/audio/` — miniaudio wrapper, sound registry, FFT spectrum, waveform peaks, tap.
- `src/video/` — ffmpeg-backed playback, demuxer/decoder threads, manager.
- `src/devtools/` — overlay UI panels.

## Data flow

1. GLFW event → `interaction_registry.processInteractions` → message_queue.
2. Reducer (`update_fn`) drains queue, returns `UpdateAction` per message; ORed.
3. If rebuild requested, `build_fn` writes a fresh tree into `build_arena`; `ui.reconcile` patches the retained tree by stable `NodeId`.
4. Layout (`measureNode` + `arrangeNode`); post-layout hooks may dirty for a second pass.
5. Render: `ui.render` walks the tree, fills the `QuadBatcher`; `engine.draw` submits Vulkan work.

## Public surface

`src/root.zig` re-exports everything callers need. New public subsystem → expose it there.

## Lifetime regimes

Three:

- Build arena (`ui.build_arena`) — per frame, bulk-freed after reconcile.
- Retained tree — GPA-owned, lives across frames, holds `layout_result`, focus state, scroll offsets, hover-blend animations, text caches.
- Subsystem-owned — engine resources, font atlases, audio engine, video playbacks.

Every field belongs to exactly one regime. See `src/ui/context.zig::reconcileNode` for promotion rules.

## Invariants

- Stable `NodeId` is the basis for identity-preserving reconcile (`lib.declareIds`).
- Tree mutation only happens on the main thread.
- Text shaping is layout-phase, never render-phase.
- Cross-thread messages enter via `interaction_registry.postExternalMessage` or `Application.postMessage`.
- Audio callback never allocates; wakes UI via `glfw.postEmptyEvent`.

## References

- `src/app.zig`
- `src/ui/context.zig`
- `src/root.zig`
- `examples/box_sizing/main.zig` — minimal shape
- `examples/discord_client/` — full app shape
