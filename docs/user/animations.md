# Animations and Transitions

Two paths:

- Declarative `Style.transition` — diffed during reconcile.
- Explicit `AnimationEntry` — registered imperatively after mount.

## Style transitions

```zig
.style = .{
    .background_color = .{ 0.2, 0.45, 0.8, 1.0 },
    .hover_color = .{ 0.3, 0.55, 0.9, 1.0 },
    .transition = .{
        .property = .{ .hover_color = true, .background_color = true },
        .duration_ms = 200,
        .timing = .ease_out,
    },
}
```

When reconcile sees a value change for a property whose `TransitionProperty` bit is set, it registers an interpolation.

Helpers (`TransitionStyle`):

- `forColors(ms)`
- `forOpacity(ms)`
- `forShadow(ms)`
- `forTransform(ms)`
- `forAll(ms)`

## Explicit entries

`AnimationEntry` shape (`src/animation/registry.zig:54`):

```zig
try app.registerAnimation(.{
    .node_id = ids.spinner,
    .value = .{ .rotate = .{ .from = 0.0, .to = std.math.tau } },
    .start_time = lib.glfw.getTime(),
    .duration = 2.0,
    .delay = 0.0,
    .timing = .ease_in_out,
    .looping = true,
});
```

`start_time` is absolute `glfw.getTime()` seconds. Animation begins at `start_time + delay`. Target node must have a stable `NodeId` (use `lib.declareIds`) and must exist in the retained tree — register after `setRootBuilder` + `mountRoot` (or after the first frame).

## Easing

`EasingFunction` variants:

- `linear`, `ease`, `ease_in`, `ease_out`, `ease_in_out`
- `step_start`, `step_end`
- `.{ .cubic_bezier = .{ .x1 = ..., .y1 = ..., .x2 = ..., .y2 = ... } }`

## Animatable properties

`AnimatedProperty` enum:

`background_color`, `hover_color`, `text_color`, `border_color`, `outline_color`, `shadow_color`, `opacity`, `shadow_blur`, `shadow_offset`, `corner_radius`, `blur`, `backdrop_blur`, `translate`, `scale`, `rotate`.

Color/radii animations carry `[4]f32`; vec2 carries `[2]f32`; scalars carry `f32`.

## Notes

- Active animations keep paint dirty; `tick()` returns true while any are running.
- Property interruption is smooth: starting a new animation for the same node/property snapshots the current interpolated value as the new `from`.

## References

- `src/animation/registry.zig`
- `src/animation/easing.zig`
- `examples/animation/main.zig`
