# Known Constraints and Gotchas

## Identity

- Stable `NodeId` is required for animation-registry targeting and robust reconcile across rebuilds with reorders.
- Anonymous nodes match by structural position only — reorder a sibling and you lose its scroll/focus state.
- Nodes removed mid-frame have their references cleared from the interaction registry (`focused_node`, `hovered_node`, `active_drag_node`).

## Animations / transitions

- Transition registration happens during reconcile, only for properties whose `TransitionProperty` bit is set on the *new* style.
- Nodes without `NodeId` cannot be addressed by the animation registry; properties snap.
- `registerAnimation` requires the target node to exist in the retained tree — call after `setRootBuilder` + first build.

## Text

- Shaping is layout-phase. Re-shaping in render is a perf regression.
- Text content changes need at least `.relayout` (different metrics), often `.rebuild` if structure changes.

## Z-index

- Z ordering is per-node and global at render-command level.
- Raising a parent's z-index without raising descendants causes the parent's background to occlude its own children. Almost always you want z-index on the leaf you're trying to lift (e.g. dropdown menu node).

## Win32 transparent / DXGI bridge

- Some compositor configurations route the engine through the DXGI bridge: offscreen Vulkan render → CPU readback → DXGI present.
- Blur and backdrop-blur passes are not supported on that path (one-time warning).

## Linux / Wayland

- libdecor disabled (GTK harfbuzz collision) — no client-side decorations on Wayland.
- `GLFW_SCALE_FRAMEBUFFER` off — fb size = window size; compositor upscales.
- Global hotkeys via `XGrabKey` only fire while the window has focus on Wayland (XWayland limitation).

## Audio thread

- Never allocates. Calls `wake_cb` (wired to `glfw.postEmptyEvent`) for UI redraw.
- Finished playback cleanup is deferred to the main thread (`processAudioCleanup`).

## virtual_list

- Wrappers are slot-pooled (`slot = i % MAX_POOL_SIZE`). A wrapper at slot `s` may carry a different item index next frame.
- `item_node.layout_result` is only meaningful for the current `i` *after* layout has run for the current frame.
- Reading layout from outside the post-layout hook is suspect.

## Repository boundaries

- Reusable runtime/library code → `src/`. Re-export public surface through `src/root.zig`.
- Demos and one-off apps → `examples/<name>/`. Helpers used by exactly one example stay there.

## Tests

- `zig build test` runs the suite.
- Test files must be reachable from the `test { _ = @import(...); }` blocks in `src/root.zig` or `src/ui/components/root.zig`. Otherwise they don't run.
