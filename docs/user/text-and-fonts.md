# Text and Fonts

## Loading fonts

Load a font before running UI builds:

```zig
const font = try app.loadFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 16);
```

`FontSource` options:

- `.{ .memory = bytes }`
- `.{ .path = "path/to/font.ttf" }`

## Text nodes

Create static text with `ui.text`:

```zig
try ui.text(.{
    .content = "Hello",
    .font = font,
    .style = .{ .text_color = .{ 1, 1, 1, 1 } },
})
```

Useful text style fields:

- `text_color`
- `font_weight`
- `white_space` (`Normal`, `NoWrap`)
- `text_overflow` (`Clip`, `Ellipsis`)
- `line_height`

## Text input nodes

Create editable input with `ui.textInput`:

```zig
try ui.textInput(.{
    .id = NodeIds.input,
    .font = font,
    .initial_text = "",
    .on_key_down_msg = Msg.input_key,
    .on_text_input_msg = Msg.input_change,
    .style = .{
        .width = .Full,
        .height = .{ .exact = 40 },
        .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 },
    },
})
```

Live text buffer is in `node.payload.text_input.buffer`.

## Text rendering model

- Text shaping and metrics are computed during layout.
- Render phase consumes cached glyph metrics.

This split keeps text rendering fast in the frame loop.

## Built-in asset helpers

The library includes `assets.getFontData` and `assets.getTextureData` for embedded resources in this repository.
