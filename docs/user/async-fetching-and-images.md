# Async, Fetching, and Image Loading

There are two main async patterns:

- Built-in async image loading (disk and HTTP)
- External worker thread messages back into UI (`postExternalMessage`)

## Async image APIs on `Application`

- `loadImageFromDiskAsync(name, path, max_bytes)`
- `loadImageFromDiskAsyncSized(name, path, target_width, target_height)`
- `loadImageFromUrlAsync(name, url, max_bytes)`
- `loadImageFromUrlAsyncSized(name, url, target_width, target_height)`
- `setImageIngressBudget(ImageIngressBudget)`
- `getImageState(name)`
- `getResolvedImageState(name)`

`ImageIngressBudget` controls request/byte backpressure:

- `max_inflight_requests`
- `max_inflight_bytes`
- `max_pending_upload_bytes`

## Rendering async images

Use `ui.asyncImage` in your tree:

```zig
try ui.asyncImage(.{
    .source = item.full_path,
    .alt_text = item.filename,
    .alt_font = font,
    .style = .{
        .width = .{ .exact = 100 },
        .height = .{ .exact = 100 },
    },
})
```

The image resolver (wired by `Application`) maps source key to texture state and ID.

Fallback state transitions are:

- `missing`
- `decoding`
- `ready`

## Practical loading pattern

1. Queue load requests in reducer/build side logic.
2. Build rows using `asyncImage` by source key.
3. As uploads complete, the app marks paint dirty and can trigger rebuild as needed.

This pattern is used by `examples/overlay/main.zig` for file preview thumbnails.

## Custom async fetching pattern

For non-image async work (network, filesystem, SDK callbacks), send results into UI with:

- `ui.interaction_registry.postExternalMessage(msg)`

Then return to the main loop and handle the message in your reducer. If your callback runs off-thread, also wake event wait with `glfw.postEmptyEvent()` when needed.

`examples/overlay/main.zig` shows this pattern in `onSearchResultsReady`.

## Notes

- Image loading uses background tasks (`std.Io.concurrent` with fallback to `std.Io.async`).
- HTTP image fetches are serialized through an internal HTTP client mutex for thread-safe access.
