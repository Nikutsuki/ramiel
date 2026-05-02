# API Reference

Authoritative source: `src/root.zig`. Every public symbol below is reachable via `lib.<name>` after `const lib = @import("ramiel");`.

## Runtime helpers

- `Runtime` — debug allocator wrapper. `Runtime.init()` / `.deinit()`; `.allocator()` returns `DebugAllocator` in Debug, `smp_allocator` in Release.
- `For(MessageT)` — bundles `UIContext`, `Node`, `InteractionMessage`, `InteractionRegistry`, `EventBinding`. Use as `const T = lib.For(AppMessage);` then `T.UIContext`, etc.
- `declareIds(.{ "tag1", "tag2" })` — comptime returns a struct with stable `NodeId` fields, one per tag.
- `bindTag(MessageT, ValueT, .tag)` — comptime trampoline producing `*const fn(ValueT, ?*const anyopaque) MessageT` that wraps `value` in a tagged union variant.
- `bindStatic(MessageT, ValueT, msg)` — same shape, ignores incoming value.
- `dupeMessageBinding` — clone an `EventBinding` into another allocator.

## Application

`Application(StateType, MessageType)` (`src/app.zig:39`).

Lifecycle:

- `init(allocator, io, WindowConfig, initial_state, update_fn) !Self`
- `setRootBuilder(build_fn) !void`
- `mountRoot() !void` (called automatically by `run`)
- `run() !void`
- `deinit()`

State / messaging:

- `postMessage(InteractionMessage) void` — thread-safe ingress, wakes event loop.
- `postMessageId(MessageT) void` — convenience wrapper.
- `setShortcutHandler(CtxT, ctx, fn) void` — typed global key handler.
- `setVisibility(bool) void`
- `tick_fn: ?*const fn(*Self) UpdateAction` — optional per-frame field.
- `tick_interval_s: ?f64` — wake cadence so `tick_fn` fires without input.

Rendering / layout:

- `updateTheme(Theme) void`

Fonts:

- `loadFont(name, FontSource, base_resolution) !*FontData`
- `setDefaultFallbackChain(names) !void`
- `getFont(name) ?*FontData`
- `requireFont(name) *FontData` — panics if missing.

Audio (`src/audio/`):

- `loadAndPlaySound(name, path) ?u64`
- `getSoundId(name, path) !u32`
- `playSoundById(u32) ?u64`
- `playAudioStream(path) ?u64`
- `stopSound(playback_id)`
- `setSoundVolume(playback_id, volume)`
- `seekStream(playback_id, seconds)`
- `pauseStream` / `resumeStream` / `isStreamPlaying` / `getStreamCursorSeconds` / `getStreamDurationSeconds`
- `unloadSound(name)`

Images:

- `loadImageFromDiskAsync(name, path, max_bytes) !void`
- `loadImageFromDiskAsyncSized(name, path, w, h) !void`
- `loadImageFromUrlAsync(name, url, max_bytes) !void`
- `loadImageFromUrlAsyncSized(name, url, w, h) !void`
- `getImageId(name) u32`
- `pushImageData(name, compressed_bytes) !void` — synchronous push.
- `getImageState(name) TextureState` / `getResolvedImageState(name)`
- `setImageIngressBudget(ImageIngressBudget)`

Icons:

- `loadIconSvg(id, path, w, h, scale) !void`
- `loadIconPng(id, path, scale) !void`
- `loadIconSvgFromMemory(id, bytes, w, h, scale) !void`
- `loadIconPngFromMemory(id, bytes, scale) !void`
- `loadRuntimeIconPng(path, scale) !IconId`
- `freeRuntimeIcon(IconId)`
- `getIconTextureId(id, scale) ?u32`

Canvas:

- `createCanvas(w, h) !*Canvas`
- `createCanvasFromBuffer(PixelBuffer) !*Canvas`
- `destroyCanvas(*Canvas)`

DevTools (`-Ddevtools=true`):

- `setDevToolsActive(bool)` / `toggleDevTools()` / `setDevToolsTab(DevToolsTab)`
- `getDevToolsState() *DevToolsState(MessageT)`

Animation:

- `registerAnimation(AnimationEntry) !void` — call after `setRootBuilder` so the target id is resolvable.

File dialog (NFD):

- `openFileDialog(filter_list_zlit, callback)` — runs in concurrent task; callback returns a `MessageType` posted on completion.
- `finalizeFileDialog()`

Static asset bundles:

- `loadStaticAssets(comptime AssetEnum, std.EnumArray(AssetEnum, StaticAsset)) !void`

Platform:

- `registerGlobalHotkey(modifier, key, HotkeyFn) !void`

## UIContext

`UIContext(MessageT)` (`src/ui/context.zig`). Exposed via `lib.For(M).UIContext` or `lib.UIContext(M)`.

Node factories (descriptor structs live in `src/ui/node.zig`):

- `div(.{...}) !*Node`
- `text(.{ .content, .font, .style })`
- `image(.{ .source, .style })`
- `asyncImage(.{ .source, .alt_text, .alt_font, .style })`
- `button(.{ .label, .font, .style, .on_click_msg })`
- `textInput(.{ .id, .font, .initial_text, .style, ...})`
- `canvas(.{ .canvas, .style, ...})`
- `fragment(children)`

Imperative:

