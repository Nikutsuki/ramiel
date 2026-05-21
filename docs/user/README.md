# User Docs

For library consumers building apps with `ramiel`.

## Start here

1. [Quickstart](quickstart.md)
2. [App lifecycle](app-lifecycle.md)
3. [Runtime helpers](runtime-helpers.md) — `Runtime`, `For`, `declareIds`, `bindTag`
4. [Styling and layout](styling-and-layout.md)
5. [Theme](theme.md)
6. [Animations](animations.md)
7. [Events and input](events-and-input.md)
8. [Async and image loading](async-fetching-and-images.md)
9. [Dynamic UI and lists](dynamic-ui-and-lists.md)
10. [Text and fonts](text-and-fonts.md)
11. [Components](components.md)
12. [Audio](audio.md)
13. [Video](video.md)
14. [Plot](plot.md)
15. [Canvas and custom rendering](canvas-and-custom-rendering.md)
16. [GPU shaders](gpu-shaders.md) — runtime GLSL compute/fragment shaders
17. [Performance](performance.md)
18. [Platform overlay and hotkeys](platform-overlay-and-hotkeys.md)
19. [Linux notes](linux-notes.md)
20. [Extending components](extending-components.md)
21. [Best practices](best-practices.md)
22. [API reference](api-reference.md)

## Examples

| Directory | What it shows |
|---|---|
| `examples/animation/` | Style transitions + explicit `registerAnimation` entries |
| `examples/audio_player/` | AudioEngine + spectrum analyzer + waveform peaks + bare-mode plot |
| `examples/box_sizing/` | Minimal app shape; `border_box` vs `content_box` |
| `examples/canvas_app/` | Canvas + worker pool + CPU and GPU image filters |
| `examples/components_showcase/` | Slider/checkbox/radio/dropdown/color picker/icon |
| `examples/discord_client/` | Full app: themed UI, virtual list, async images, gateway |
| `examples/file_explorer/` | Tree component, lazy loading, drag/drop, nav history |
| `examples/overlay/` | Transparent topmost window + global hotkey toggle |
| `examples/plot/` | Line / bar / scatter, follow mode, keyboard reset |
| `examples/shader_canvas/` | Runtime compute shaders cycling image filters |
| `examples/shader_background/` | Fragment-shader background that resizes with the window |
| `examples/pointer_capture/` | Drag + pointer capture + cursor lock |
| `examples/tree/` | Minimal tree component usage |
| `examples/video_player/` | Video subsystem + `videoPlayer` component |
| `examples/benchmarks/` | `zig build bench` micro-benchmarks |

`examples/file_explorer/README.md` has reusable patterns (lazy trees, nav history, arena-per-view).
