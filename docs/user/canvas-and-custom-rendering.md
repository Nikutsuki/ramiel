# Canvas and Custom Rendering

`Canvas` is a GPU texture mapped to a `*Node` payload; you mutate a CPU-side `PixelBuffer` and call `markDirty()` to queue a re-upload.

## Allocation

```zig
// Blank GPU-backed texture, library owns the pixel buffer:
const canvas = try app.createCanvas(640, 480);

// Or wrap an existing PixelBuffer (you keep ownership of the buffer):
const buf = try lib.PixelBuffer.initBlank(allocator, 640, 480);
const canvas = try app.createCanvasFromBuffer(buf);
```

`Application.destroyCanvas(canvas)` detaches it from the tree, waits for GPU idle, frees GPU resources.

## Display

```zig
try ui.canvas(.{
    .canvas = state.my_canvas.?,
    .style = .{ .width = .Full, .height = .Full },
    .on_pointer_move_msg = .canvas_pointer_move,
});
```

## Mutation

```zig
const pixels = canvas.getRawPixels();
const idx: usize = @intCast((y * canvas.width + x) * 4);
pixels[idx + 0] = r;
pixels[idx + 1] = g;
pixels[idx + 2] = b;
pixels[idx + 3] = a;
canvas.markDirty();
return .repaint;
```

`.repaint` skips rebuild and layout — exactly what you want for brush strokes.

## Worker offload

For heavy ops (filters, blurs), submit to a worker and post results back via `app.ui.interaction_registry.postExternalMessage`. Worker mutates a secondary buffer or the canvas pixels (with the usual cross-thread caveats — don't tear). Reducer applies + `markDirty` + `.repaint`.

```zig
.filter_done => {
    if (state.my_canvas) |canvas| {
        canvas.markDirty();
        return .repaint;
    }
    return .none;
}
```

See `examples/canvas_app/worker.zig` for the full pattern.

## References

- `src/renderer/canvas.zig`
- `src/renderer/pixel_buffer.zig`
- `src/app.zig:186` (`createCanvas`)
- `src/app.zig:202` (`createCanvasFromBuffer`)
- `examples/canvas_app/`
