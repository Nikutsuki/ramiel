# Styling and Layout

All visual and layout behavior is driven by `layout.Style`.

## Style foundations

Important defaults:

- `display = .flex`
- `direction = .Column`
- `box_sizing = .border_box`
- `position = .relative`
- `pointer_events = .auto`

## Sizing model

`Style.width` and `Style.height` use `layout.Size`:

- `.Auto`
- `.Full`
- `.{ .percent = 0.5 }`
- `.{ .exact = 320 }`
- `.screen` (legacy fill alias)

Constraints are available on both axes:

- `min_width`, `max_width`
- `min_height`, `max_height`

## Flex layout

Flex controls:

- `direction`: `.Row` or `.Column`
- `align_items`: `.Start`, `.Center`, `.End`, `.Stretch`
- `justify_content`: `.Start`, `.Center`, `.End`, `.SpaceBetween`, `.SpaceAround`
- `flex_grow`, `flex_shrink`
- `gap`

## Grid layout

Enable grid with:

- `display = .grid`

Configure tracks with:

- `grid_template_columns`
- `grid_template_rows`
- `grid_auto_rows`

Track units (`GridTrack`):

- `.Auto`
- `.{ .exact = px }`
- `.{ .percent = p }`
- `.{ .fr = n }`

Child placement fields:

- `grid_column_start`, `grid_row_start`
- `grid_column_span`, `grid_row_span`

## Box model

Spacing fields:

- `padding: Spacing`
- `margin: Spacing`

Helpers:

- `Spacing.all(value)`

Border and outline:

- `border: Border`
- `outline: Border`
- `Border.all(width, color)`

Corner radius:

- `corner_radius: CornerRadius`
- `CornerRadius.all(radius)`

## Positioning and overflow

Positioning:

- `position = .relative` or `.absolute`
- offsets: `top`, `right`, `bottom`, `left`

Overflow:

- `overflow_x`, `overflow_y`: `.visible`, `.hidden`, `.scroll`
- scrollbars can be styled with `scrollbar_width`, `scrollbar_min_height`, `scrollbar_color`, `scrollbar_radius`

## Visual style fields

- `background_color`
- `hover_color`
- `text_color`
- `opacity`
- `shadow_color`, `shadow_offset`, `shadow_blur`
- `blur`, `backdrop_blur`
- `transform` (`translate`, `scale`, `rotate`)

## Input and hit testing style fields

- `cursor` (`default`, `pointer`, `text`, `crosshair`, `ns_resize`, `ew_resize`)
- `pointer_events` (`auto`, `none`)
- `z_index`

## Example style block

```zig
.style = .{
    .width = .Full,
    .height = .{ .exact = 56 },
    .direction = .Row,
    .align_items = .Center,
    .justify_content = .SpaceBetween,
    .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
    .background_color = .{ 0.12, 0.14, 0.2, 0.95 },
    .border = layout.Border.all(1, .{ 0.28, 0.32, 0.45, 1.0 }),
    .corner_radius = layout.CornerRadius.all(8),
    .overflow_x = .hidden,
    .overflow_y = .scroll,
}
```

## References

- `examples/box_sizing/main.zig`
- `examples/overlay/main.zig`
