const std = @import("std");
const color_parser = @import("color.zig");
const layout = @import("layout.zig");
const theme_mod = @import("theme.zig");

pub const Style = layout.Style;
pub const Size = layout.Size;
pub const Spacing = layout.Spacing;
pub const CornerRadius = layout.CornerRadius;
pub const Border = layout.Border;
pub const GridTrack = layout.GridTrack;
pub const GridTemplate = layout.GridTemplate;
pub const Transform = layout.Transform;
pub const TransitionStyle = layout.TransitionStyle;

pub const unit_px: f32 = 4.0;

pub fn unit(n: f32) f32 {
    return n * unit_px;
}

pub fn style(partials: anytype) Style {
    return apply(.{}, partials);
}

pub fn apply(base: Style, partials: anytype) Style {
    var result = base;
    applyPartials(&result, partials);
    return result;
}

pub fn styleTheme(tokens: theme_mod.SemanticTokens, partials: anytype) Style {
    return applyTheme(.{}, tokens, partials);
}

pub fn applyTheme(base: Style, tokens: theme_mod.SemanticTokens, partials: anytype) Style {
    var result = base;
    applyThemedPartials(&result, tokens, partials);
    return result;
}

fn applyPartials(result: *Style, partials: anytype) void {
    const info = @typeInfo(@TypeOf(partials));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            applyPartial(result, @field(partials, field.name));
        }
    } else {
        applyPartial(result, partials);
    }
}

fn applyThemedPartials(result: *Style, tokens: theme_mod.SemanticTokens, partials: anytype) void {
    const info = @typeInfo(@TypeOf(partials));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            applyThemedPartial(result, tokens, @field(partials, field.name));
        }
    } else {
        applyThemedPartial(result, tokens, partials);
    }
}

fn applyThemedPartial(result: *Style, tokens: theme_mod.SemanticTokens, partial: anytype) void {
    if (@TypeOf(partial) == ThemedPartial) {
        applyThemeToken(result, tokens, partial);
    } else {
        applyPartial(result, partial);
    }
}

fn applyPartial(result: *Style, partial: anytype) void {
    if (@TypeOf(partial) == ThemedPartial) {
        @compileError("theme-aware tw classes require active theme tokens; use uix `.class`, tw.styleTheme(tokens, ...), or tw.applyTheme(base, tokens, ...)");
    }

    const PartialT = @TypeOf(partial);
    const info = @typeInfo(PartialT);
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("tw.style expects style partial structs, e.g. `tw.style(.{ tw.flex_col, tw.p(4) })`");
    }

    inline for (info.@"struct".fields) |field| {
        if (!@hasField(Style, field.name)) {
            @compileError("Style has no field named '" ++ field.name ++ "'");
        }
        @field(result, field.name) = @as(@TypeOf(@field(result, field.name)), @field(partial, field.name));
    }
}

pub const ThemeColor = enum {
    bg_base,
    bg_surface,
    bg_elevated,
    bg_subtle,
    bg_overlay,
    text_main,
    text_muted,
    text_inverse,
    text_disabled,
    text_accent,
    action_default,
    action_hover,
    action_pressed,
    action_disabled,
    action_subtle,
    action_text,
    accent_default,
    accent_hover,
    accent_pressed,
    accent_subtle,
    accent_text,
    secondary_default,
    secondary_hover,
    secondary_pressed,
    secondary_subtle,
    secondary_text,
    status_success,
    status_success_bg,
    status_success_text,
    status_warning,
    status_warning_bg,
    status_warning_text,
    status_info,
    status_info_bg,
    status_info_text,
    status_danger,
    status_danger_bg,
    status_danger_text,
    border_subtle,
    border_strong,
    border_focus,
};

pub const ThemedProperty = enum {
    background_color,
    text_color,
    hover_color,
    border,
    border_t,
    border_r,
    border_b,
    border_l,
    outline,
    shadow,
};

pub const ThemedPartial = struct {
    property: ThemedProperty,
    token: ThemeColor,
    width: f32 = 1.0,
    offset: [2]f32 = .{ 0.0, 0.0 },
    blur: f32 = 0.0,
};

pub fn bg_token(token: ThemeColor) ThemedPartial {
    return .{ .property = .background_color, .token = token };
}

