# Theme

OKLCH-based palette + semantic tokens. One brand color generates the full palette and dark/light token sets.

## Construction

```zig
const theme = lib.Theme.fromOklch(.{ .l = 0.6, .c = 0.1, .h = 250.0 }, .dark);
```

Equivalent low-level form:

```zig
const theme = lib.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true);
```

`Theme` carries `palette: Palette`, `tokens: SemanticTokens`, `is_dark: bool`. App init uses `(0.6, 0.1, 250.0)` dark by default.

## Apply

```zig
app.updateTheme(theme);
// or, if you have *UIContext directly:
ui.setTheme(theme);
```

`Theme.switchMode(*Theme)` flips dark/light without rebuilding the palette.

## Palette

`Palette.init(brand_oklch)` derives:

- `brand` ramp (steps 50 → 900)
- `neutral` ramp
- `success` (green-ish), `warning` (yellow-ish), `danger` (red-ish) ramps

Each step is a `Color` (= `[4]f32` RGBA). Use them directly in styles:

```zig
.background_color = theme.palette.brand.step_500,
.text_color = theme.tokens.text_main,
```

## SemanticTokens

Pre-mapped roles (`src/ui/theme.zig:5`):

- backgrounds: `bg_base`, `bg_surface`, `bg_elevated`
- text: `text_main`, `text_muted`, `text_inverse`, `text_disabled`
- actions: `action_default`, `action_hover`, `action_pressed`, `action_disabled`
- status: `status_success`, `status_warning`, `status_danger`
- borders: `border_subtle`, `border_focus`

Components (slider, button, dropdown, tree) read from `ui.active_theme.tokens` so a theme switch repaints the whole UI consistently.

## Color helpers

`lib.Color`:

- `parse(comptime "#aabbcc")` / `parse(comptime "oklch(0.6 0.1 250)")` — comptime, returns `[4]f32`.
- `oklch(l, c, h, a)` — runtime constructor.
- `oklchToRgb`, `hsvToRgb`, `rgbToHsv`, `rgbToHex`.

```zig
.background_color = lib.Color.parse("#1a1f2e"),
.text_color = lib.Color.parse("oklch(0.95 0.02 250)"),
```

## tw — Tailwind-style mixins

`lib.tw` exposes pre-built style fragments. Compose with `Style.mix`, which takes a tuple of partial-struct literals and merges left-to-right:

```zig
.style = Style.mix(.{
    tw.flex_row,
    tw.items_center,
    tw.text_lg,
    tw.font_bold,
    .{ .gap = 12 },
}),
```

Available: `text_xs`..`text_5xl`, `font_light`..`font_ultra_bold`, `w_full`/`h_full`/`w_auto`/`h_auto`, `flex_row`/`flex_col`, `items_center`, `justify_center`/`justify_between`. `src/ui/tw.zig`. Zig 0.16 does not support struct spread, so always go through `Style.mix`.

## References

- `src/ui/theme.zig`
- `src/assets/palette.zig`
- `src/ui/color.zig`
- `src/ui/tw.zig`
- `examples/components_showcase/main.zig`
- `examples/discord_client/main.zig`
