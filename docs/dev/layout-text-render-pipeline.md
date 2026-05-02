# Layout, Text, Render Pipeline

How geometry, text shaping, and Vulkan submission compose.

## Layout

`src/ui/layout.zig`.

- `measureNode(node, ...)` — computes intrinsic + content sizes; for text nodes runs HarfBuzz shaping into `layout_result.text_cache`.
- `arrangeNode(node, x, y, w, h)` — resolves flex/grid/absolute positions into absolute coordinates.
- `calculateLayout` (`ui.calculateLayout(text_layouter, fb_w, fb_h)`) — pair of passes wrapped in animation-value application + post-layout hooks.

Box model:

- `padding`, `border` are insets relative to outer box.
- `box_sizing` controls whether stated `width`/`height` is outer or content.
- `margin` applies between siblings; absolute children ignore flex margin collapse.

Overflow:

- `overflow_x/y = .scroll` enables interaction-driven scrolling; scroll bounds = `content - viewport`.
- Scrollbar geometry derived from viewport/content ratio; thumb position from `scroll_offset`.

## Text pipeline split

Layout-phase work:

- HarfBuzz shaping per (font, size, content).
- Glyph metrics cached: `render_x`, `render_y`, UVs, visibility, line breaks.

Render-phase work:

- Read cached metrics; emit textured quads through the batcher.
- Never re-shape.

This is the single largest perf invariant. Text reshape inside render is forbidden.

## Render

`src/ui/node.zig::render`. For each node, in order:

1. Apply transform (translate / scale / rotate).
2. Push scissor / mask if `overflow != .visible`.
3. Emit shadow → background → border → outline.
4. Emit payload (image, text, text_input, canvas, video).
5. Recurse children.
6. Pop scissor / transform.

Opacity is multiplicative through the subtree.

## Animation timing

`animation_registry.applyAnimatedValuesToTree(root, time)` runs immediately before each layout pass and immediately before render. Style fields it touches: paint properties (colors, opacity, shadow, blur, corner radius), transform (translate/scale/rotate). Layout-affecting animations (currently none in the registry — translate is a transform, not a flex resize) would set `hasLayoutAnimations()` and force a layout pass.

## References

- `src/ui/layout.zig`
- `src/ui/node.zig`
- `src/ui/context.zig::calculateLayout`
- `src/animation/registry.zig::applyAnimatedValuesToTree`