pub fn text_token(token: ThemeColor) ThemedPartial {
    return .{ .property = .text_color, .token = token };
}

pub fn hover_token(token: ThemeColor) ThemedPartial {
    return .{ .property = .hover_color, .token = token };
}

pub fn border_token(width: f32, token: ThemeColor) ThemedPartial {
    return .{ .property = .border, .token = token, .width = width };
}

pub fn border_t_token(width: f32, token: ThemeColor) ThemedPartial {
    return .{ .property = .border_t, .token = token, .width = width };
}

pub fn border_r_token(width: f32, token: ThemeColor) ThemedPartial {
    return .{ .property = .border_r, .token = token, .width = width };
}

pub fn border_b_token(width: f32, token: ThemeColor) ThemedPartial {
    return .{ .property = .border_b, .token = token, .width = width };
}

pub fn border_l_token(width: f32, token: ThemeColor) ThemedPartial {
    return .{ .property = .border_l, .token = token, .width = width };
}

pub fn outline_token(width: f32, token: ThemeColor) ThemedPartial {
    return .{ .property = .outline, .token = token, .width = width };
}

pub fn shadow_token(token: ThemeColor, offset: [2]f32, blur_px: f32) ThemedPartial {
    return .{ .property = .shadow, .token = token, .offset = offset, .blur = blur_px };
}

fn applyThemeToken(result: *Style, tokens: theme_mod.SemanticTokens, partial: ThemedPartial) void {
    const token_color = resolveThemeColor(tokens, partial.token);
    switch (partial.property) {
        .background_color => result.background_color = token_color,
        .text_color => result.text_color = token_color,
        .hover_color => result.hover_color = token_color,
        .border => result.border = Border.all(partial.width, token_color),
        .border_t => result.border.top = .{ .width = partial.width, .color = token_color },
        .border_r => result.border.right = .{ .width = partial.width, .color = token_color },
        .border_b => result.border.bottom = .{ .width = partial.width, .color = token_color },
        .border_l => result.border.left = .{ .width = partial.width, .color = token_color },
        .outline => result.outline = Border.all(partial.width, token_color),
        .shadow => {
            result.shadow_color = token_color;
            result.shadow_offset = partial.offset;
            result.shadow_blur = partial.blur;
        },
    }
}

pub fn resolveThemeColor(tokens: theme_mod.SemanticTokens, token: ThemeColor) [4]f32 {
    return switch (token) {
        inline else => |tag| @field(tokens, @tagName(tag)),
    };
}

pub fn color(comptime input_str: []const u8) [4]f32 {
    return comptime color_parser.parse(input_str);
}

pub fn rgba(r: f32, g: f32, b: f32, a: f32) [4]f32 {
    return .{ r, g, b, a };
}

pub fn rgb255(r: u8, g: u8, b: u8) [4]f32 {
    return rgba(@as(f32, @floatFromInt(r)) / 255.0, @as(f32, @floatFromInt(g)) / 255.0, @as(f32, @floatFromInt(b)) / 255.0, 1.0);
}

pub fn rgba255(r: u8, g: u8, b: u8, a: u8) [4]f32 {
    return rgba(
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    );
}

pub const transparent = color("#0000");
pub const white = color("#fff");
pub const black = color("#000");

pub const bg_base = bg_token(.bg_base);
pub const bg_surface = bg_token(.bg_surface);
pub const bg_elevated = bg_token(.bg_elevated);
pub const bg_subtle = bg_token(.bg_subtle);
pub const bg_overlay = bg_token(.bg_overlay);
pub const bg_action = bg_token(.action_default);
pub const bg_action_hover = bg_token(.action_hover);
pub const bg_action_pressed = bg_token(.action_pressed);
pub const bg_action_disabled = bg_token(.action_disabled);
pub const bg_action_subtle = bg_token(.action_subtle);
pub const bg_accent = bg_token(.accent_default);
pub const bg_accent_hover = bg_token(.accent_hover);
pub const bg_accent_pressed = bg_token(.accent_pressed);
pub const bg_accent_subtle = bg_token(.accent_subtle);
pub const bg_secondary = bg_token(.secondary_default);
pub const bg_secondary_hover = bg_token(.secondary_hover);
pub const bg_secondary_pressed = bg_token(.secondary_pressed);
pub const bg_secondary_subtle = bg_token(.secondary_subtle);
pub const bg_success = bg_token(.status_success);
pub const bg_success_subtle = bg_token(.status_success_bg);
pub const bg_warning = bg_token(.status_warning);
pub const bg_warning_subtle = bg_token(.status_warning_bg);
pub const bg_info = bg_token(.status_info);
pub const bg_info_subtle = bg_token(.status_info_bg);
pub const bg_danger = bg_token(.status_danger);
pub const bg_danger_subtle = bg_token(.status_danger_bg);

