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

Single-selection picker: a trigger button shows the current label; clicking opens a popup menu of
options. State (`is_open`, `active_index`, option labels) lives in **your** app — the component is
stateless and re-reads params every rebuild.

`DropdownParams(MessageT)`:

| field | role |
|---|---|
| `base_id` | Stable root id (`lib.declareIds`) |
| `is_open` | Whether the menu portal is rendered |
| `active_index` | Index into `options` shown on the trigger and highlighted in the menu |
| `options` | `[]const []const u8` labels (trigger + one row each) |
| `on_toggle` | `fn(bool, ?*const anyopaque) MessageT` — open (`true`) / close (`false`) |
| `on_select` | `fn(usize, ?*const anyopaque) MessageT` — user picked option `i` |
| `userdata` | Opaque pointer forwarded to both callbacks |
| `font` | Optional label font |
| `style` | Root wrapper (`direction` forced to column) |
| `trigger` | `TriggerStyle{ .style }` — the closed-state button |
| `menu` | `MenuStyle{ .style }` — the open popup panel |
| `item` | `ItemStyle{ .style, .active_color, .hover_color }` — per-row styling |

### Behaviour

1. **Closed** — trigger shows `options[active_index]` (or `""` when empty / out of range).
2. **Trigger click** — emits `on_toggle(!is_open, userdata)`; your reducer sets `is_open` and rebuilds.
3. **Open** — renders a `portal` with:
   - full-screen **backdrop** (click → `on_toggle(false, …)`),
   - **menu** anchored below the trigger (`position = .anchored`, `anchor_id = trigger`, `z_index = 1000`).
4. **Row click** — emits `on_select(i, userdata)` with the row index baked in at build time; you
   typically set `active_index = i`, `is_open = false`, and rebuild.

Callbacks return a `MessageT` value that is embedded into click bindings during `build` (not called
at click time). Wire them with `lib.bindTag` in standalone apps:

```zig
const options = [_][]const u8{ "Windowed", "Borderless", "Fullscreen" };

try b.dropdown(.{
    .base_id = ids.display_mode,
    .is_open = state.dropdown_open,
    .active_index = state.dropdown_selected,
    .options = &options,
    .on_toggle = lib.bindTag(AppMessage, bool, .dropdown_toggle),
    .on_select = lib.bindTag(AppMessage, usize, .dropdown_select),
    .font = font,
    .trigger = .{ .style = tw.style(.{ tw.w_full, tw.px(8), tw.py(6) }) },
    .menu = .{ .style = tw.style(.{ tw.rounded(8), tw.p(1) }) },
    .item = .{ .style = tw.style(.{ tw.px(8), tw.py(6), tw.rounded(4) }) },
});
```

Reducer:

```zig
.dropdown_toggle => |open| { state.dropdown_open = open; return .rebuild; },
.dropdown_select => |idx| {
    if (idx < options.len) state.dropdown_selected = idx;
    state.dropdown_open = false;
    return .rebuild;
},
```

See `examples/components_showcase/main.zig` (display-mode dropdown).

### Scrollable menus

The dropdown renders **every option as a real row** (no virtualization). For a long but modest list,
cap menu height and enable overflow scroll on `menu.style`:

```zig
.menu = .{ .style = tw.style(.{
    tw.max_h(240),
    tw.overflow_y_scroll,
}) },
```

Wheel / drag scrolling uses the normal layout overflow path. There is no built-in keyboard
navigation. For hundreds of rows or search/filter, use `virtualList` instead.

### Embedded hosts (e.g. Rei panels)

When `MessageT` is a closed union you do not control, return messages your host already understands
(e.g. `.command = .{ .id = "…", .args = … }`) from hand-written `on_toggle` / `on_select` functions
instead of `lib.bindTag`. `CommandInvoke` slice fields are not copied — args must outlive dispatch
(use stable strings from your state or the build arena).

`src/ui/components/dropdown.zig`.

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
