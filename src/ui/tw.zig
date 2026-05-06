const std = @import("std");
const layout = @import("layout.zig");

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

fn applyPartial(result: *Style, partial: anytype) void {
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

pub const transparent = rgba(0, 0, 0, 0);
pub const white = rgba(1, 1, 1, 1);
pub const black = rgba(0, 0, 0, 1);

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

pub fn text_color(color: [4]f32) struct { text_color: [4]f32 } {
    return .{ .text_color = color };
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

pub const overflow_visible = .{ .overflow_x = layout.Overflow.visible, .overflow_y = layout.Overflow.visible };
pub const overflow_hidden = .{ .overflow_x = layout.Overflow.hidden, .overflow_y = layout.Overflow.hidden };
pub const overflow_scroll = .{ .overflow_x = layout.Overflow.scroll, .overflow_y = layout.Overflow.scroll };
pub const overflow_x_hidden = .{ .overflow_x = layout.Overflow.hidden };
pub const overflow_y_hidden = .{ .overflow_y = layout.Overflow.hidden };
pub const overflow_x_scroll = .{ .overflow_x = layout.Overflow.scroll };
pub const overflow_y_scroll = .{ .overflow_y = layout.Overflow.scroll };

pub fn bg(color: [4]f32) struct { background_color: [4]f32 } {
    return .{ .background_color = color };
}

pub fn hover(color: [4]f32) struct { hover_color: ?[4]f32 } {
    return .{ .hover_color = color };
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

pub fn border(width: f32, color: [4]f32) struct { border: Border } {
    return .{ .border = Border.all(width, color) };
}

pub fn border_t(width: f32, color: [4]f32) struct { border: Border } {
    return .{ .border = .{ .top = .{ .width = width, .color = color } } };
}

pub fn border_r(width: f32, color: [4]f32) struct { border: Border } {
    return .{ .border = .{ .right = .{ .width = width, .color = color } } };
}

pub fn border_b(width: f32, color: [4]f32) struct { border: Border } {
    return .{ .border = .{ .bottom = .{ .width = width, .color = color } } };
}

pub fn border_l(width: f32, color: [4]f32) struct { border: Border } {
    return .{ .border = .{ .left = .{ .width = width, .color = color } } };
}

pub fn outline(width: f32, color: [4]f32) struct { outline: Border } {
    return .{ .outline = Border.all(width, color) };
}

pub fn shadow(color: [4]f32, offset: [2]f32, blur_px: f32) struct { shadow_color: [4]f32, shadow_offset: [2]f32, shadow_blur: f32 } {
    return .{ .shadow_color = color, .shadow_offset = offset, .shadow_blur = blur_px };
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
        bg(rgb255(12, 24, 48)),
        text_color(white),
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