pub const text_main = text_token(.text_main);
pub const text_muted = text_token(.text_muted);
pub const text_inverse = text_token(.text_inverse);
pub const text_disabled = text_token(.text_disabled);
pub const text_accent = text_token(.text_accent);
pub const text_action = text_token(.action_default);
pub const text_action_on = text_token(.action_text);
pub const text_accent_on = text_token(.accent_text);
pub const text_secondary = text_token(.secondary_text);
pub const text_success = text_token(.status_success_text);
pub const text_warning = text_token(.status_warning_text);
pub const text_info = text_token(.status_info_text);
pub const text_danger = text_token(.status_danger_text);

pub const hover_action = hover_token(.action_hover);
pub const hover_action_default = hover_token(.action_default);
pub const hover_accent = hover_token(.accent_hover);
pub const hover_secondary = hover_token(.secondary_hover);
pub const hover_surface = hover_token(.bg_elevated);

pub const border_subtle = border_token(1.0, .border_subtle);
pub const border_strong = border_token(1.0, .border_strong);
pub const border_focus = border_token(1.0, .border_focus);
pub const border_action = border_token(1.0, .action_default);
pub const border_success = border_token(1.0, .status_success);
pub const border_warning = border_token(1.0, .status_warning);
pub const border_info = border_token(1.0, .status_info);
pub const border_danger = border_token(1.0, .status_danger);
pub const outline_focus = outline_token(2.0, .border_focus);

pub const text_xs = .{ .font_size = 12.0 };
pub const text_sm = .{ .font_size = 14.0 };
pub const text_base = .{ .font_size = 16.0 };
pub const text_lg = .{ .font_size = 18.0 };
pub const text_xl = .{ .font_size = 20.0 };
pub const text_2xl = .{ .font_size = 24.0 };
pub const text_3xl = .{ .font_size = 30.0 };
pub const text_4xl = .{ .font_size = 36.0 };
pub const text_5xl = .{ .font_size = 48.0 };

pub fn text(size_px: f32) struct { font_size: f32 } {
    return .{ .font_size = size_px };
}

pub fn leading(value_px: f32) struct { line_height: f32 } {
    return .{ .line_height = value_px };
}

pub fn text_color(comptime color_str: []const u8) struct { text_color: [4]f32 } {
    return .{ .text_color = color(color_str) };
}

pub fn text_color_value(color_value: [4]f32) struct { text_color: [4]f32 } {
    return .{ .text_color = color_value };
}

pub const font_light = .{ .font_weight = 0.3 };
pub const font_normal = .{ .font_weight = 0.5 };
pub const font_semibold = .{ .font_weight = 0.6 };
pub const font_bold = .{ .font_weight = 0.7 };
pub const font_ultra_bold = .{ .font_weight = 0.9 };
pub const whitespace_normal = .{ .white_space = layout.WhiteSpace.Normal };
pub const whitespace_nowrap = .{ .white_space = layout.WhiteSpace.NoWrap };
pub const text_clip = .{ .text_overflow = layout.TextOverflow.Clip };
pub const text_ellipsis = .{ .text_overflow = layout.TextOverflow.Ellipsis };

pub const flex = .{ .display = layout.Display.flex };
pub const block = .{ .display = layout.Display.block };
pub const grid = .{ .display = layout.Display.grid };
pub const hidden = .{ .display = layout.Display.none };
pub const flex_row = .{ .display = layout.Display.flex, .direction = layout.FlexDirection.Row };
pub const flex_col = .{ .display = layout.Display.flex, .direction = layout.FlexDirection.Column };
pub const flex_wrap = .{ .flex_wrap = layout.FlexWrap.Wrap };
pub const flex_nowrap = .{ .flex_wrap = layout.FlexWrap.NoWrap };

