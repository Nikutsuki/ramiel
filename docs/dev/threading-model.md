# Threading Model

One UI thread does all build / reconcile / layout / render. Subsystems own their own threads and communicate via lock-free queues, atomic flags, or `interaction_registry.postExternalMessage`.

## Main thread

`Application.run` (`src/app.zig:734`) — the only thread that touches the retained UI tree, reducer, build arena, layout state, Vulkan command submission. Sleeps in `glfw.waitEventsTimeout`.

## Audio callback thread

miniaudio pulls samples on its own thread. Library invariants:

- Never allocate.
- Mix into `Tap.ring` (lock-free ring buffer, `src/audio/tap.zig`).
- Call `wake_cb` after each ring write — the library wires this to `glfw.postEmptyEvent` so the UI thread wakes for spectrum/waveform redraw.
- Cleanup of finished playback instances is *not* done here; finished voices flip an atomic flag and the UI calls `processAudioCleanup` next frame.

## Video decode threads

One demuxer + one decoder per `VideoPlayback` (`src/video/playback.zig`).

- Demuxer: `av_read_frame` -> `PacketQueue` (mutex + condvar).
- Decoder: pops packets, runs `avcodec_send_packet` / `_receive_frame`, swscale to YUV planes, pushes onto `FrameQueue`.
- Atomic flags coordinate seek (`seek_target_us`), flush (`decoder_flush_flag`, `audio_flush_pending`), EOF (`eof_reached`).
- Audio side feeds the shared miniaudio engine via vtable callbacks.

Main thread's `VideoManager.tick(frame_index)` pulls one frame per playback off `FrameQueue` and uploads to a YUV texture for the active swapchain frame slot.

## Image ingress

`ImageIngress` (`src/renderer/image_ingress.zig`) runs disk reads + HTTP fetches on `std.Io` tasks (`io.concurrent` with fallback to `io.async`).

- Dedup + backpressure under `request_mutex`.
- Decoded bytes are pushed into `texture_registry` via the registry's thread-safe push API.
- Main thread's `processPendingTextureUploads` (called once/frame) runs the actual GPU upload, marks paint dirty, possibly requests a rebuild.

## Cross-thread message ingress

`InteractionRegistry.postExternalMessage(msg)` and `Application.postMessage` / `postMessageId` are the only sanctioned ways to inject reducer messages from another thread.

- Mutex-protected `cross_thread_queue` (`Application`) or `external_messages` (`InteractionRegistry`).
- Posting calls `glfw.postEmptyEvent` to wake the UI loop.
- Main loop drains into the per-frame message queue before reducer dispatch (`src/app.zig:796`).

## File dialog

`Application.openFileDialog` runs NFD on a `std.Io.concurrent` task. The worker calls `nfd.openFileDialog`, dupes the result string into the app allocator, then `app.postMessageId(callback(path))` so the main loop owns the result.

## Hotkey listener (Linux X11)

A dedicated `Display` connection + listener thread. See `docs/dev/windows-transparent-and-overlay.md`.

## What is NOT thread-safe

- `*UIContext` and the retained tree.
- `*Node` mutation outside the build/reconcile path.
- The build arena.
- Vulkan device + queues outside `engine.draw`.

Always route through messages.

## References

- `src/app.zig:796` — cross-thread drain
- `src/audio/tap.zig`
- `src/video/playback.zig`
- `src/renderer/image_ingress.zig`
- `src/ui/interaction.zig`
