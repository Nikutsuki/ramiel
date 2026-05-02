# Video

ffmpeg-backed playback with separate demuxer and decoder threads, YUV upload to a Vulkan texture, audio routed through the shared miniaudio engine.

## Manager

`VideoManager` (`src/video/manager.zig`) is a field on `*Application`. One manager owns all `*VideoPlayback` instances.

```zig
const playback = try app.video_manager.createPlayback("clip.mp4");
defer app.video_manager.destroyPlayback(playback.id);
```

`VideoManager.tick(frame_index)` runs once per frame from `Application.run` — pulls decoded frames into the YUV texture for the active swapchain frame slot.

## Playback

`VideoPlayback` (`src/video/playback.zig`) — per-stream state.

- `play()` / `pause()`
- `seekTo(seconds)`
- `setVolume(0..1)`
- `state: PlaybackState` — `.loading | .playing | .paused | .buffering | .ended | .error_state`
- `width` / `height`

`initAsync` opens the file off-thread; the playback enters `.loading` until first frame decoded.

## Internals (per playback)

- Demuxer thread — reads packets from `AVFormatContext`, pushes into `PacketQueue`.
- Decoder thread — pops packets, runs `avcodec_send_packet` / `_receive_frame`, swscale to YUV planes, pushes onto `FrameQueue`.
- Audio data source — feeds the miniaudio engine via vtable callbacks (`audioSourceRead`, `audioSourceSeek`, etc.).
- Atomic flags coordinate seek/flush across threads.

## UI binding

The `comp.video` builder takes a `*const VideoPlayback` and a `Style`:

```zig
try b.video(playback, .{ .width = .Full, .height = .{ .exact = 480 } });
```

For full transport controls use `comp.videoPlayer`:

```zig
try b.videoPlayer(.{
    .base_id = ids.player,
    .font = font,
}, .{
    .playback = playback,
    .progress = current_seconds / duration,
    .volume = state.volume,
    .is_hovered = state.player_hovered,
    .on_play_toggle = .play_toggle,
    .on_seek = lib.bindTag(AppMessage, f32, .seek_to),
    .on_volume = lib.bindTag(AppMessage, f32, .volume_changed),
    .on_hover_enter = .player_hover_enter,
    .on_hover_leave = .player_hover_leave,
});
```

`VideoPlayerDescriptor` has style overrides for the controls strip, slider, icon buttons. `examples/video_player/main.zig`.

## References

- `src/video/manager.zig`
- `src/video/playback.zig`
- `src/video/demuxer.zig`
- `src/video/decoder.zig`
- `src/ui/components/video_player.zig`
