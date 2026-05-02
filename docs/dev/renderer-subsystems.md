# Renderer Subsystems

`src/renderer/`. Vulkan engine plus async ingress for images and font atlases.

## Engine

`src/renderer/vulkan/engine.zig` — owns:

- `Core` — instance, device, queues.
- `Swapchain` + `FrameManager` — N in-flight frames.
- `RenderGraph` — render passes (UI, video, blur, devtools).
- `TextureRegistry` — image texture indices + state.
- `processPendingTextureUploads` — runs queued image uploads.
- `draw(batcher, canvases, video_manager, font_registry)` — submits the frame.

## Quad batcher

`src/renderer/vulkan/batcher.zig`. Accumulates per-frame:

- Layered draw commands.
- Vertex/index buffers (uploaded into a frame-local arena).
- Scissor stack for clipping.
- Z-index ordering hints (per-node `z_index` + render-time push).

## Texture registry

`src/renderer/vulkan/texture_registry.zig`. Two id spaces:

- Built-in `TextureId` (blank canvas, blur material, sdf, text).
- Dynamic image IDs by string key. `getImageId(name)` returns a fallback id for assets still decoding/missing.

`pushImageData(name, compressed_bytes)` queues a decode + upload. Thread-safe.

## Image ingress

`src/renderer/image_ingress.zig`. Background fetcher.

- `io.concurrent` task primary; falls back to `io.async`.
- Dedup by image key via `request_mutex`.
- Backpressure budgets: max in-flight requests, max in-flight bytes, max pending upload bytes (see `ImageIngressBudget`).
- HTTP fetches serialized through an internal `http_mutex`.
- Pushes compressed bytes into `texture_registry` on completion.

## Font system

`src/renderer/font/`:

- `font_registry.zig` — FreeType + HarfBuzz + MSDF atlas generation. `FontData` per loaded face/size.
- `text_layouter.zig` — measurement + shaping; fills `layout_result.text_cache` during layout.
- `font_system.zig` — orchestration, fallback chain, atlas eviction.

Text shaping is a layout-phase task. Render reads cached glyph metrics — never re-shapes.

## Canvas

`src/renderer/canvas.zig`. CPU `PixelBuffer` (`pixel_buffer.zig`) + GPU texture. `markDirty()` queues an upload; `engine.draw` consumes the dirty list per frame.

## Icons

`src/renderer/icon/registry.zig`. SVG (resvg) + PNG decoded into MSDF / pre-rasterized atlas slices keyed by `(icon_id, scale)`.

## Image animations

`src/renderer/image_animation.zig`. Animated PNG/GIF state — frame timing + cursor. Layout reads `min_animated_frame_ms` to pick a wait timeout that keeps animations smooth without spinning.

## Ownership map

- `Application` owns engine, font system, batcher, audio engine, video manager, icon registry.
- `UIContext` owns the retained node tree, animation registry, interaction registry.
- Render phase: `ui.render(&batcher, ...)` -> `engine.draw(&batcher, canvases, video_manager, font_registry)`.

## References

- `src/renderer/vulkan/engine.zig`
- `src/renderer/vulkan/batcher.zig`
- `src/renderer/vulkan/texture_registry.zig`
- `src/renderer/image_ingress.zig`
- `src/renderer/font/`
