# Plot

Real-time plot component. Line / bar / scatter, multi-series, log-spaced LOD, follow-mode for streaming, crosshair tooltip, bare mode for inline sparklines.

## Surface

`comp.plot` (`src/ui/components/plot.zig`).

`PlotContext(MessageT)`:

- `base_id: NodeId`
- `state: *PlotState`
- `on_change: ?*const fn(PlotMsg, ?*) MessageT`
- `userdata: ?*const anyopaque`

`PlotDescriptor`:

- `style: Style`
- colors: `background_color`, `grid_color`, `axis_color`, `crosshair_color`
- `target_grid_lines_x/y`
- margins: `margin_left/right/top/bottom`
- `axis_label_style`, `axis_font: ?*FontData`
- `enable_pan`, `enable_zoom`, `zoom_modifier: ZoomModifier (.none | .ctrl | .shift | .alt)`
- `show_crosshair: bool`
- `bare: bool` — drops margins/axes/labels for sparkline use.

## Series

`PlotSeries`:

```zig
.{
    .xs = state.xs,
    .ys = state.ys,
    .kind = .line,            // .line | .bar | .scatter
    .color = .{ 0.4, 0.7, 1.0, 1.0 },
    .line_width = 1.5,
    .point_size = 0.0,
    .label = "rate",
    .bar_baseline = 0.0,
    .bar_gap = 0.0,
    .is_monotonic_x = true,   // false for scatter
}
```

`is_monotonic_x = true` enables binary-search clip to the viewport — set false for unsorted scatter data.

## State + axis modes

`PlotState` carries view bounds, axis modes, follow window, hover state, LOD pyramid.

```zig
state.x_mode = .{ .follow = 10.0 }; // last 10 seconds
state.y_mode = .fixed;
state.setYRange(-1.5, 1.5);
state.setSeries(&.{ .{ .xs = ..., .ys = ..., .kind = .line } });
```

`AxisMode`: `.auto`, `.fixed`, `.{ .follow = window_size }`. Follow mode auto-reattaches to the latest data when new samples arrive.

## LOD

`PlotLod` (`src/ui/components/plot.zig:123`) builds a min/max pyramid for series. Long series (10k+ points) draw correctly without per-frame full traversal.

## Reducer integration

Plot emits `PlotMsg`:

```zig
PlotMsg = union(enum) {
    pan: struct { dx: f32, dy: f32 },
    zoom: struct { delta: f32, focus_x: f32, focus_y: f32 },
    hover: ?struct { x: f64, y: f64 },
};
```

Apply via `comp.applyPlotMsg(state, msg)` in the reducer:

```zig
.plot_msg => |pm| {
    comp.applyPlotMsg(&state.plot_state, pm);
    return .repaint;
},
```

## Bare mode

`PlotDescriptor.bare = true` drops axes, labels, margins, crosshair. Use for inline sparklines (e.g. embedded inside a virtual list row). `examples/audio_player/` uses bare-mode bar plots for the spectrum + waveform.

## References

- `src/ui/components/plot.zig`
- `examples/plot/main.zig`
- `examples/audio_player/main.zig`
