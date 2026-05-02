# App Loop Phases

`Application.run` (`src/app.zig:734`) per frame, in order. Idles on `waitEvents` when nothing is pending.

## Phases

1. **Audio cleanup** — `audio_engine.registry.processAudioCleanup()` (`app.zig:747`). Frees finished playback instances marked from the audio thread.

2. **Visibility gate** (`app.zig:749`). Hidden window blocks on `waitEvents` and skips the rest.

3. **Event wait** (`app.zig:754`). `waitEventsTimeout(computeWaitTimeoutSeconds())` — timeout is the min of animation deadline, video poll Hz, animated-image min frame, `tick_interval_s`, hover-anim. `0.0` if rebuild already requested.

4. **Video tick** (`app.zig:763`). `video_manager.tick(frame_index)` pulls decoded frames into the per-frame YUV texture; sets paint dirty if a new frame landed.

5. **Frame timing** (`app.zig:773`). Updates `ui.current_time`, `ui.delta_time`, devtools FPS history.

6. **Resize check** (`app.zig:780`). Compares last fb size; marks layout + paint dirty.

7. **Input + hit-test** (`app.zig:788`). `interaction_registry.updateInput` reads GLFW; `processInteractions` does hit-testing against last frame's tree, dispatches events; `drainExternalMessages` pulls the registry-side queue.

8. **Cross-thread queue drain** (`app.zig:796`). `cross_thread_queue` (filled by `Application.postMessage` from any thread) merges into the registry's `message_queue`.

9. **Texture upload** (`app.zig:806`). `engine.processPendingTextureUploads()` runs queued GPU uploads from the image ingress thread; if anything landed, paint dirty + queue rebuild.

10. **`tick_fn`** (`app.zig:814`). Optional per-frame app hook; returns `UpdateAction`.

11. **Reducer drain** (`app.zig:827`). For each queued message, `update_fn(self, msg)` runs; return values ORed into rebuild/relayout/repaint flags.

12. **DevTools rebuild request** (`app.zig:842`). DevTools panel can request rebuild via `consumeRebuildRequest`.

13. **Conditional rebuild** (`app.zig:859`). `build_fn(&ui, &state)` writes new tree into `build_arena`; `ui.reconcile(new_root)` patches retained tree by stable `NodeId`.

14. **Layout/paint requests from registry** (`app.zig:873`).

15. **Animation tick** (`app.zig:884`). `animation_registry.tick(time)` advances entries; layout-affecting animations dirty layout. Hover-blend ticks separately.

16. **Layout pass** (`app.zig:897`). Up to 2 passes. Inside each: apply animated values, run `calculateLayout` (measure + arrange + post-layout hooks). A hook returning `true` re-dirties layout for the second pass.

17. **Render pass** (`app.zig:909`). Apply animated values, clear batcher, push root scissor, `ui.render` walks tree, devtools highlights overlay, `engine.draw` submits.

## Why this order

- Texture uploads before reducer drain: uploads can affect what the next build emits (resolved image IDs).
- Rebuild before layout: descriptor changes need to land before measurement.
- Animation application immediately before layout/render: avoid stale interpolated values.
- External messages drained before reducer: async results integrate naturally.
- Layout up to 2 passes: post-layout hooks (e.g. `virtual_list`) can request a second pass within the same frame to consume freshly-measured geometry without a frame delay.

## References

- `src/app.zig`
- `src/ui/context.zig::reconcile`
- `src/ui/context.zig::registerPostLayoutHook`