pub const items_start = .{ .align_items = layout.FlexAlign.Start };
pub const items_center = .{ .align_items = layout.FlexAlign.Center };
pub const items_end = .{ .align_items = layout.FlexAlign.End };
pub const items_stretch = .{ .align_items = layout.FlexAlign.Stretch };
pub const self_auto = .{ .align_self = layout.FlexAlignSelf.Auto };
pub const self_start = .{ .align_self = layout.FlexAlignSelf.Start };
pub const self_center = .{ .align_self = layout.FlexAlignSelf.Center };
pub const self_end = .{ .align_self = layout.FlexAlignSelf.End };
pub const self_stretch = .{ .align_self = layout.FlexAlignSelf.Stretch };
pub const justify_start = .{ .justify_content = layout.JustifyContent.Start };
pub const justify_center = .{ .justify_content = layout.JustifyContent.Center };
pub const justify_end = .{ .justify_content = layout.JustifyContent.End };
pub const justify_between = .{ .justify_content = layout.JustifyContent.SpaceBetween };
pub const justify_around = .{ .justify_content = layout.JustifyContent.SpaceAround };

pub fn grow(value: f32) struct { flex_grow: f32 } {
    return .{ .flex_grow = value };
}

pub fn shrink(value: f32) struct { flex_shrink: f32 } {
    return .{ .flex_shrink = value };
}

pub const grow_0 = .{ .flex_grow = 0.0 };
pub const grow_1 = .{ .flex_grow = 1.0 };
pub const shrink_0 = .{ .flex_shrink = 0.0 };
pub const shrink_1 = .{ .flex_shrink = 1.0 };

pub fn gap(n: f32) struct { gap: f32 } {
    return .{ .gap = unit(n) };
}

pub fn gap_px(value_px: f32) struct { gap: f32 } {
    return .{ .gap = value_px };
}

pub fn columns(count: u16) struct { grid_columns: u16 } {
    return .{ .grid_columns = count };
}

pub fn cols(tracks: []const GridTrack) struct { grid_template_columns: GridTemplate } {
    return .{ .grid_template_columns = GridTemplate.fromSlice(tracks) };
}

pub fn rows(tracks: []const GridTrack) struct { grid_template_rows: GridTemplate } {
    return .{ .grid_template_rows = GridTemplate.fromSlice(tracks) };
}

pub const relative = .{ .position = layout.Position.relative };
pub const absolute = .{ .position = layout.Position.absolute };
pub const anchored = .{ .position = layout.Position.anchored };

pub fn z(index: i32) struct { z_index: i32 } {
    return .{ .z_index = index };
}

pub fn top(value_px: f32) struct { top: ?f32 } {
    return .{ .top = value_px };
}

pub fn right(value_px: f32) struct { right: ?f32 } {
    return .{ .right = value_px };
}

pub fn bottom(value_px: f32) struct { bottom: ?f32 } {
    return .{ .bottom = value_px };
}

pub fn left(value_px: f32) struct { left: ?f32 } {
    return .{ .left = value_px };
}

pub fn inset(value_px: f32) struct { top: ?f32, right: ?f32, bottom: ?f32, left: ?f32 } {
    return .{ .top = value_px, .right = value_px, .bottom = value_px, .left = value_px };
}

pub const w_full = .{ .width = Size.Full };
pub const h_full = .{ .height = Size.Full };
pub const size_full = .{ .width = Size.Full, .height = Size.Full };
pub const w_screen = .{ .width = Size.screen };
pub const h_screen = .{ .height = Size.screen };
pub const size_screen = .{ .width = Size.screen, .height = Size.screen };
pub const w_auto = .{ .width = Size.Auto };
pub const h_auto = .{ .height = Size.Auto };

pub fn w(value_px: f32) struct { width: Size } {
    return .{ .width = .{ .exact = value_px } };
}

pub fn h(value_px: f32) struct { height: Size } {
    return .{ .height = .{ .exact = value_px } };
}

pub fn square(value_px: f32) struct { width: Size, height: Size } {
    return .{ .width = .{ .exact = value_px }, .height = .{ .exact = value_px } };
}

pub fn w_pct(percent: f32) struct { width: Size } {
    return .{ .width = .{ .percent = percent } };
}

