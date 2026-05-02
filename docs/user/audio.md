# Audio

`AudioEngine` (miniaudio-backed) is owned by `Application`. Sounds, streams, FFT spectrum, waveform peaks — all routed through one engine.

## Lifecycle

`AudioEngine.init` runs inside `App.init`. The library wires `glfw.postEmptyEvent` as the wake callback so audio-thread events drain to UI promptly. `App.deinit` tears it down.

## Sound registry

Methods on `*Application`:

- `loadAndPlaySound(name, path) ?u64` — loads if needed, returns playback id.
- `getSoundId(name, path) !u32` — register, no playback.
- `playSoundById(sound_id) ?u64`
- `playAudioStream(path) ?u64` — for long files; streams from disk.
- `pauseStream` / `resumeStream` / `seekStream` / `getStreamCursorSeconds` / `getStreamDurationSeconds` / `isStreamPlaying`
- `setSoundVolume(playback_id, volume)`
- `stopSound(playback_id)`
- `unloadSound(name)`

Up to 64 concurrent voices (`MAX_CONCURRENT_VOICES` in `src/audio/registry.zig`). One-shot sounds use a pool; streams are tracked individually.

## Waveform peaks

Off-thread peak extraction for static waveform displays.

```zig
const peaks = try lib.audio_waveform.extractPeaks(allocator, "track.mp3", 512);
defer peaks.deinit(allocator);
// peaks.peaks: []f32 in [0,1]
// peaks.duration_seconds: f64
```

`src/audio/waveform.zig`.

## Spectrum analyzer

Real-time FFT over the audio tap. Hann window, in-place radix-2, log-spaced bands, one-pole peak-fall smoothing.

```zig
var analyzer = try lib.audio_spectrum.Analyzer.init(allocator, 1024, 64, 48000.0);
defer analyzer.deinit();
analyzer.decay = 0.85;        // smoothing
analyzer.db_floor = -72.0;
analyzer.db_ceiling = -6.0;
analyzer.compute(samples);
// analyzer.bands: []f32, normalized 0..1 per band
```

`src/audio/spectrum.zig`. FFT size must be a power of two.

## Tap (audio passthrough)

`audio_engine.tap` is a miniaudio passthrough node between sounds and the endpoint. It writes a mono mix into a 4096-frame ring buffer. UI reads via `tap.readSnapshot(...)` in the build/tick path.

```zig
app.audio_engine.tap.setWakeCallback(audioTapWake);
```

`src/audio/tap.zig`.

## Threading rule

The miniaudio callback thread never allocates. It writes the tap ring buffer and calls `wake_cb` (if set) — wire it to `glfw.postEmptyEvent` so the UI thread wakes and reads the latest snapshot.

`audio_engine.registry.processAudioCleanup()` runs at the top of every UI frame to free finished playback instances.

## References

- `src/audio/audio_engine.zig`
- `src/audio/registry.zig`
- `src/audio/spectrum.zig`
- `src/audio/waveform.zig`
- `src/audio/tap.zig`
- `examples/audio_player/main.zig`
