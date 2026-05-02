# Performance

Hot-path rules. The renderer runs every monitor refresh — invariants that look pedantic compound into stutter when broken.

## Don't allocate in render

`UIContext.render` consumes cached layout state. Anything you allocate inside paint paths shows up as per-frame garbage. Style/text changes go through layout.

## Don't reshape text in render

Text shaping is a layout-phase task: `measureNode` runs HarfBuzz, fills `layout_result.text_cache`. Render reads cached glyph metrics. If you find yourself touching shaping in a paint path, redesign — it is the single largest perf invariant.

## Pick the lightest UpdateAction

Reducer return values are ORed across the message drain:

- `.none` — sleep next frame.
- `.repaint` — render only. Right for canvas pixel mutations, animation tick.
- `.relayout` — layout + paint. Right for size/text changes when tree shape is the same.
- `.rebuild` — re-runs `build_fn` + reconcile + layout + paint. Default for structural change.

Don't blanket-return `.rebuild`. A slider drag emitting 60 `.rebuild`s/sec burns the build arena and reconcile pass when the slider is the only thing changing.

## `processPendingTextureUploads`

Async image ingress is split: workers decode + push compressed pixels into `texture_registry`; the main loop calls `processPendingTextureUploads` once per frame, runs the GPU upload, marks paint dirty. If uploads landed, the loop also queues a rebuild (the descriptor source -> texture index map may have moved). Don't push from worker threads outside of the registry API.

## virtual_list slot pooling

`virtual_list` keeps `MAX_POOL_SIZE` wrapper nodes alive across frames; an item at slot `s = i % MAX_POOL_SIZE` may carry a different item index next frame. Implication: `item_node.layout_result` is only meaningful for the current `i` *after* layout has run for the current frame. Anything that reads geometry from outside the post-layout hook is suspect.

## Post-layout hook

`UIContext.registerPostLayoutHook` is the sanctioned escape hatch for "I need fresh layout to compute something inside a component." Fires after `arrangeNode`, can return `true` to request a second layout pass within the same frame. Bound to 2 passes max. Used by `virtual_list` to consume freshly-measured item heights, patch wrapper offsets, warp scroll.

Use it before inventing new runtime hooks.

## Stable IDs

Anonymous nodes survive reconcile by structural position. Nodes with explicit IDs survive by ID. For stateful subtrees (text inputs, scroll containers, animated nodes) always use `lib.declareIds`. A loop body should use `comp.deriveChildId(parent, key)` keyed on data identity, not array index.

## bench_prefetch

`lib.bench_prefetch` (`src/ui/bench_prefetch.zig`) — micro-benchmarks for tree traversal + reconcile prefetch heuristics. Run via `zig build bench`.

## Idle behavior

`Application.run` sleeps in `glfw.waitEventsTimeout` when there's no work. Wake sources:

- input event
- `glfw.postEmptyEvent` from another thread (audio tap, image ingress, video tick)
- animation tick deadline
- `tick_interval_s` if set

Timeout is the min of all active deadlines — see `computeWaitTimeoutSeconds` (`src/app.zig:566`).

## References

- `src/app.zig`
- `src/ui/context.zig`
- `src/ui/components/virtual_list.zig`
- `src/ui/bench_prefetch.zig`
- `examples/benchmarks/reconcile_traverse.zig`