pub fn h_pct(percent: f32) struct { height: Size } {
    return .{ .height = .{ .percent = percent } };
}

pub fn w_frac(numerator: f32, denominator: f32) struct { width: Size } {
    return .{ .width = Size.fraction(numerator, denominator) };
}

pub fn h_frac(numerator: f32, denominator: f32) struct { height: Size } {
    return .{ .height = Size.fraction(numerator, denominator) };
}

pub fn min_w(value_px: f32) struct { min_width: Size } {
    return .{ .min_width = .{ .exact = value_px } };
}

pub fn max_w(value_px: f32) struct { max_width: Size } {
    return .{ .max_width = .{ .exact = value_px } };
}

pub fn min_h(value_px: f32) struct { min_height: Size } {
    return .{ .min_height = .{ .exact = value_px } };
}

pub fn max_h(value_px: f32) struct { max_height: Size } {
    return .{ .max_height = .{ .exact = value_px } };
}

pub fn p(n: f32) struct { padding: Spacing } {
    return .{ .padding = Spacing.all(unit(n)) };
}

pub fn p_px(value_px: f32) struct { padding: Spacing } {
    return .{ .padding = Spacing.all(value_px) };
}

pub fn px(n: f32) struct { padding: Spacing } {
    const v = unit(n);
    return .{ .padding = .{ .left = v, .right = v } };
}

pub fn py(n: f32) struct { padding: Spacing } {
    const v = unit(n);
    return .{ .padding = .{ .top = v, .bottom = v } };
}

pub fn p_xy(x: f32, y: f32) struct { padding: Spacing } {
    const xv = unit(x);
    const yv = unit(y);
    return .{ .padding = .{ .left = xv, .right = xv, .top = yv, .bottom = yv } };
}

pub fn p_xy_px(x_px: f32, y_px: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .left = x_px, .right = x_px, .top = y_px, .bottom = y_px } };
}

pub fn p_each_px(top_px: f32, right_px: f32, bottom_px: f32, left_px: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .top = top_px, .right = right_px, .bottom = bottom_px, .left = left_px } };
}

pub fn pt(n: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .top = unit(n) } };
}

pub fn pr(n: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .right = unit(n) } };
}

pub fn pb(n: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .bottom = unit(n) } };
}

pub fn pl(n: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .left = unit(n) } };
}

pub fn m(n: f32) struct { margin: Spacing } {
    return .{ .margin = Spacing.all(unit(n)) };
}

pub fn mx(n: f32) struct { margin: Spacing } {
    const v = unit(n);
    return .{ .margin = .{ .left = v, .right = v } };
}

pub fn my(n: f32) struct { margin: Spacing } {
    const v = unit(n);
    return .{ .margin = .{ .top = v, .bottom = v } };
}

pub fn m_xy(x: f32, y: f32) struct { margin: Spacing } {
    const xv = unit(x);
    const yv = unit(y);
    return .{ .margin = .{ .left = xv, .right = xv, .top = yv, .bottom = yv } };
}

pub fn m_xy_px(x_px: f32, y_px: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .left = x_px, .right = x_px, .top = y_px, .bottom = y_px } };
}

pub fn m_each_px(top_px: f32, right_px: f32, bottom_px: f32, left_px: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .top = top_px, .right = right_px, .bottom = bottom_px, .left = left_px } };
}

pub fn mt_px(value_px: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .top = value_px } };
}

pub fn mr_px(value_px: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .right = value_px } };
}

pub fn mb_px(value_px: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .bottom = value_px } };
}

pub fn ml_px(value_px: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .left = value_px } };
}

pub fn pt_px(value_px: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .top = value_px } };
}

pub fn pr_px(value_px: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .right = value_px } };
}

pub fn pb_px(value_px: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .bottom = value_px } };
}

pub fn pl_px(value_px: f32) struct { padding: Spacing } {
    return .{ .padding = .{ .left = value_px } };
}

pub fn mt(n: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .top = unit(n) } };
}

pub fn mr(n: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .right = unit(n) } };
}

pub fn mb(n: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .bottom = unit(n) } };
}

pub fn ml(n: f32) struct { margin: Spacing } {
    return .{ .margin = .{ .left = unit(n) } };
}

pub const box_border = .{ .box_sizing = layout.BoxSizing.border_box };
pub const box_content = .{ .box_sizing = layout.BoxSizing.content_box };

