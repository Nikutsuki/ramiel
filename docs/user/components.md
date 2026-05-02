# Components

Catalog. Each lives in `src/ui/components/<name>.zig`, re-exported via `lib.components`. Build through `comp.Builder(MessageT){ .ui = ui }`.

State lives in your `AppState`. Components take a logic struct (state pointer + callback slots) and a descriptor struct (style overrides). Wire callbacks via `lib.bindTag(MessageT, ValueT, .tag)` instead of writing trampolines.

## slider

`SliderParams(MessageT)`: `base_id`, `value: f32 (0..1)`, `on_change: *const fn(f32, ?*const anyopaque) MessageT`, `userdata`, plus `track`/`fill`/`handle` `SliderSlot` style overrides.

```zig
try b.slider(.{
    .base_id = ids.volume,
    .value = state.volume,
    .on_change = lib.bindTag(AppMessage, f32, .volume_changed),
});
```

`src/ui/components/slider.zig`. Pointer capture + drag built in.

## checkbox

`CheckboxParams(MessageT)`: `base_id`, `checked: bool`, `on_toggle: MessageT`, optional `label`, `font`, `style`, `label_style`, `box: BoxStyle = .{ .style, .active_color, .inactive_color }`. `on_toggle` is a plain message value — use `lib.bindStatic` if you need it computed. `src/ui/components/checkbox.zig`.

## checkbox_group

`CheckboxGroupContext(MessageT)` + `CheckboxGroupDescriptor`. Shared state; emits per-item toggle messages. `src/ui/components/checkbox_group.zig`.

## radio

`RadioParams(MessageT)`: `base_id`, `selected: bool`, `on_select: MessageT`, optional `label`, `font`, `style`, `label_style`, `ring: RingStyle`, `dot: DotStyle`. `on_select` is a plain message, not a function.

## radio_group

Single selection across N items. `RadioGroupContext` carries `selected_index` + `on_select`; `RadioGroupDescriptor` styles options.

## dropdown

`DropdownParams(MessageT)`: `base_id`, `is_open: bool`, `active_index: usize`, `options: []const []const u8`, `font: *FontData`, `on_toggle: *const fn(bool, ?*const anyopaque) MessageT`, `on_select: *const fn(usize, ?*const anyopaque) MessageT`, optional `userdata`, plus `style`/`trigger: TriggerStyle`/`menu: MenuStyle`/`item: ItemStyle`. Menu node uses `position = .absolute` and lifts on z-index.

## color_picker

`ColorPickerContext(MessageT)` (current OKLCH + callbacks) + `ColorPickerDescriptor` (sizing). HSV plane texture is owned by the app — call `comp.updateColorPickerPlaneTexture(...)` when hue changes. See `examples/components_showcase/main.zig`.

## icon

`IconDescriptor`: `icon_id: u32`, `intrinsic_size: [2]f32` (required), `scale: f32 = 1.0`, `style: Style = .{}`, `tint: [4]f32 = .{1,1,1,1}`, `fallback_state`, `alt_text`, `alt_font`. Resolves through `icon_registry`; `ui.icon_resolver` must be wired. Pre-load with `app.loadIconSvgFromMemory` / `app.loadIconPngFromMemory`.

## virtual_list

Windowed renderer with Fenwick-tree size cache and slot-pooled wrappers. `VirtualListContext(MessageT)` carries `state: *VirtualListState`, `item_count`, `axis`, `build_item: *const fn(...) !*Node`, scroll callbacks. `VirtualListDescriptor` styles the viewport.

```zig
try b.virtualList(.{
    .state = &state.list,
    .item_count = state.rows.len,
    .axis = .vertical,
    .base_id = ids.list,
    .build_item = buildRow,
    .on_scroll = lib.bindTag(AppMessage, f32, .list_scrolled),
}, .{ .style = .{ .width = .Full, .height = .Full } });
```

Use `comp.virtualListItemNodeId(base, i)` for stable per-row IDs. `applyVirtualListScrollDelta` and `scrollVirtualListToEnd` are imperative helpers. `src/ui/components/virtual_list.zig`.

## tree

Hierarchical view with drag/drop. Two entry points:

- `b.tree(logic, visuals)` — you flatten + supply rows.
- `b.treeFromSource(ItemT, &tree_state, root_items, logic, visuals)` — items shaped `{ id, children, is_group }`; the component flattens and drives `build_row_content`.

`TreeMessage` union covers `.click`, `.toggle`, `.drag_start`, `.drop`, `.tick`. Reconcile messages before delegating to `comp.tree.update` for lazy loading. `examples/file_explorer/` and `examples/tree/main.zig`.

## plot

`PlotContext(MessageT)`: `base_id`, `state: *PlotState`, `on_change: ?*const fn(PlotMsg, ?*) MessageT`, `userdata`. `PlotDescriptor` controls margins, grid colors, crosshair, `bare` mode.

`PlotState.series: []const PlotSeries` — each series declares `xs`, `ys`, `kind` (`.line | .bar | .scatter`), `color`, etc. `applyPlotMsg(state, msg)` integrates pan/zoom/hover into state from your reducer.

```zig
try b.plot(.{
    .base_id = ids.plot,
    .state = &state.plot_state,
    .on_change = lib.bindTag(AppMessage, comp.PlotMsg, .plot_msg),
}, .{ .style = .{ .width = .Full, .height = .{ .exact = 240 } } });
```

See `docs/user/plot.md`. `examples/plot/main.zig`, `examples/audio_player/main.zig`.

## video_player

`VideoPlayerDescriptor`: `base_id`, `font`, plus styling for controls, sliders, icon buttons. `VideoPlayerContext(MessageT)`: `playback: *const VideoPlayback`, `progress`, `volume`, `is_hovered`, `on_play_toggle`, `on_seek`, `on_volume`, `on_hover_enter/leave`. Hover-aware overlay; mute/unmute remembers previous volume. `examples/video_player/main.zig`.

## animated_media

Lighter surface than `video_player` for autoplaying short loops (GIFs/short MP4s). Takes `*VideoPlayback`, `AnimatedMediaDescriptor`, `AnimatedMediaContext(MessageT)`.

## Component IDs

Use `comp.deriveChildId(parent_id, "key")` for stable per-child IDs inside a custom component. Pairs with `lib.declareIds`.