- `getById(NodeId) ?*Node`
- `setTheme(Theme) void`
- `requestLayout()` / `requestPaint()`
- `registerPostLayoutHook(...)` — fires after `arrangeNode`; can request a second layout pass within the same frame.

Per-frame allocators:

- `build_arena: std.heap.ArenaAllocator` — call `.allocator()` for descriptor-tree scratch.

## Components

`lib.components` (`src/ui/components/root.zig`) re-exports everything below. See `docs/user/components.md` for usage.

Descriptors / params: `SliderDescriptor`, `SliderParams`, `SliderSlot`, `CheckboxParams`, `CheckboxBoxStyle`, `RadioParams`, `RadioRingStyle`, `RadioDotStyle`, `RadioGroupDescriptor`, `RadioGroupContext`, `CheckboxGroupDescriptor`, `CheckboxGroupContext`, `DropdownParams`, `DropdownTriggerStyle`, `DropdownMenuStyle`, `DropdownItemStyle`, `ColorPickerDescriptor`, `ColorPickerContext`, `IconDescriptor`, `VideoPlayerDescriptor`, `VideoPlayerContext`, `AnimatedMediaDescriptor`, `AnimatedMediaContext`, `VirtualListDescriptor`, `VirtualListContext`, `VirtualListState`, `VirtualListAxis`, `TreeDescriptor`, `TreeContext`, `TreeItem`, `TreeDropPosition`, `TreeMessage`, `PlotDescriptor`, `PlotContext`, `PlotState`, `PlotSeries`, `PlotMsg`.

Free functions: `applyPlotMsg(state, msg)`, `applyTreeDrop(...)`, `collectTopLevelSelectedIds`, `applyVirtualListScrollDelta`, `scrollVirtualListToEnd`, `virtualListItemNodeId`, `updateColorPickerPlaneTexture`, `deriveChildId(parent, key)`.

Builder proxy: `Builder(MessageT)` — methods `slider`, `checkbox`, `radio`, `radioGroup`, `checkboxGroup`, `dropdown`, `colorPicker`, `icon`, `video`, `videoPlayer`, `animatedMedia`, `virtualList`, `tree`, `treeFromSource`, `plot`. Construct as `comp.Builder(M){ .ui = ui }`.

## Layout / style

- `layout` — full module. `Style`, `Spacing`, `Size`, `Border`, `CornerRadius`, etc.
- `Style` — re-exported top-level.
- `BoxSizing` (`.border_box`, `.content_box`)
- `GridTrack` (`.Auto`, `.{ .exact = px }`, `.{ .percent = p }`, `.{ .fr = n }`)
- `Transform` — `translate`/`scale`/`rotate`.
- `TransitionStyle` / `TransitionProperty` — declarative transitions on style.

## Theme

- `Theme.init([4]f32 brand_oklch, is_dark) Theme`
- `Theme.fromOklch(.{ .l, .c, .h, .a = 1.0 }, .dark|.light)`
- `Theme.switchMode(*Theme)`
- `SemanticTokens` — `bg_base`, `bg_surface`, `bg_elevated`, `text_main`, `text_muted`, `action_default`, `action_hover`, `status_success`, `border_subtle`, etc. (`src/ui/theme.zig`).
- `Palette` — `Palette.init(brand_oklch)` builds neutral/brand/success/warning/danger ramps.
- `palette` module re-exported.

## Color

- `Color.parse(comptime "#rrggbb" | "oklch(...)")` — comptime literal -> `[4]f32`.
- `Color.oklch(l, c, h, a)` — runtime constructor.
- `Color.oklchToRgb`, `hsvToRgb`, `rgbToHsv`, `rgbToHex`.

## Tailwind helper

`tw` module — opinionated style mixins (`text_xs`...`text_5xl`, `font_bold`, `flex_row`, `items_center`, `w_full`, `justify_between`, etc.). See `src/ui/tw.zig`.

## Animation

- `animation` module
- `EasingFunction` (`linear`, `ease_in`, `ease_in_out`, `step_start`, `step_end`, `.{ .cubic_bezier = ... }`, ...)
- `AnimationEntry`, `AnimatedValue`, `AnimatedProperty`

## Audio / video

- `audio_waveform.PeakSet` and `extractPeaks(allocator, path, num_buckets)`
- `audio_spectrum.Analyzer` — FFT + log-spaced bands.
- `VideoManager` — owns `*VideoPlayback` instances.
- `VideoPlayback` — per-stream demuxer/decoder pair.

## Renderer-adjacent

- `Canvas`, `PixelBuffer`, `renderer.PixelBuffer`
- `IconRegistry`, `IconId`, `hashIconId`
- `ImageIngressBudget` — backpressure knobs.
- `stb` — image decode glue.
- `FontSource`, `FontData`

## Window

- `WindowConfig`, `WindowContext`
- `HotkeyFn`
- `win32` module

## DevTools

- `DevToolsTab`, `DevToolsState`, `DevToolsTabModule`

## Types

- `Node`, `NodeId`, `InteractionMessage`, `UpdateAction`
- `PaintContext`, `PaintFn`, `paint_context` module
- `types` module — `EventBinding`, etc.
- `bench_prefetch` — micro-bench helpers used by `examples/benchmarks/`.
- `assets` — `getFontData(.jetbrains_mono)`, `getTextureData(id)`, `StaticAsset`, `StaticAssetPayload`.
- `glfw` — re-exported GLFW binding for key/mod constants.
- `tracy_impl` — exposed so example/main translation units can wire profiler init.