pub const object_fill = .{ .object_fit = layout.ObjectFit.fill };
pub const object_contain = .{ .object_fit = layout.ObjectFit.contain };
pub const object_cover = .{ .object_fit = layout.ObjectFit.cover };
pub const object_none = .{ .object_fit = layout.ObjectFit.none };
pub const object_scale_down = .{ .object_fit = layout.ObjectFit.scale_down };

pub const overflow_visible = .{ .overflow_x = layout.Overflow.visible, .overflow_y = layout.Overflow.visible };
pub const overflow_hidden = .{ .overflow_x = layout.Overflow.hidden, .overflow_y = layout.Overflow.hidden };
pub const overflow_scroll = .{ .overflow_x = layout.Overflow.scroll, .overflow_y = layout.Overflow.scroll };
pub const overflow_x_hidden = .{ .overflow_x = layout.Overflow.hidden };
pub const overflow_y_hidden = .{ .overflow_y = layout.Overflow.hidden };
pub const overflow_x_scroll = .{ .overflow_x = layout.Overflow.scroll };
pub const overflow_y_scroll = .{ .overflow_y = layout.Overflow.scroll };

pub fn bg(comptime color_str: []const u8) struct { background_color: [4]f32 } {
    return .{ .background_color = color(color_str) };
}

pub fn bg_value(color_value: [4]f32) struct { background_color: [4]f32 } {
    return .{ .background_color = color_value };
}

pub fn hover(comptime color_str: []const u8) struct { hover_color: ?[4]f32 } {
    return .{ .hover_color = color(color_str) };
}

pub fn hover_value(color_value: [4]f32) struct { hover_color: ?[4]f32 } {
    return .{ .hover_color = color_value };
}

pub fn opacity(value: f32) struct { opacity: f32 } {
    return .{ .opacity = value };
}

pub fn rounded(value_px: f32) struct { corner_radius: CornerRadius } {
    return .{ .corner_radius = CornerRadius.all(value_px) };
}

pub const rounded_none = .{ .corner_radius = CornerRadius.all(0) };
pub const rounded_sm = .{ .corner_radius = CornerRadius.all(2) };
pub const rounded_md = .{ .corner_radius = CornerRadius.all(4) };
pub const rounded_lg = .{ .corner_radius = CornerRadius.all(8) };
pub const rounded_xl = .{ .corner_radius = CornerRadius.all(12) };
pub const rounded_full = .{ .corner_radius = CornerRadius.all(9999) };

pub fn border(width: f32, comptime color_str: []const u8) struct { border: Border } {
    return .{ .border = Border.all(width, color(color_str)) };
}

pub fn border_value(width: f32, color_value: [4]f32) struct { border: Border } {
    return .{ .border = Border.all(width, color_value) };
}

pub fn border_t(width: f32, comptime color_str: []const u8) struct { border: Border } {
    return .{ .border = .{ .top = .{ .width = width, .color = color(color_str) } } };
}

pub fn border_t_value(width: f32, color_value: [4]f32) struct { border: Border } {
    return .{ .border = .{ .top = .{ .width = width, .color = color_value } } };
}

pub fn border_r(width: f32, comptime color_str: []const u8) struct { border: Border } {
    return .{ .border = .{ .right = .{ .width = width, .color = color(color_str) } } };
}

pub fn border_r_value(width: f32, color_value: [4]f32) struct { border: Border } {
    return .{ .border = .{ .right = .{ .width = width, .color = color_value } } };
}

pub fn border_b(width: f32, comptime color_str: []const u8) struct { border: Border } {
    return .{ .border = .{ .bottom = .{ .width = width, .color = color(color_str) } } };
}

pub fn border_b_value(width: f32, color_value: [4]f32) struct { border: Border } {
    return .{ .border = .{ .bottom = .{ .width = width, .color = color_value } } };
}

pub fn border_l(width: f32, comptime color_str: []const u8) struct { border: Border } {
    return .{ .border = .{ .left = .{ .width = width, .color = color(color_str) } } };
}

pub fn border_l_value(width: f32, color_value: [4]f32) struct { border: Border } {
    return .{ .border = .{ .left = .{ .width = width, .color = color_value } } };
}

pub fn outline(width: f32, comptime color_str: []const u8) struct { outline: Border } {
    return .{ .outline = Border.all(width, color(color_str)) };
}

pub fn outline_value(width: f32, color_value: [4]f32) struct { outline: Border } {
    return .{ .outline = Border.all(width, color_value) };
}

pub fn shadow(comptime color_str: []const u8, offset: [2]f32, blur_px: f32) struct { shadow_color: [4]f32, shadow_offset: [2]f32, shadow_blur: f32 } {
    return .{ .shadow_color = color(color_str), .shadow_offset = offset, .shadow_blur = blur_px };
}

pub fn shadow_value(color_value: [4]f32, offset: [2]f32, blur_px: f32) struct { shadow_color: [4]f32, shadow_offset: [2]f32, shadow_blur: f32 } {
    return .{ .shadow_color = color_value, .shadow_offset = offset, .shadow_blur = blur_px };
}

pub fn blur(value_px: f32) struct { blur: f32 } {
    return .{ .blur = value_px };
}

pub fn backdrop_blur(value_px: f32) struct { backdrop_blur: f32 } {
    return .{ .backdrop_blur = value_px };
}

pub const cursor_default = .{ .cursor = layout.Cursor.default };
pub const cursor_pointer = .{ .cursor = layout.Cursor.pointer };
pub const cursor_text = .{ .cursor = layout.Cursor.text };
pub const cursor_crosshair = .{ .cursor = layout.Cursor.crosshair };
pub const cursor_ns_resize = .{ .cursor = layout.Cursor.ns_resize };
pub const cursor_ew_resize = .{ .cursor = layout.Cursor.ew_resize };
pub const pointer_events_auto = .{ .pointer_events = layout.PointerEvents.auto };
pub const pointer_events_none = .{ .pointer_events = layout.PointerEvents.none };

pub fn translate(x: f32, y: f32) struct { transform: Transform } {
    return .{ .transform = .{ .translate = .{ x, y } } };
}

pub fn scale(value: f32) struct { transform: Transform } {
    return .{ .transform = .{ .scale = value } };
}

pub fn rotate(radians: f32) struct { transform: Transform } {
    return .{ .transform = .{ .rotate = radians } };
}

pub fn transition(value: TransitionStyle) struct { transition: TransitionStyle } {
    return .{ .transition = value };
}

pub fn transition_all(ms: u32) struct { transition: TransitionStyle } {
    return .{ .transition = TransitionStyle.forAll(ms) };
}

pub fn transition_colors(ms: u32) struct { transition: TransitionStyle } {
    return .{ .transition = TransitionStyle.forColors(ms) };
}

test "tw composes style partials over defaults" {
    const s = style(.{
        flex_row,
        items_center,
        gap(3),
        p(2),
        bg("#0c1830"),
        text_color("#fff"),
    });

    try std.testing.expectEqual(layout.FlexDirection.Row, s.direction);
    try std.testing.expectEqual(layout.FlexAlign.Center, s.align_items);
    try std.testing.expectEqual(@as(f32, 12), s.gap);
    try std.testing.expectEqual(@as(f32, 8), s.padding.left);
    try std.testing.expectEqual(@as(f32, 1), s.text_color[3]);
}

test "tw applies partials over existing style" {
    const base = Style{ .width = .{ .exact = 10 }, .height = .{ .exact = 20 } };
    const s = apply(base, .{ w(100), flex_col });

    try std.testing.expectEqual(Size{ .exact = 100 }, s.width);
    try std.testing.expectEqual(Size{ .exact = 20 }, s.height);
    try std.testing.expectEqual(layout.FlexDirection.Column, s.direction);
}

test "tw resolves semantic theme classes through explicit tokens" {
    const active_theme = theme_mod.Theme.init(.{ 0.62, 0.14, 255.0, 1.0 }, true);
    const s = styleTheme(active_theme.tokens, .{
        bg_surface,
        text_muted,
        border_focus,
        hover_action,
    });

    try std.testing.expectEqual(active_theme.tokens.bg_surface, s.background_color);
    try std.testing.expectEqual(active_theme.tokens.text_muted, s.text_color);
    try std.testing.expectEqual(active_theme.tokens.border_focus, s.border.top.color);
    try std.testing.expectEqual(active_theme.tokens.action_hover, s.hover_color.?);
}
