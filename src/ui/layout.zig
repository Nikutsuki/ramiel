const std = @import("std");
const Node = @import("node.zig").Node;
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const EasingFunction = @import("../animation/easing.zig").EasingFunction;
const bench_prefetch = @import("bench_prefetch.zig");
const NodeId = u32;

pub const FlexDirection = enum {
    Row,
    Column,
};

pub const FlexWrap = enum {
    NoWrap,
    Wrap,
};

pub const FlexAlign = enum {
    Start,
    Center,
    End,
    Stretch,
};

pub const FlexAlignSelf = enum {
    Auto,
    Start,
    Center,
    End,
    Stretch,
};

pub const JustifyContent = enum {
    Start,
    Center,
    End,
    SpaceBetween,
    SpaceAround,
};

pub const Size = union(enum) {
    Auto,
    Full,
    percent: f32,
    exact: f32,
    screen,

    pub fn fraction(numerator: f32, denominator: f32) Size {
        if (denominator <= 0.0) return .{ .percent = 0.0 };
        return .{ .percent = @max(0.0, numerator / denominator) };
    }
};

pub const Display = enum {
    flex,
    grid,
    block,
    none,
};

pub const GridTrack = union(enum) {
    Auto,
    exact: f32,
    percent: f32,
    fr: f32,
};

pub const GridTemplate = struct {
    pub const max_tracks: usize = 32;

    tracks: [max_tracks]GridTrack = [_]GridTrack{.{ .Auto = {} }} ** max_tracks,
    len: u8 = 0,

    pub fn fromSlice(values: []const GridTrack) GridTemplate {
        var template = GridTemplate{};
        const track_count = @min(values.len, max_tracks);
        var i: usize = 0;
        while (i < track_count) : (i += 1) {
            template.tracks[i] = values[i];
        }
        template.len = @as(u8, @intCast(track_count));
        return template;
    }

    pub fn count(self: GridTemplate) usize {
        return @as(usize, self.len);
    }

    pub fn trackAt(self: GridTemplate, index: usize) GridTrack {
        return self.tracks[index];
    }
};

pub const Overflow = enum {
    visible,
    hidden,
    scroll,
};

pub const WhiteSpace = enum {
    Normal,
    NoWrap,
};

pub const TextOverflow = enum {
    Clip,
    Ellipsis,
};

pub const Position = enum {
    relative,
    absolute,
    anchored,
};

pub const Cursor = enum {
    default,
    pointer,
    text,
    crosshair,
    ns_resize,
    ew_resize,
};

pub const PointerEvents = enum {
    auto,
    none,
};

pub const BoxSizing = enum {
    border_box,
    content_box,
};

pub const ObjectFit = enum {
    fill,
    contain,
    cover,
    none,
    scale_down,
};

pub const Transform = struct {
    translate: [2]f32 = .{ 0, 0 },
    scale: f32 = 1.0,
    rotate: f32 = 0.0,

    pub fn isIdentity(self: Transform) bool {
        return self.translate[0] == 0 and self.translate[1] == 0 and
            self.scale == 1.0 and self.rotate == 0.0;
    }
};

pub const TransitionProperty = packed struct(u32) {
    background_color: bool = false,
    hover_color: bool = false,
    text_color: bool = false,
    border_color: bool = false,
    outline_color: bool = false,
    shadow_color: bool = false,
    opacity: bool = false,
    shadow_blur: bool = false,
    shadow_offset: bool = false,
    corner_radius: bool = false,
    blur: bool = false,
    backdrop_blur: bool = false,
    translate: bool = false,
    scale: bool = false,
    rotate: bool = false,
    text_decoration_color: bool = false,
    _pad: u16 = 0,

    pub const all = TransitionProperty{
        .background_color = true,
        .hover_color = true,
        .text_color = true,
        .border_color = true,
        .outline_color = true,
        .shadow_color = true,
        .opacity = true,
        .shadow_blur = true,
        .shadow_offset = true,
        .corner_radius = true,
        .blur = true,
        .backdrop_blur = true,
        .translate = true,
        .scale = true,
        .rotate = true,
        .text_decoration_color = true,
    };

    pub const colors = TransitionProperty{
        .background_color = true,
        .hover_color = true,
        .text_color = true,
        .border_color = true,
        .outline_color = true,
        .shadow_color = true,
        .text_decoration_color = true,
    };

    pub const opacity_only = TransitionProperty{ .opacity = true };

    pub const shadow_only = TransitionProperty{
        .shadow_color = true,
        .shadow_blur = true,
        .shadow_offset = true,
    };

    pub const transform_only = TransitionProperty{
        .translate = true,
        .scale = true,
        .rotate = true,
    };

    pub fn hasAny(self: TransitionProperty) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};

pub const TransitionStyle = struct {
    property: TransitionProperty = .{},
    duration_ms: u32 = 150,
    delay_ms: u32 = 0,
    timing: EasingFunction = .ease_in_out,

    pub const none = TransitionStyle{};

    pub fn forColors(duration_ms: u32) TransitionStyle {
        return .{ .property = TransitionProperty.colors, .duration_ms = duration_ms, .timing = .ease_in_out };
    }

    pub fn forOpacity(duration_ms: u32) TransitionStyle {
        return .{ .property = TransitionProperty.opacity_only, .duration_ms = duration_ms, .timing = .ease_in_out };
    }

    pub fn forShadow(duration_ms: u32) TransitionStyle {
        return .{ .property = TransitionProperty.shadow_only, .duration_ms = duration_ms, .timing = .ease_in_out };
    }

    pub fn forTransform(duration_ms: u32) TransitionStyle {
        return .{ .property = TransitionProperty.transform_only, .duration_ms = duration_ms, .timing = .ease_out };
    }

    pub fn forAll(duration_ms: u32) TransitionStyle {
        return .{ .property = TransitionProperty.all, .duration_ms = duration_ms, .timing = .ease_in_out };
    }
};

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(r: f32) CornerRadius {
        return .{ .top_left = r, .top_right = r, .bottom_right = r, .bottom_left = r };
    }

    pub fn hasAny(self: CornerRadius) bool {
        return self.top_left > 0 or self.top_right > 0 or
            self.bottom_right > 0 or self.bottom_left > 0;
    }

    pub fn toArray(self: CornerRadius) [4]f32 {
        return .{ self.top_left, self.top_right, self.bottom_right, self.bottom_left };
    }
};

pub const BorderSide = struct {
    width: f32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Border = struct {
    top: BorderSide = .{},
    right: BorderSide = .{},
    bottom: BorderSide = .{},
    left: BorderSide = .{},

    pub fn all(width: f32, color: [4]f32) Border {
        const s = BorderSide{ .width = width, .color = color };
        return .{ .top = s, .right = s, .bottom = s, .left = s };
    }

    pub fn hasAny(self: Border) bool {
        return self.top.width > 0 or self.right.width > 0 or
            self.bottom.width > 0 or self.left.width > 0;
    }

    pub fn widths(self: Border) [4]f32 {
        return .{ self.top.width, self.right.width, self.bottom.width, self.left.width };
    }
};

pub const FontWeight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    normal = 400,
    medium = 500,
    semibold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
};

pub const FontStyle = enum(u8) {
    normal,
    italic,
    /// No synthesized shear; resolves through the italic variant slot.
    oblique,
};

pub const TextDecorationLine = struct {
    underline: bool = false,
    line_through: bool = false,
    overline: bool = false,

    pub fn hasAny(self: TextDecorationLine) bool {
        return self.underline or self.line_through or self.overline;
    }

    pub fn merge(self: TextDecorationLine, other: TextDecorationLine) TextDecorationLine {
        return .{
            .underline = self.underline or other.underline,
            .line_through = self.line_through or other.line_through,
            .overline = self.overline or other.overline,
        };
    }
};

pub const TextDecorationShape = enum(u8) { solid, double, wavy, dotted, dashed };

pub const TextDecoration = struct {
    line: TextDecorationLine = .{},
    shape: TextDecorationShape = .solid,
    /// null -> inherit text_color.
    color: ?[4]f32 = null,
    /// 0 -> use font.underline_thickness.
    thickness: f32 = 0,
    offset: f32 = 0,

    /// Field-by-field merge: only non-default fields on `other` overwrite.
    /// Required so `tw.underline` and `tw.decoration_color(...)` compose
    /// without the latter wiping the line bits.
    pub fn merge(self: TextDecoration, other: TextDecoration) TextDecoration {
        var out = self;
        if (other.line.hasAny()) out.line = out.line.merge(other.line);
        if (other.shape != .solid) out.shape = other.shape;
        if (other.color) |c| out.color = c;
        if (other.thickness != 0) out.thickness = other.thickness;
        if (other.offset != 0) out.offset = other.offset;
        return out;
    }
};

/// Per-glyph MSDF stem-weight knob (`corner_radii[0]`). Real face does the
/// heavy lifting; this just nudges the shader's threshold sympathetically.
pub fn msdfWeightFor(weight: FontWeight) f32 {
    return switch (weight) {
        .thin => 0.3,
        .extra_light => 0.35,
        .light => 0.4,
        .normal => 0.5,
        .medium => 0.55,
        .semibold => 0.6,
        .bold => 0.7,
        .extra_bold => 0.78,
        .black => 0.85,
    };
}

pub const Spacing = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(value: f32) Spacing {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn horizontal(self: Spacing) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Spacing) f32 {
        return self.top + self.bottom;
    }
};

pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    pointer_events: PointerEvents = .auto,
    /// null: engine picks (text payloads -> .text, click/hover -> .pointer, else .default).
    cursor: ?Cursor = null,
    z_index: i32 = 0,
    opacity: f32 = 1.0,
    transform: Transform = .{},
    transition: TransitionStyle = .{},
    anchor_id: ?NodeId = null,

    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
    left: ?f32 = null,

    direction: FlexDirection = .Column,
    flex_wrap: FlexWrap = .NoWrap,
    align_items: FlexAlign = .Start,
    align_self: FlexAlignSelf = .Auto,
    justify_content: JustifyContent = .Start,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    gap: f32 = 0,

    grid_columns: u16 = 0,
    grid_template_columns: GridTemplate = .{},
    grid_template_rows: GridTemplate = .{},
    grid_auto_rows: GridTrack = .{ .Auto = {} },

    grid_column_start: ?u16 = null,
    grid_row_start: ?u16 = null,
    grid_column_span: u16 = 1,
    grid_row_span: u16 = 1,

    box_sizing: BoxSizing = .border_box,
    width: Size = .Auto,
    height: Size = .Auto,
    min_width: Size = .Auto,
    max_width: Size = .Auto,
    min_height: Size = .Auto,
    max_height: Size = .Auto,
    padding: Spacing = .{},
    margin: Spacing = .{},
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,

    scrollbar_width: f32 = 8.0,
    scrollbar_min_height: f32 = 20.0,
    scrollbar_color: [4]f32 = .{ 1.0, 1.0, 1.0, 0.3 },
    scrollbar_radius: f32 = 4.0,

    background_color: [4]f32 = .{ 0, 0, 0, 0 },
    hover_color: ?[4]f32 = null,
    _hover_blend: f32 = 0.0,
    corner_radius: CornerRadius = .{},
    corner_softness: f32 = 1.0,
    border: Border = .{},
    outline: Border = .{},
    blur: f32 = 0,
    backdrop_blur: f32 = 0,

    shadow_color: [4]f32 = .{ 0, 0, 0, 0 },
    shadow_offset: [2]f32 = .{ 0, 0 },
    shadow_blur: f32 = 0,

    text_color: [4]f32 = .{ 1, 1, 1, 1 },
    /// null -> UIContext's default family.
    font_family: ?[]const u8 = null,
    font_weight: FontWeight = .normal,
    font_style: FontStyle = .normal,
    font_size: f32 = 16.0,
    white_space: WhiteSpace = .Normal,
    text_overflow: TextOverflow = .Clip,
    line_height: f32 = 0.0,
    text_decoration: TextDecoration = .{},

    object_fit: ObjectFit = .fill,

    pub fn mix(partials: anytype) Style {
        var result = Style{}; // Start with default values
        const type_info = @typeInfo(@TypeOf(partials));

        if (type_info != .@"struct" or !type_info.@"struct".is_tuple) {
            @compileError("Style.mix expects a tuple of anonymous structs, e.g. `.{ tw.text_xl, .{ .padding = Spacing.all(4) } }`");
        }

        inline for (type_info.@"struct".fields) |tuple_field| {
            const partial = @field(partials, tuple_field.name);
            inline for (@typeInfo(@TypeOf(partial)).@"struct".fields) |style_field| {
                if (@hasField(Style, style_field.name)) {
                    if (comptime std.mem.eql(u8, style_field.name, "text_decoration")) {
                        result.text_decoration = result.text_decoration.merge(@field(partial, style_field.name));
                    } else {
                        @field(result, style_field.name) = @field(partial, style_field.name);
                    }
                } else {
                    @compileError("Style has no field named '" ++ style_field.name ++ "'");
                }
            }
        }
        return result;
    }
};

pub const LayoutResult = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 0.0,
    height: f32 = 0.0,
    content_width: f32 = 0.0,
    content_height: f32 = 0.0,
    measured_max_w: f32 = -1.0,
    measured_max_h: f32 = -1.0,
    text_cache: TextLayoutCache = .{},
};

inline fn prefetchNextChildIfEnabled(children: anytype, idx: usize) void {
    if (!bench_prefetch.isEnabled()) return;
    if (idx + 1 >= children.len) return;
    @prefetch(children[idx + 1], .{});
}

pub const TextLayoutMetric = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    byte_offset: usize,
    byte_length: usize,

    render_x: f32 = 0.0,
    render_y: f32 = 0.0,
    render_w: f32 = 0.0,
    render_h: f32 = 0.0,
    uv_min: [2]f32 = .{ 0.0, 0.0 },
    uv_max: [2]f32 = .{ 0.0, 0.0 },
    is_visible: bool = false,

    /// Bindless atlas index + effect flag for this glyph. Font fallback can mix
    /// atlases within one run (e.g. MSDF text alongside color-bitmap emoji), so
    /// routing is per-glyph rather than per-text-node.
    atlas_id: u32 = 0,
    effect: u32 = 0,
    sdf_padding: f32 = 0,
};

pub const TextLayoutCache = struct {
    width: f32 = 0.0,
    height: f32 = 0.0,
    max_width: f32 = 0.0,
    wrap: bool = true,
    ellipsis: bool = false,
    line_height: f32 = 0.0,
    font_size: f32 = 0.0,
    /// True when glyph UVs index into `font.bitmap_atlas_tex_id` (FT-hinted path).
    is_bitmap: bool = false,
    metrics: []TextLayoutMetric = &.{},

    pub fn clear(self: *TextLayoutCache, allocator: anytype) void {
        if (self.metrics.len > 0) {
            allocator.free(self.metrics);
        }
        self.* = .{};
    }
};

const TextMeasureOptions = struct {
    max_width: f32,
    wrap: bool,
    ellipsis: bool,
    line_height: f32,
    font_size: f32,
};

const AxisBounds = struct {
    min: f32,
    max: f32,
};

fn resolveAxisBound(size: Size, available: f32, comptime is_min: bool) f32 {
    const bounded_available = @max(0.0, available);
    return switch (size) {
        .Auto => if (is_min) 0.0 else std.math.inf(f32),
        .exact => |v| @max(0.0, v),
        .percent => |p| bounded_available * @max(0.0, p),
        .Full, .screen => bounded_available,
    };
}

fn resolveAxisBounds(min_size: Size, max_size: Size, available: f32) AxisBounds {
    const min_value = resolveAxisBound(min_size, available, true);
    const raw_max_value = resolveAxisBound(max_size, available, false);
    const max_value = @max(raw_max_value, min_value);
    return .{ .min = min_value, .max = max_value };
}

fn clampToAxisBounds(value: f32, bounds: AxisBounds) f32 {
    return std.math.clamp(value, bounds.min, bounds.max);
}

fn clampAxisByStyle(value: f32, min_size: Size, max_size: Size, available: f32) f32 {
    return clampToAxisBounds(value, resolveAxisBounds(min_size, max_size, available));
}

fn contentInsets(style: Style) Spacing {
    return .{
        .top = style.padding.top + @max(0.0, style.border.top.width),
        .right = style.padding.right + @max(0.0, style.border.right.width),
        .bottom = style.padding.bottom + @max(0.0, style.border.bottom.width),
        .left = style.padding.left + @max(0.0, style.border.left.width),
    };
}

fn isGridLayoutEnabled(style: Style) bool {
    return style.grid_columns > 0 or style.grid_template_columns.count() > 0;
}

fn effectiveGridColumnCount(style: Style) usize {
    const template_cols = style.grid_template_columns.count();
    if (template_cols > 0) return template_cols;
    return @as(usize, @intCast(style.grid_columns));
}

fn getGridColumnTrack(style: Style, column_index: usize) GridTrack {
    const template_cols = style.grid_template_columns.count();
    if (template_cols > 0 and column_index < template_cols) {
        return style.grid_template_columns.trackAt(column_index);
    }
    return .{ .fr = 1.0 };
}

fn getGridRowTrack(style: Style, row_index: usize) GridTrack {
    const template_rows = style.grid_template_rows.count();
    if (row_index < template_rows) {
        return style.grid_template_rows.trackAt(row_index);
    }
    return style.grid_auto_rows;
}

fn layouterDeclType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

fn resolveTextMeasureOptions(style: Style, requested_max_width: f32, available_width: f32, force_no_wrap: bool, force_wrap: bool) TextMeasureOptions {
    const wrap = if (force_wrap) true else (!force_no_wrap and style.white_space == .Normal);
    const ellipsis = !wrap and style.text_overflow == .Ellipsis;

    var max_width = requested_max_width;
    if (max_width <= 0.0 and (wrap or ellipsis) and available_width > 0.0) {
        max_width = available_width;
    } else if (max_width > 0.0 and wrap and available_width > 0.0) {
        max_width = @min(max_width, available_width);
    }

    return .{
        .max_width = @max(0.0, max_width),
        .wrap = wrap,
        .ellipsis = ellipsis,
        .line_height = style.line_height,
        .font_size = style.font_size,
    };
}

fn updateTextLayoutCache(node: anytype, text_layouter: anytype, font: anytype, text: []const u8, options: TextMeasureOptions) void {
    var cache = &node.layout_result.text_cache;
    cache.clear(node.allocator);

    cache.max_width = options.max_width;
    cache.wrap = options.wrap;
    cache.ellipsis = options.ellipsis;
    cache.line_height = options.line_height;
    cache.font_size = options.font_size;

    const Layouter = layouterDeclType(@TypeOf(text_layouter));
    const measured = if (@hasDecl(Layouter, "measureTextWithOptions"))
        text_layouter.measureTextWithOptions(node.allocator, font, text, .{
            .max_width = options.max_width,
            .wrap = options.wrap,
            .ellipsis = options.ellipsis,
            .font_size = node.style.font_size,
            .line_height = options.line_height,
        })
    else
        text_layouter.measureText(node.allocator, font, text, options.max_width);

    cache.width = measured.width;
    cache.height = measured.height;
    cache.is_bitmap = measured.is_bitmap;

    if (measured.metrics.len == 0) return;

    cache.metrics = node.allocator.alloc(TextLayoutMetric, measured.metrics.len) catch @panic("OOM while allocating UI text cache");
    for (measured.metrics, 0..) |m, i| {
        cache.metrics[i] = .{
            .x = m.x,
            .y = m.y,
            .width = m.width,
            .height = m.height,
            .byte_offset = m.byte_offset,
            .byte_length = m.byte_length,
            .render_x = m.render_x,
            .render_y = m.render_y,
            .render_w = m.render_w,
            .render_h = m.render_h,
            .uv_min = m.uv_min,
            .uv_max = m.uv_max,
            .is_visible = m.is_visible,
            .atlas_id = m.atlas_id,
            .effect = m.effect,
            .sdf_padding = m.sdf_padding,
        };
    }
    node.allocator.free(measured.metrics);
}

// text_layouter is anytype so tests can stub without HarfBuzz/Vulkan.
pub fn measureNode(node: anytype, text_layouter: anytype, max_w: f32, max_h: f32, force_recalculate: bool) void {
    if (node.style.display == .none) {
        node.layout_result.width = 0;
        node.layout_result.height = 0;
        node.layout_result.content_width = 0;
        node.layout_result.content_height = 0;
        node.flags = .{
            .position = false,
            .size = false,
            .content = false,
        };
        return;
    }

    const constraints_changed =
        node.layout_result.measured_max_w != max_w or
        node.layout_result.measured_max_h != max_h;

    if (!node.flags.any() and !force_recalculate and !constraints_changed) return;

    if (constraints_changed or force_recalculate) {
        node.flags.size = true;
        node.flags.position = true;
    }

    const width_bounds = resolveAxisBounds(node.style.min_width, node.style.max_width, max_w);
    const height_bounds = resolveAxisBounds(node.style.min_height, node.style.max_height, max_h);

    const insets = contentInsets(node.style);
    const is_content_box = node.style.box_sizing == .content_box;

    const resolved_width_raw: ?f32 = switch (node.style.width) {
        .exact => |w| w,
        .Full => max_w,
        .percent => |p| max_w * @max(0.0, p),
        .screen => max_w,
        .Auto => if (node.style.display == .block) max_w else null,
    };

    var resolved_width: ?f32 = if (resolved_width_raw) |w| blk: {
        const outer_w = if (is_content_box) w + insets.horizontal() else w;
        break :blk clampToAxisBounds(outer_w, width_bounds);
    } else null;

    const resolved_height_raw: ?f32 = switch (node.style.height) {
        .exact => |h| h,
        .Full => max_h,
        .percent => |p| max_h * @max(0.0, p),
        .screen => max_h,
        .Auto => null,
    };

    var resolved_height: ?f32 = if (resolved_height_raw) |h| blk: {
        const outer_h = if (is_content_box) h + insets.vertical() else h;
        break :blk clampToAxisBounds(outer_h, height_bounds);
    } else null;

    if (nodeAspectRatio(node)) |ratio| {
        if (resolved_width != null and resolved_height == null) {
            resolved_height = clampToAxisBounds(resolved_width.? / ratio, height_bounds);
        } else if (resolved_height != null and resolved_width == null) {
            resolved_width = clampToAxisBounds(resolved_height.? * ratio, width_bounds);
        }
    }

    const auto_width = clampToAxisBounds(max_w, width_bounds);
    const auto_height = clampToAxisBounds(max_h, height_bounds);

    const content_w = (resolved_width orelse auto_width) - insets.horizontal();
    const content_h = (resolved_height orelse auto_height) - insets.vertical();

    var intrinsic_w: f32 = 0;
    var intrinsic_h: f32 = 0;

    if (node.style.display == .grid and isGridLayoutEnabled(node.style)) {
        measureGridContent(
            node,
            text_layouter,
            @max(0, content_w),
            @max(0, content_h),
            resolved_height != null,
            &intrinsic_w,
            &intrinsic_h,
        );
    } else {
        measureFlexContent(node, text_layouter, @max(0, content_w), @max(0, content_h), resolved_width, resolved_height, &intrinsic_w, &intrinsic_h);
    }

    node.layout_result.content_width = intrinsic_w + insets.horizontal();
    node.layout_result.content_height = intrinsic_h + insets.vertical();

    const tentative_width = if (node.style.overflow_x != .visible)
        (resolved_width orelse @min(node.layout_result.content_width, max_w))
    else
        (resolved_width orelse node.layout_result.content_width);

    const tentative_height = if (node.style.overflow_y != .visible)
        (resolved_height orelse @min(node.layout_result.content_height, max_h))
    else
        (resolved_height orelse node.layout_result.content_height);

    node.layout_result.width = clampToAxisBounds(tentative_width, width_bounds);
    node.layout_result.height = clampToAxisBounds(tentative_height, height_bounds);

    const final_content_w = node.layout_result.width - insets.horizontal();
    const final_content_h = node.layout_result.height - insets.vertical();

    for (node.children.items, 0..) |child, i| {
        prefetchNextChildIfEnabled(node.children.items, i);
        if (child.style.position == .absolute or child.style.position == .anchored) {
            measureNode(child, text_layouter, @max(0, final_content_w), @max(0, final_content_h), force_recalculate);
        }
    }

    const max_scroll_x = @max(0.0, node.layout_result.content_width - node.layout_result.width);
    const max_scroll_y = @max(0.0, node.layout_result.content_height - node.layout_result.height);
    node.scroll_x = std.math.clamp(node.scroll_x, 0.0, max_scroll_x);
    node.scroll_y = std.math.clamp(node.scroll_y, 0.0, max_scroll_y);

    node.layout_result.measured_max_w = max_w;
    node.layout_result.measured_max_h = max_h;
}

fn measureLeafContent(
    node: anytype,
    text_layouter: anytype,
    content_w: f32,
    out_w: *f32,
    out_h: *f32,
) void {
    switch (node.payload) {
        .text => |t| {
            const options = resolveTextMeasureOptions(node.style, t.max_width, content_w, false, false);
            const cache = node.layout_result.text_cache;
            const options_changed = cache.max_width != options.max_width or
                cache.wrap != options.wrap or
                cache.ellipsis != options.ellipsis or
                cache.line_height != options.line_height or
                cache.font_size != options.font_size;
            if (node.flags.content or node.flags.size or options_changed) {
                updateTextLayoutCache(node, text_layouter, t.font, t.content, options);
            }
            out_w.* = node.layout_result.text_cache.width;
            out_h.* = node.layout_result.text_cache.height;
        },
        .image => |img| {
            if (img.fallback_state != .ready and img.alt_text.len > 0 and img.alt_font != null) {
                const options = resolveTextMeasureOptions(node.style, 0.0, content_w, false, false);
                const cache = node.layout_result.text_cache;
                const options_changed = cache.max_width != options.max_width or
                    cache.wrap != options.wrap or
                    cache.ellipsis != options.ellipsis or
                    cache.line_height != options.line_height or
                    cache.font_size != options.font_size;
                if (node.flags.content or node.flags.size or options_changed) {
                    updateTextLayoutCache(node, text_layouter, img.alt_font.?, img.alt_text, options);
                }
                out_w.* = node.layout_result.text_cache.width;
                out_h.* = node.layout_result.text_cache.height;
            } else if (img.intrinsic_size[0] > 0.0 and img.intrinsic_size[1] > 0.0) {
                node.layout_result.text_cache.clear(node.allocator);
                out_w.* = img.intrinsic_size[0];
                out_h.* = img.intrinsic_size[1];
            } else {
                node.layout_result.text_cache.clear(node.allocator);
                out_w.* = 0;
                out_h.* = 0;
            }
        },
        .canvas => |canvas_payload| {
            node.layout_result.text_cache.clear(node.allocator);
            out_w.* = @floatFromInt(canvas_payload.target.width);
            out_h.* = @floatFromInt(canvas_payload.target.height);
        },
        .text_input => |input| {
            const options = resolveTextMeasureOptions(node.style, input.max_width, content_w, false, false);
            const cache = node.layout_result.text_cache;
            const options_changed = cache.max_width != options.max_width or
                cache.wrap != options.wrap or
                cache.ellipsis != options.ellipsis or
                cache.line_height != options.line_height or
                cache.font_size != options.font_size;
            // When buffer is empty, shape the placeholder so the box keeps
            // intrinsic size and the renderer naturally draws the placeholder
            // glyphs (with `placeholder_color` instead of `text_color`).
            const measure_text = if (input.buffer.items.len == 0) input.placeholder else input.buffer.items;
            // Re-shape when dirty OR when the box is empty (cache may be holding
            // either the placeholder or stale buffer text - re-shaping is cheap
            // for one short string and avoids losing the placeholder render).
            const empty_force = input.buffer.items.len == 0 and input.placeholder.len > 0;
            if (node.flags.content or node.flags.size or options_changed or empty_force) {
                updateTextLayoutCache(node, text_layouter, input.font, measure_text, options);
            }
            out_w.* = node.layout_result.text_cache.width;
            // Even with an empty placeholder, give the input one line-height of
            // room so the cursor (and an eventually-typed first character) fit.
            if (input.buffer.items.len == 0 and input.placeholder.len == 0) {
                const font_scale = if (node.style.font_size > 0.0) (node.style.font_size / input.font.base_size) else 1.0;
                out_h.* = input.font.line_height * font_scale;
            } else {
                out_h.* = node.layout_result.text_cache.height;
            }
        },
        .text_area => |input| {
            const options = resolveTextMeasureOptions(node.style, input.max_width, content_w, false, true);
            const cache = node.layout_result.text_cache;
            const options_changed = cache.max_width != options.max_width or
                cache.wrap != options.wrap or
                cache.ellipsis != options.ellipsis or
                cache.line_height != options.line_height or
                cache.font_size != options.font_size;
            if (node.flags.content or node.flags.size or options_changed) {
                updateTextLayoutCache(node, text_layouter, input.font, input.buffer.items, options);
            }
            out_w.* = node.layout_result.text_cache.width;
            out_h.* = node.layout_result.text_cache.height;
        },
        else => {
            node.layout_result.text_cache.clear(node.allocator);
            out_w.* = 0;
            out_h.* = 0;
        },
    }
}

fn measureFlexContentNoWrap(
    node: anytype,
    text_layouter: anytype,
    content_w: f32,
    content_h: f32,
    resolved_width: ?f32,
    resolved_height: ?f32,
    out_w: *f32,
    out_h: *f32,
) void {
    const is_row = node.style.direction == .Row;

    for (node.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .anchored) continue;
        if (child.style.display == .none) continue;
        if (child.style.flex_grow > 0) continue; // deferred
        measureNode(child, text_layouter, content_w, content_h, false);
    }

    var fixed_main: f32 = 0;
    var total_flex_grow: f32 = 0;
    var flex_count: usize = 0;
    var flow_count: usize = 0;

    for (node.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .anchored) continue;
        if (child.style.display == .none) continue;
        flow_count += 1;
        const margin = child.style.margin;
        const margin_main = if (is_row) margin.left + margin.right else margin.top + margin.bottom;
        if (child.style.flex_grow > 0) {
            total_flex_grow += child.style.flex_grow;
            flex_count += 1;
            fixed_main += margin_main;
        } else {
            fixed_main += if (is_row)
                child.layout_result.width + margin_main
            else
                child.layout_result.height + margin_main;
        }
    }

    const total_gap: f32 = if (flow_count > 1)
        node.style.gap * @as(f32, @floatFromInt(flow_count - 1))
    else
        0;

    if (flex_count > 0 and total_flex_grow > 0) {
        const insets = contentInsets(node.style);
        const parent_main = if (is_row)
            (resolved_width orelse (content_w + insets.horizontal())) - insets.horizontal()
        else
            (resolved_height orelse (content_h + insets.vertical())) - insets.vertical();

        const remaining = @max(0.0, parent_main - fixed_main - total_gap);

        for (node.children.items) |child| {
            if (child.style.position == .absolute or child.style.position == .anchored) continue;
            if (child.style.display == .none) continue;
            if (child.style.flex_grow <= 0) continue;

            const allocated = remaining * (child.style.flex_grow / total_flex_grow);
            if (is_row) {
                measureNode(child, text_layouter, @max(0, allocated), content_h, true);
                child.layout_result.width = clampAxisByStyle(
                    allocated,
                    child.style.min_width,
                    child.style.max_width,
                    allocated,
                );
            } else {
                measureNode(child, text_layouter, content_w, @max(0, allocated), true);
                child.layout_result.height = clampAxisByStyle(
                    allocated,
                    child.style.min_height,
                    child.style.max_height,
                    allocated,
                );
            }
        }
    }

    node.layout_result.text_cache.clear(node.allocator);

    var main_size: f32 = 0;
    var cross_size: f32 = 0;
    var first = true;

    for (node.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .anchored) continue;
        if (child.style.display == .none) continue;

        if (!first) main_size += node.style.gap;
        first = false;

        const margin = child.style.margin;
        const child_main = if (is_row)
            child.layout_result.width + margin.left + margin.right
        else
            child.layout_result.height + margin.top + margin.bottom;

        const child_cross = if (is_row)
            child.layout_result.height + margin.top + margin.bottom
        else
            child.layout_result.width + margin.left + margin.right;

        main_size += child_main;
        cross_size = @max(cross_size, child_cross);
    }

    out_w.* = if (is_row) main_size else cross_size;
    out_h.* = if (is_row) cross_size else main_size;
}

fn measureFlexContentWrap(
    node: anytype,
    text_layouter: anytype,
    content_w: f32,
    content_h: f32,
    out_w: *f32,
    out_h: *f32,
) void {
    const is_row = node.style.direction == .Row;
    const main_limit = if (is_row) content_w else content_h;

    for (node.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .anchored) continue;
        if (child.style.display == .none) continue;
        measureNode(child, text_layouter, content_w, content_h, false);
    }

    node.layout_result.text_cache.clear(node.allocator);

    var line_main: f32 = 0;
    var line_cross: f32 = 0;
    var line_has_items = false;

    var max_line_main: f32 = 0;
    var total_cross: f32 = 0;
    var line_count: usize = 0;

    for (node.children.items) |child| {
        if (child.style.position == .absolute or child.style.position == .anchored) continue;
        if (child.style.display == .none) continue;

        const margin = child.style.margin;
        const child_main = if (is_row)
            child.layout_result.width + margin.left + margin.right
        else
            child.layout_result.height + margin.top + margin.bottom;

        const child_cross = if (is_row)
            child.layout_result.height + margin.top + margin.bottom
        else
            child.layout_result.width + margin.left + margin.right;

        const tentative_main = if (line_has_items)
            line_main + node.style.gap + child_main
        else
            child_main;

        const should_wrap = line_has_items and main_limit > 0.0 and tentative_main > main_limit;
        if (should_wrap) {
            max_line_main = @max(max_line_main, line_main);
            if (line_count > 0) total_cross += node.style.gap;
            total_cross += line_cross;
            line_count += 1;

            line_main = child_main;
            line_cross = child_cross;
        } else {
            if (line_has_items) line_main += node.style.gap;
            line_main += child_main;
            line_cross = @max(line_cross, child_cross);
        }

        line_has_items = true;
    }

    if (line_has_items) {
        max_line_main = @max(max_line_main, line_main);
        if (line_count > 0) total_cross += node.style.gap;
        total_cross += line_cross;
        line_count += 1;
    }

    out_w.* = if (is_row) max_line_main else total_cross;
    out_h.* = if (is_row) total_cross else max_line_main;
}

fn measureFlexContent(
    node: anytype,
    text_layouter: anytype,
    content_w: f32,
    content_h: f32,
    resolved_width: ?f32,
    resolved_height: ?f32,
    out_w: *f32,
    out_h: *f32,
) void {
    if (node.children.items.len == 0) {
        measureLeafContent(node, text_layouter, content_w, out_w, out_h);
        return;
    }

    if (node.style.flex_wrap == .Wrap) {
        measureFlexContentWrap(node, text_layouter, content_w, content_h, out_w, out_h);
        return;
    }

    measureFlexContentNoWrap(
        node,
        text_layouter,
        content_w,
        content_h,
        resolved_width,
        resolved_height,
        out_w,
        out_h,
    );
}

fn GridPlacement(comptime ChildPtr: type) type {
    return struct {
        child: ChildPtr,
        column_start: usize,
        row_start: usize,
        column_span: usize,
        row_span: usize,
    };
}

const GridRowSizing = struct {
    size: f32 = 0.0,
    growable: bool = true,
    fr: f32 = 0.0,
};

const GridCell = struct {
    row: usize,
    col: usize,
};

fn normalizeGridSpan(span_raw: u16) usize {
    const span = @as(usize, @intCast(span_raw));
    return if (span == 0) 1 else span;
}

fn normalizeGridStart(start_1_based: ?u16) ?usize {
    if (start_1_based) |v| {
        if (v == 0) return null;
        return @as(usize, @intCast(v - 1));
    }
    return null;
}

fn ensureGridOccupancyRows(
    occupancy: *std.ArrayList(bool),
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
) !void {
    const needed = rows * cols;
    while (occupancy.items.len < needed) {
        try occupancy.append(allocator, false);
    }
}

fn gridAreaIsFree(
    occupancy: []const bool,
    cols: usize,
    row_start: usize,
    col_start: usize,
    row_span: usize,
    col_span: usize,
) bool {
    var r: usize = 0;
    while (r < row_span) : (r += 1) {
        var c: usize = 0;
        while (c < col_span) : (c += 1) {
            const idx = (row_start + r) * cols + (col_start + c);
            if (occupancy[idx]) return false;
        }
    }
    return true;
}

fn markGridArea(
    occupancy: []bool,
    cols: usize,
    row_start: usize,
    col_start: usize,
    row_span: usize,
    col_span: usize,
) void {
    var r: usize = 0;
    while (r < row_span) : (r += 1) {
        var c: usize = 0;
        while (c < col_span) : (c += 1) {
            const idx = (row_start + r) * cols + (col_start + c);
            occupancy[idx] = true;
        }
    }
}

fn findGridColumnForRow(
    occupancy: []const bool,
    cols: usize,
    row_start: usize,
    row_span: usize,
    col_span: usize,
) ?usize {
    if (col_span > cols) return null;

    var col: usize = 0;
    while (col + col_span <= cols) : (col += 1) {
        if (gridAreaIsFree(occupancy, cols, row_start, col, row_span, col_span)) {
            return col;
        }
    }

    return null;
}

fn findGridRowForColumn(
    occupancy: *std.ArrayList(bool),
    allocator: std.mem.Allocator,
    cols: usize,
    col_start: usize,
    row_span: usize,
    col_span: usize,
    start_row: usize,
) !usize {
    var row = start_row;
    while (true) : (row += 1) {
        try ensureGridOccupancyRows(occupancy, allocator, cols, row + row_span);
        if (gridAreaIsFree(occupancy.items, cols, row, col_start, row_span, col_span)) {
            return row;
        }
    }
}

fn findGridAutoPlacement(
    occupancy: *std.ArrayList(bool),
    allocator: std.mem.Allocator,
    cols: usize,
    row_span: usize,
    col_span: usize,
    start_row: usize,
    start_col: usize,
) !GridCell {
    var row = start_row;
    var col = start_col;

    while (true) {
        try ensureGridOccupancyRows(occupancy, allocator, cols, row + row_span);

        while (col + col_span <= cols) : (col += 1) {
            if (gridAreaIsFree(occupancy.items, cols, row, col, row_span, col_span)) {
                return .{ .row = row, .col = col };
            }
        }

        row += 1;
        col = 0;
    }
}

fn buildGridPlacements(
    node: anytype,
    allocator: std.mem.Allocator,
    cols: usize,
) !std.ArrayList(GridPlacement(@typeInfo(@TypeOf(node.children.items)).pointer.child)) {
    var placements = std.ArrayList(GridPlacement(@typeInfo(@TypeOf(node.children.items)).pointer.child)).empty;
    errdefer placements.deinit(allocator);

    var occupancy = std.ArrayList(bool).empty;
    defer occupancy.deinit(allocator);

    var auto_row_cursor: usize = 0;
    var auto_col_cursor: usize = 0;

    for (node.children.items) |child| {
        if (!isFlowChild(child)) continue;

        var col_span = normalizeGridSpan(child.style.grid_column_span);
        var row_span = normalizeGridSpan(child.style.grid_row_span);
        if (col_span > cols) col_span = cols;
        if (row_span == 0) row_span = 1;

        const max_col_start = if (cols > col_span) cols - col_span else 0;
        const explicit_col_start = if (normalizeGridStart(child.style.grid_column_start)) |v|
            @min(v, max_col_start)
        else
            null;
        const explicit_row_start = normalizeGridStart(child.style.grid_row_start);

        var row_start: usize = 0;
        var col_start: usize = 0;
        var should_advance_auto_cursor = true;

        if (explicit_row_start != null and explicit_col_start != null) {
            row_start = explicit_row_start.?;
            col_start = explicit_col_start.?;
            try ensureGridOccupancyRows(&occupancy, allocator, cols, row_start + row_span);
            should_advance_auto_cursor = false;
        } else if (explicit_row_start != null) {
            var candidate_row = explicit_row_start.?;
            while (true) : (candidate_row += 1) {
                try ensureGridOccupancyRows(&occupancy, allocator, cols, candidate_row + row_span);
                if (findGridColumnForRow(occupancy.items, cols, candidate_row, row_span, col_span)) |candidate_col| {
                    row_start = candidate_row;
                    col_start = candidate_col;
                    break;
                }
            }
        } else if (explicit_col_start != null) {
            col_start = explicit_col_start.?;
            row_start = try findGridRowForColumn(
                &occupancy,
                allocator,
                cols,
                col_start,
                row_span,
                col_span,
                auto_row_cursor,
            );
        } else {
            const found = try findGridAutoPlacement(
                &occupancy,
                allocator,
                cols,
                row_span,
                col_span,
                auto_row_cursor,
                auto_col_cursor,
            );
            row_start = found.row;
            col_start = found.col;
        }

        markGridArea(occupancy.items, cols, row_start, col_start, row_span, col_span);

        if (should_advance_auto_cursor) {
            auto_row_cursor = row_start;
            auto_col_cursor = col_start + col_span;
            while (auto_col_cursor >= cols) {
                auto_col_cursor -= cols;
                auto_row_cursor += 1;
            }
        }

        try placements.append(allocator, .{
            .child = child,
            .column_start = col_start,
            .row_start = row_start,
            .column_span = col_span,
            .row_span = row_span,
        });
    }

    return placements;
}

fn requiredGridRowCount(style: Style, placements: anytype) usize {
    var row_count = style.grid_template_rows.count();
    for (placements) |placement| {
        row_count = @max(row_count, placement.row_start + placement.row_span);
    }
    return row_count;
}

fn resolveGridColumnSizes(
    style: Style,
    allocator: std.mem.Allocator,
    cols: usize,
    content_w: f32,
    gap: f32,
) !std.ArrayList(f32) {
    var sizes = std.ArrayList(f32).empty;
    errdefer sizes.deinit(allocator);

    var fr_weights = std.ArrayList(f32).empty;
    defer fr_weights.deinit(allocator);

    const gap_total = if (cols > 1)
        gap * @as(f32, @floatFromInt(cols - 1))
    else
        0.0;
    const available_for_tracks = @max(0.0, content_w - gap_total);

    var fixed_total: f32 = 0.0;
    var fr_total: f32 = 0.0;

    var i: usize = 0;
    while (i < cols) : (i += 1) {
        const track = getGridColumnTrack(style, i);

        var size: f32 = 0.0;
        var fr_weight: f32 = 0.0;

        switch (track) {
            .exact => |px| {
                size = @max(0.0, px);
                fixed_total += size;
            },
            .percent => |pct| {
                size = available_for_tracks * @max(0.0, pct);
                fixed_total += size;
            },
            .fr => |fr| {
                fr_weight = @max(0.0, fr);
                fr_total += fr_weight;
            },
            .Auto => {
                fr_weight = 1.0;
                fr_total += fr_weight;
            },
        }

        try sizes.append(allocator, size);
        try fr_weights.append(allocator, fr_weight);
    }

    const remaining = @max(0.0, available_for_tracks - fixed_total);
    if (fr_total > 0.0) {
        for (sizes.items, fr_weights.items) |*size, fr_weight| {
            if (fr_weight <= 0.0) continue;
            size.* = remaining * (fr_weight / fr_total);
        }
    }

    return sizes;
}

fn initGridRowSizing(
    style: Style,
    allocator: std.mem.Allocator,
    row_count: usize,
    content_h: f32,
    has_explicit_height: bool,
) !std.ArrayList(GridRowSizing) {
    var rows = std.ArrayList(GridRowSizing).empty;
    errdefer rows.deinit(allocator);

    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const track = getGridRowTrack(style, i);
        var row = GridRowSizing{};

        switch (track) {
            .exact => |px| {
                row.size = @max(0.0, px);
                row.growable = false;
            },
            .percent => |pct| {
                if (has_explicit_height) {
                    row.size = content_h * @max(0.0, pct);
                    row.growable = false;
                } else {
                    row.size = 0.0;
                    row.growable = true;
                }
            },
            .fr => |fr| {
                row.size = 0.0;
                row.growable = true;
                row.fr = @max(0.0, fr);
            },
            .Auto => {
                row.size = 0.0;
                row.growable = true;
            },
        }

        try rows.append(allocator, row);
    }

    return rows;
}

fn gridTrackSpanSize(track_sizes: []const f32, gap: f32, start: usize, span: usize) f32 {
    if (span == 0) return 0.0;

    var total: f32 = if (span > 1)
        gap * @as(f32, @floatFromInt(span - 1))
    else
        0.0;

    var i: usize = 0;
    while (i < span) : (i += 1) {
        total += track_sizes[start + i];
    }

    return total;
}

fn gridTrackStartOffset(track_sizes: []const f32, gap: f32, track_index: usize) f32 {
    if (track_index == 0) return 0.0;

    var offset: f32 = 0.0;
    var i: usize = 0;
    while (i < track_index) : (i += 1) {
        offset += track_sizes[i] + gap;
    }

    return offset;
}

fn gridRowSpanSize(row_sizes: []const GridRowSizing, gap: f32, start: usize, span: usize) f32 {
    if (span == 0) return 0.0;

    var total: f32 = if (span > 1)
        gap * @as(f32, @floatFromInt(span - 1))
    else
        0.0;

    var i: usize = 0;
    while (i < span) : (i += 1) {
        total += row_sizes[start + i].size;
    }

    return total;
}

fn gridRowStartOffset(row_sizes: []const GridRowSizing, gap: f32, row_index: usize) f32 {
    if (row_index == 0) return 0.0;

    var offset: f32 = 0.0;
    var i: usize = 0;
    while (i < row_index) : (i += 1) {
        offset += row_sizes[i].size + gap;
    }

    return offset;
}

fn growGridRowsForPlacement(
    row_sizes: []GridRowSizing,
    placement: anytype,
    required_height: f32,
    gap: f32,
) void {
    const current = gridRowSpanSize(row_sizes, gap, placement.row_start, placement.row_span);
    if (required_height <= current) return;

    var growable_count: usize = 0;
    var i: usize = 0;
    while (i < placement.row_span) : (i += 1) {
        if (row_sizes[placement.row_start + i].growable) {
            growable_count += 1;
        }
    }
    if (growable_count == 0) return;

    const extra_each = (required_height - current) / @as(f32, @floatFromInt(growable_count));
    i = 0;
    while (i < placement.row_span) : (i += 1) {
        const row_index = placement.row_start + i;
        if (!row_sizes[row_index].growable) continue;
        row_sizes[row_index].size += extra_each;
    }
}

fn totalGridRowHeight(row_sizes: []const GridRowSizing, gap: f32) f32 {
    if (row_sizes.len == 0) return 0.0;

    var total: f32 = if (row_sizes.len > 1)
        gap * @as(f32, @floatFromInt(row_sizes.len - 1))
    else
        0.0;

    for (row_sizes) |row| {
        total += row.size;
    }

    return total;
}

fn applyGridFrRows(row_sizes: []GridRowSizing, content_h: f32, gap: f32, has_explicit_height: bool) void {
    if (!has_explicit_height) return;

    var fr_total: f32 = 0.0;
    for (row_sizes) |row| {
        fr_total += row.fr;
    }
    if (fr_total <= 0.0) return;

    const current_total = totalGridRowHeight(row_sizes, gap);
    const remaining = content_h - current_total;
    if (remaining <= 0.0) return;

    for (row_sizes) |*row| {
        if (row.fr <= 0.0) continue;
        row.size += remaining * (row.fr / fr_total);
    }
}

fn measureGridContent(
    node: anytype,
    text_layouter: anytype,
    content_w: f32,
    content_h: f32,
    has_explicit_height: bool,
    out_w: *f32,
    out_h: *f32,
) void {
    const cols = effectiveGridColumnCount(node.style);
    if (cols == 0) {
        node.layout_result.text_cache.clear(node.allocator);
        out_w.* = 0.0;
        out_h.* = 0.0;
        return;
    }

    var column_sizes = resolveGridColumnSizes(node.style, node.allocator, cols, content_w, node.style.gap) catch
        @panic("OOM while resolving grid column sizes");
    defer column_sizes.deinit(node.allocator);

    var placements = buildGridPlacements(node, node.allocator, cols) catch
        @panic("OOM while building grid placements");
    defer placements.deinit(node.allocator);

    const row_count = requiredGridRowCount(node.style, placements.items);

    var row_sizes = initGridRowSizing(node.style, node.allocator, row_count, content_h, has_explicit_height) catch
        @panic("OOM while initializing grid row sizing");
    defer row_sizes.deinit(node.allocator);

    for (placements.items) |placement| {
        const child = placement.child;
        const area_w = gridTrackSpanSize(column_sizes.items, node.style.gap, placement.column_start, placement.column_span);
        const child_available_w = @max(0.0, area_w - child.style.margin.horizontal());

        measureNode(child, text_layouter, child_available_w, content_h, false);

        if (child.style.width == .Auto) {
            child.layout_result.width = clampAxisByStyle(
                child_available_w,
                child.style.min_width,
                child.style.max_width,
                child_available_w,
            );
        }

        const required_h = child.layout_result.height + child.style.margin.top + child.style.margin.bottom;
        growGridRowsForPlacement(row_sizes.items, placement, required_h, node.style.gap);
    }

    applyGridFrRows(row_sizes.items, content_h, node.style.gap, has_explicit_height);

    node.layout_result.text_cache.clear(node.allocator);
    out_w.* = content_w;
    out_h.* = totalGridRowHeight(row_sizes.items, node.style.gap);
}

pub fn arrangeNode(node: anytype, start_x: f32, start_y: f32) void {
    if (node.style.display == .none) return;

    if (!node.flags.position) {
        const delta_x = start_x - node.layout_result.x;
        const delta_y = start_y - node.layout_result.y;
        if (delta_x != 0.0 or delta_y != 0.0) {
            translateSubTree(node, delta_x, delta_y);
        }
        return;
    }

    node.layout_result.x = start_x;
    node.layout_result.y = start_y;

    const w = node.layout_result.width;
    const h = node.layout_result.height;

    if (node.style.display == .grid and isGridLayoutEnabled(node.style)) {
        arrangeGridChildren(node, start_x, start_y, w, h);
    } else {
        arrangeFlexChildren(node, start_x, start_y, w, h);
    }

    for (node.children.items, 0..) |child, i| {
        prefetchNextChildIfEnabled(node.children.items, i);
        if (child.style.position != .absolute and child.style.position != .anchored) continue;

        const insets = contentInsets(node.style);

        const parent_origin_x = if (child.payload == .portal) 0.0 else start_x + insets.left;
        const parent_origin_y = if (child.payload == .portal) 0.0 else start_y + insets.top;
        const parent_far_x = if (child.payload == .portal) 0.0 else start_x + w - insets.right;
        const parent_far_y = if (child.payload == .portal) 0.0 else start_y + h - insets.bottom;

        var child_x = parent_origin_x;
        var child_y = parent_origin_y;

        if (child.style.left) |l| {
            child_x = parent_origin_x + l;
            if (child.style.right) |r| {
                if (child.style.width == .Auto) {
                    child.layout_result.width = @max(0.0, parent_far_x - r - child_x);
                }
            }
        } else if (child.style.right) |r| {
            child_x = parent_far_x - child.layout_result.width - r;
        }

        if (child.style.top) |t| {
            child_y = parent_origin_y + t;
            if (child.style.bottom) |b| {
                if (child.style.height == .Auto) {
                    child.layout_result.height = @max(0.0, parent_far_y - b - child_y);
                }
            }
        } else if (child.style.bottom) |b| {
            child_y = parent_far_y - child.layout_result.height - b;
        }

        arrangeNode(child, child_x, child_y);
    }

    node.flags = .{
        .position = false,
        .size = false,
        .content = false,
    };
}

fn isFlowChild(child: anytype) bool {
    return child.style.position != .absolute and
        child.style.position != .anchored and
        child.style.display != .none;
}

fn nodeAspectRatio(node: anytype) ?f32 {
    switch (node.payload) {
        .image => |img| {
            if (img.intrinsic_size[0] > 0.0 and img.intrinsic_size[1] > 0.0) {
                return img.intrinsic_size[0] / img.intrinsic_size[1];
            }
        },
        .video => |v| {
            const vw = @as(f32, @floatFromInt(v.playback.width));
            const vh = @as(f32, @floatFromInt(v.playback.height));
            if (vw > 0.0 and vh > 0.0) {
                return vw / vh;
            }
        },
        else => {},
    }
    return null;
}

fn arrangeFlexChildrenNoWrap(node: anytype, start_x: f32, start_y: f32, w: f32, h: f32) void {
    const is_row = node.style.direction == .Row;
    const pad = contentInsets(node.style);
    const scroll_main = if (is_row) node.scroll_x else node.scroll_y;
    const scroll_cross = if (is_row) node.scroll_y else node.scroll_x;

    var children_main_sum: f32 = 0;
    var flow_count: usize = 0;
    for (node.children.items, 0..) |child, i| {
        prefetchNextChildIfEnabled(node.children.items, i);
        if (!isFlowChild(child)) continue;
        flow_count += 1;
        const margin = child.style.margin;
        children_main_sum += if (is_row)
            child.layout_result.width + margin.left + margin.right
        else
            child.layout_result.height + margin.top + margin.bottom;
    }

    const inner_main: f32 = if (is_row) w - pad.horizontal() else h - pad.vertical();
    const inner_cross: f32 = if (is_row) h - pad.vertical() else w - pad.horizontal();

    var between_gap: f32 = node.style.gap;
    var start_offset: f32 = 0;

    if (flow_count > 0) {
        const total_gap = node.style.gap * @as(f32, @floatFromInt(if (flow_count > 1) flow_count - 1 else 0));
        const total_children = children_main_sum + total_gap;
        const remaining = inner_main - total_children;

        switch (node.style.justify_content) {
            .Start => {},
            .Center => start_offset = @max(0, remaining) / 2.0,
            .End => start_offset = @max(0, remaining),
            .SpaceBetween => {
                if (flow_count > 1) {
                    between_gap = @max(0, inner_main - children_main_sum) / @as(f32, @floatFromInt(flow_count - 1));
                }
                start_offset = 0;
            },
            .SpaceAround => {
                const space = @max(0, inner_main - children_main_sum) / @as(f32, @floatFromInt(flow_count));
                between_gap = space;
                start_offset = space / 2.0;
            },
        }
    }

    var cursor: f32 = (if (is_row) start_x else start_y) +
        (if (is_row) pad.left else pad.top) +
        start_offset - scroll_main;
    var first = true;

    for (node.children.items) |child| {
        if (!isFlowChild(child)) continue;

        if (!first) cursor += between_gap;
        first = false;

        const margin = child.style.margin;
        const main_margin_start = if (is_row) margin.left else margin.top;
        const main_margin_end = if (is_row) margin.right else margin.bottom;
        const child_main_start = cursor + main_margin_start;

        const cross_base: f32 = (if (is_row) start_y else start_x) - scroll_cross;
        const cross_pad_start = if (is_row) pad.top else pad.left;
        const cross_margin_start = if (is_row) margin.top else margin.left;
        const cross_margin_end = if (is_row) margin.bottom else margin.right;

        const child_align_self = if (child.style.align_self != .Auto)
            @as(FlexAlign, @enumFromInt(@intFromEnum(child.style.align_self) - 1))
        else
            node.style.align_items;

        if (child_align_self == .Stretch) {
            const target_cross = @max(0.0, inner_cross - cross_margin_start - cross_margin_end);
            if (is_row) {
                if (child.style.height == .Auto) child.layout_result.height = target_cross;
            } else {
                if (child.style.width == .Auto) child.layout_result.width = target_cross;
            }
        }

        const child_cross_extent = if (is_row) child.layout_result.height else child.layout_result.width;
        const child_cross_start: f32 = switch (child_align_self) {
            .Start => cross_base + cross_pad_start + cross_margin_start,
            .Center => cross_base + cross_pad_start +
                @max(0.0, inner_cross - child_cross_extent - cross_margin_start - cross_margin_end) / 2.0 +
                cross_margin_start,
            .End => cross_base + cross_pad_start + inner_cross - child_cross_extent - cross_margin_end,
            .Stretch => cross_base + cross_pad_start + cross_margin_start,
        };

        const child_x = if (is_row) child_main_start else child_cross_start;
        const child_y = if (is_row) child_cross_start else child_main_start;

        arrangeNode(child, child_x, child_y);

        cursor += (if (is_row)
            child.layout_result.width
        else
            child.layout_result.height) + main_margin_start + main_margin_end;
    }
}

fn arrangeFlexChildrenWrap(node: anytype, start_x: f32, start_y: f32, w: f32, h: f32) void {
    const is_row = node.style.direction == .Row;
    const pad = contentInsets(node.style);

    const scroll_main = if (is_row) node.scroll_x else node.scroll_y;
    const scroll_cross = if (is_row) node.scroll_y else node.scroll_x;

    const inner_main: f32 = @max(0.0, if (is_row) w - pad.horizontal() else h - pad.vertical());
    const cross_limit: f32 = @max(0.0, if (is_row) h - pad.vertical() else w - pad.horizontal());

    const main_origin: f32 =
        (if (is_row) start_x else start_y) +
        (if (is_row) pad.left else pad.top) -
        scroll_main;

    var line_cross_cursor: f32 =
        (if (is_row) start_y else start_x) +
        (if (is_row) pad.top else pad.left) -
        scroll_cross;

    var i: usize = 0;
    while (i < node.children.items.len) {
        while (i < node.children.items.len and !isFlowChild(node.children.items[i])) : (i += 1) {}
        if (i >= node.children.items.len) break;

        var j = i;
        var line_main: f32 = 0;
        var line_children_main_sum: f32 = 0;
        var line_cross: f32 = 0;
        var line_flow_count: usize = 0;

        while (j < node.children.items.len) : (j += 1) {
            const child = node.children.items[j];
            if (!isFlowChild(child)) continue;

            const margin = child.style.margin;
            const child_main = if (is_row)
                child.layout_result.width + margin.left + margin.right
            else
                child.layout_result.height + margin.top + margin.bottom;

            const child_cross = if (is_row)
                child.layout_result.height + margin.top + margin.bottom
            else
                child.layout_result.width + margin.left + margin.right;

            const tentative_main = if (line_flow_count > 0)
                line_main + node.style.gap + child_main
            else
                child_main;

            if (line_flow_count > 0 and inner_main > 0.0 and tentative_main > inner_main) {
                break;
            }

            if (line_flow_count > 0) line_main += node.style.gap;
            line_main += child_main;
            line_children_main_sum += child_main;
            line_cross = @max(line_cross, child_cross);
            line_flow_count += 1;
        }

        var between_gap: f32 = node.style.gap;
        var start_offset: f32 = 0;

        if (line_flow_count > 0) {
            const remaining = inner_main - line_main;
            switch (node.style.justify_content) {
                .Start => {},
                .Center => start_offset = @max(0.0, remaining) / 2.0,
                .End => start_offset = @max(0.0, remaining),
                .SpaceBetween => {
                    if (line_flow_count > 1) {
                        between_gap = @max(0.0, inner_main - line_children_main_sum) /
                            @as(f32, @floatFromInt(line_flow_count - 1));
                    }
                    start_offset = 0;
                },
                .SpaceAround => {
                    const space = @max(0.0, inner_main - line_children_main_sum) /
                        @as(f32, @floatFromInt(line_flow_count));
                    between_gap = space;
                    start_offset = space / 2.0;
                },
            }
        }

        var cursor = main_origin + start_offset;
        var first_in_line = true;

        var k = i;
        while (k < j) : (k += 1) {
            const child = node.children.items[k];
            if (!isFlowChild(child)) continue;

            if (!first_in_line) cursor += between_gap;
            first_in_line = false;

            const margin = child.style.margin;
            const main_margin_start = if (is_row) margin.left else margin.top;
            const main_margin_end = if (is_row) margin.right else margin.bottom;
            const child_main_start = cursor + main_margin_start;

            const cross_margin_start = if (is_row) margin.top else margin.left;
            const cross_margin_end = if (is_row) margin.bottom else margin.right;

            const child_align_self = if (child.style.align_self != .Auto)
                @as(FlexAlign, @enumFromInt(@intFromEnum(child.style.align_self) - 1))
            else
                node.style.align_items;

            if (child_align_self == .Stretch and nodeAspectRatio(child) == null) {
                const stretched_cross = @max(0.0, line_cross - cross_margin_start - cross_margin_end);
                if (is_row) {
                    child.layout_result.height = clampAxisByStyle(
                        stretched_cross,
                        child.style.min_height,
                        child.style.max_height,
                        cross_limit,
                    );
                } else {
                    child.layout_result.width = clampAxisByStyle(
                        stretched_cross,
                        child.style.min_width,
                        child.style.max_width,
                        cross_limit,
                    );
                }
            }

            const child_cross_extent = if (is_row) child.layout_result.height else child.layout_result.width;
            const child_cross_start = switch (child_align_self) {
                .Start => line_cross_cursor + cross_margin_start,
                .Center => line_cross_cursor + cross_margin_start +
                    @max(0.0, line_cross - child_cross_extent - cross_margin_start - cross_margin_end) / 2.0,
                .End => line_cross_cursor + line_cross - child_cross_extent - cross_margin_end,
                .Stretch => line_cross_cursor + cross_margin_start,
            };

            const child_x = if (is_row) child_main_start else child_cross_start;
            const child_y = if (is_row) child_cross_start else child_main_start;

            arrangeNode(child, child_x, child_y);

            cursor += (if (is_row)
                child.layout_result.width
            else
                child.layout_result.height) + main_margin_start + main_margin_end;
        }

        line_cross_cursor += line_cross + node.style.gap;
        i = j;
    }
}

fn arrangeFlexChildren(node: anytype, start_x: f32, start_y: f32, w: f32, h: f32) void {
    if (node.style.flex_wrap == .Wrap) {
        arrangeFlexChildrenWrap(node, start_x, start_y, w, h);
        return;
    }

    arrangeFlexChildrenNoWrap(node, start_x, start_y, w, h);
}

fn arrangeGridChildren(node: anytype, start_x: f32, start_y: f32, w: f32, h: f32) void {
    const cols = effectiveGridColumnCount(node.style);
    if (cols == 0) return;

    const pad = contentInsets(node.style);
    const content_w = @max(0.0, w - pad.horizontal());
    const content_h = @max(0.0, h - pad.vertical());
    const has_explicit_height = switch (node.style.height) {
        .Auto => false,
        else => true,
    };

    var column_sizes = resolveGridColumnSizes(node.style, node.allocator, cols, content_w, node.style.gap) catch
        @panic("OOM while resolving grid columns during arrangement");
    defer column_sizes.deinit(node.allocator);

    var placements = buildGridPlacements(node, node.allocator, cols) catch
        @panic("OOM while building grid placements during arrangement");
    defer placements.deinit(node.allocator);

    const row_count = requiredGridRowCount(node.style, placements.items);
    var row_sizes = initGridRowSizing(node.style, node.allocator, row_count, content_h, has_explicit_height) catch
        @panic("OOM while resolving grid rows during arrangement");
    defer row_sizes.deinit(node.allocator);

    for (placements.items) |placement| {
        const child = placement.child;
        const required_h = child.layout_result.height + child.style.margin.top + child.style.margin.bottom;
        growGridRowsForPlacement(row_sizes.items, placement, required_h, node.style.gap);
    }
    applyGridFrRows(row_sizes.items, content_h, node.style.gap, has_explicit_height);

    const origin_x = start_x + pad.left - node.scroll_x;
    const origin_y = start_y + pad.top - node.scroll_y;

    for (placements.items) |placement| {
        const child = placement.child;
        const x = origin_x +
            gridTrackStartOffset(column_sizes.items, node.style.gap, placement.column_start) +
            child.style.margin.left;
        const y = origin_y +
            gridRowStartOffset(row_sizes.items, node.style.gap, placement.row_start) +
            child.style.margin.top;
        arrangeNode(child, x, y);
    }
}

pub fn translateSubTree(node: anytype, dx: f32, dy: f32) void {
    node.layout_result.x += dx;
    node.layout_result.y += dy;
    for (node.children.items) |child| {
        translateSubTree(child, dx, dy);
    }
}

pub const MediaRenderData = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    uv_min: [2]f32 = .{ 0.0, 0.0 },
    uv_max: [2]f32 = .{ 1.0, 1.0 },
};

pub fn computeMediaFit(
    box_x: f32,
    box_y: f32,
    box_w: f32,
    box_h: f32,
    media_w: f32,
    media_h: f32,
    fit: ObjectFit,
) MediaRenderData {
    if (box_w <= 0.0 or box_h <= 0.0) {
        return .{ .x = box_x, .y = box_y, .w = 0, .h = 0 };
    }

    if (media_w <= 0.0 or media_h <= 0.0) {
        return .{ .x = box_x, .y = box_y, .w = box_w, .h = box_h };
    }

    switch (fit) {
        .fill => {
            return .{
                .x = box_x,
                .y = box_y,
                .w = box_w,
                .h = box_h,
            };
        },
        .contain, .scale_down => {
            const scale_x = box_w / media_w;
            const scale_y = box_h / media_h;
            var scale = @min(scale_x, scale_y);

            if (fit == .scale_down and scale > 1.0) {
                scale = 1.0;
            }

            const target_w = media_w * scale;
            const target_h = media_h * scale;

            return .{
                .x = box_x + (box_w - target_w) / 2.0,
                .y = box_y + (box_h - target_h) / 2.0,
                .w = target_w,
                .h = target_h,
            };
        },
        .cover => {
            const scale_x = box_w / media_w;
            const scale_y = box_h / media_h;
            const scale = @max(scale_x, scale_y);

            const visible_w = box_w / scale;
            const visible_h = box_h / scale;

            const uv_dx = (media_w - visible_w) / 2.0 / media_w;
            const uv_dy = (media_h - visible_h) / 2.0 / media_h;

            return .{
                .x = box_x,
                .y = box_y,
                .w = box_w,
                .h = box_h,
                .uv_min = .{ uv_dx, uv_dy },
                .uv_max = .{ 1.0 - uv_dx, 1.0 - uv_dy },
            };
        },
        .none => {
            return .{
                .x = box_x + (box_w - media_w) / 2.0,
                .y = box_y + (box_h - media_h) / 2.0,
                .w = media_w,
                .h = media_h,
            };
        },
    }
}

const testing = std.testing;
const TestMessage = u32;
const TestNode = Node(TestMessage);

const PanicTextLayouter = struct {
    pub fn measureText(
        _: *PanicTextLayouter,
        _: anytype,
        _: anytype,
        _: []const u8,
        _: f32,
    ) struct { width: f32, height: f32, metrics: []TextLayoutMetric, is_bitmap: bool = false } {
        @panic("PanicTextLayouter.measureText called - layout tests must not use text nodes");
    }
};

const FixedTextLayouter = struct {
    pub fn measureText(
        _: *FixedTextLayouter,
        _: anytype,
        _: anytype,
        text: []const u8,
        _: f32,
    ) struct { width: f32, height: f32, metrics: []TextLayoutMetric, is_bitmap: bool = false } {
        return .{
            .width = @as(f32, @floatFromInt(text.len)) * 8.0,
            .height = 16.0,
            .metrics = &.{},
        };
    }
};

const OptionTrackingTextLayouter = struct {
    last_max_width: f32 = -1.0,
    last_wrap: bool = false,
    last_ellipsis: bool = false,
    last_line_height: f32 = 0.0,

    pub fn measureTextWithOptions(
        self: *OptionTrackingTextLayouter,
        _: anytype,
        _: anytype,
        text: []const u8,
        options: anytype,
    ) struct { width: f32, height: f32, metrics: []TextLayoutMetric, is_bitmap: bool = false } {
        self.last_max_width = options.max_width;
        self.last_wrap = options.wrap;
        self.last_ellipsis = options.ellipsis;
        self.last_line_height = options.line_height;

        const char_w: f32 = 8.0;
        const line_h: f32 = if (options.line_height > 0.0) options.line_height else 16.0;
        const full_width: f32 = @as(f32, @floatFromInt(text.len)) * char_w;

        if (options.wrap and options.max_width > 0.0) {
            const chars_per_line = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(options.max_width / char_w))));
            const lines = @max(@as(usize, 1), (text.len + chars_per_line - 1) / chars_per_line);
            const last_line_chars = if (text.len % chars_per_line == 0) chars_per_line else text.len % chars_per_line;
            const width = @min(options.max_width, @as(f32, @floatFromInt(@max(chars_per_line, last_line_chars))) * char_w);
            return .{
                .width = width,
                .height = @as(f32, @floatFromInt(lines)) * line_h,
                .metrics = &.{},
            };
        }

        if (!options.wrap and options.max_width > 0.0 and !options.ellipsis) {
            return .{
                .width = @min(full_width, options.max_width),
                .height = line_h,
                .metrics = &.{},
            };
        }

        if (!options.wrap and options.max_width > 0.0 and options.ellipsis and full_width > options.max_width) {
            return .{
                .width = options.max_width,
                .height = line_h,
                .metrics = &.{},
            };
        }

        return .{
            .width = full_width,
            .height = line_h,
            .metrics = &.{},
        };
    }
};

fn makeNode(alloc: std.mem.Allocator, style: Style) !*TestNode {
    const node = try alloc.create(TestNode);
    node.* = TestNode.init();
    node.allocator = alloc;
    node.style = style;
    return node;
}

fn fakeFont() *FontData {
    const Dummy = struct {
        var font: FontData = undefined;
    };
    return &Dummy.font;
}

fn makeTextNode(alloc: std.mem.Allocator, style: Style, content: []const u8, max_width: f32) !*TestNode {
    const node = try makeNode(alloc, style);
    node.payload = .{ .text = .{
        .content = try alloc.dupe(u8, content),
        .font = fakeFont(),
        .max_width = max_width,
    } };
    return node;
}

fn makeTextInputNode(alloc: std.mem.Allocator, style: Style, content: []const u8, max_width: f32) !*TestNode {
    const node = try makeNode(alloc, style);
    node.payload = .{ .text_input = .{
        .buffer = std.ArrayList(u8).empty,
        .cursor_index = 0,
        .font = fakeFont(),
        .max_width = max_width,
    } };

    if (content.len > 0) {
        try node.payload.text_input.buffer.appendSlice(alloc, content);
        node.payload.text_input.cursor_index = content.len;
    }

    return node;
}

test "TextDecoration.merge: line bits OR together" {
    const a = TextDecoration{ .line = .{ .underline = true } };
    const b = TextDecoration{ .line = .{ .line_through = true } };
    const out = a.merge(b);
    try testing.expect(out.line.underline);
    try testing.expect(out.line.line_through);
    try testing.expect(!out.line.overline);
}

test "TextDecoration.merge: non-default fields win" {
    const a = TextDecoration{ .line = .{ .underline = true } };
    const b = TextDecoration{
        .shape = .wavy,
        .color = .{ 1, 0, 0, 1 },
        .thickness = 3,
    };
    const out = a.merge(b);
    try testing.expect(out.line.underline);
    try testing.expectEqual(TextDecorationShape.wavy, out.shape);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1 }, &out.color.?);
    try testing.expectApproxEqAbs(@as(f32, 3), out.thickness, 0.001);
}

test "Style.mix: text_decoration deep-merges across partials" {
    const underline_partial = .{ .text_decoration = TextDecoration{ .line = .{ .underline = true } } };
    const wavy_partial = .{ .text_decoration = TextDecoration{ .shape = .wavy } };
    const red_partial = .{ .text_decoration = TextDecoration{ .color = .{ 1, 0, 0, 1 } } };
    const merged = Style.mix(.{ underline_partial, wavy_partial, red_partial });
    try testing.expect(merged.text_decoration.line.underline);
    try testing.expectEqual(TextDecorationShape.wavy, merged.text_decoration.shape);
    try testing.expect(merged.text_decoration.color != null);
}

test "tw.style: text_decoration deep-merges across helpers" {
    // tw.style and Style.mix both need the deep-merge carve-out; this guards
    // the path apps actually take (tw.style flat-overwrote before the fix).
    const tw = @import("tw.zig");
    const a = tw.style(.{ tw.underline, tw.decoration_color_value(.{ 1, 0, 0, 1 }) });
    try testing.expect(a.text_decoration.line.underline);
    try testing.expect(a.text_decoration.color != null);

    const b = tw.style(.{ tw.line_through, tw.decoration_thickness(2.0) });
    try testing.expect(b.text_decoration.line.line_through);
    try testing.expectApproxEqAbs(@as(f32, 2.0), b.text_decoration.thickness, 0.001);

    const c = tw.style(.{ tw.underline, tw.line_through, tw.overline, tw.decoration_color_value(.{ 0.5, 0.5, 0.5, 1 }) });
    try testing.expect(c.text_decoration.line.underline);
    try testing.expect(c.text_decoration.line.line_through);
    try testing.expect(c.text_decoration.line.overline);
}

test "measureNode: single node with exact size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 50 } });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 100), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), node.layout_result.height, 0.01);
}

test "measureNode: screen-sized node fills viewport" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{ .width = .screen, .height = .screen });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 800), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 600), node.layout_result.height, 0.01);
}

test "measureNode: full-sized node fills available constraints" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{ .width = .Full, .height = .Full });
    defer node.deinit();

    measureNode(node, &tl, 640, 360, true);

    try testing.expectApproxEqAbs(@as(f32, 640), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 360), node.layout_result.height, 0.01);
}

test "measureNode: percent-sized node fills percentage of constraints" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{ .width = .{ .percent = 0.4 }, .height = .{ .percent = 0.75 } });
    defer node.deinit();

    measureNode(node, &tl, 500, 200, true);

    try testing.expectApproxEqAbs(@as(f32, 200), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 150), node.layout_result.height, 0.01);
}

test "measureNode: min and max clamp explicit width and height" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{
        .width = .{ .exact = 120 },
        .height = .{ .exact = 140 },
        .min_width = .{ .exact = 80 },
        .max_width = .{ .exact = 100 },
        .min_height = .{ .exact = 90 },
        .max_height = .{ .exact = 110 },
    });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 100), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), node.layout_result.height, 0.01);
}

test "measureNode: auto size respects min and max constraints" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .min_width = .{ .exact = 120 },
        .max_height = .{ .exact = 12 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 20 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 120), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 12), parent.layout_result.height, 0.01);
}

test "measureNode: min greater than max follows CSS min precedence" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{
        .width = .{ .exact = 50 },
        .min_width = .{ .exact = 140 },
        .max_width = .{ .exact = 90 },
    });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 140), node.layout_result.width, 0.01);
}

test "measureNode: display none produces zero size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{
        .display = .none,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
    });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 0), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), node.layout_result.height, 0.01);
}

test "measureNode: block display fills available width" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};
    const node = try makeNode(alloc, .{ .display = .block });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 800), node.layout_result.width, 0.01);
}

test "measureNode: column flex intrinsic size from children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 20 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 80 }, .height = .{ .exact = 30 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 80), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), parent.layout_result.height, 0.01);
}

test "measureNode: row flex intrinsic size from children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 20 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 80 }, .height = .{ .exact = 30 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 140), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), parent.layout_result.height, 0.01);
}

test "measureNode: padding increases intrinsic size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .padding = Spacing.all(10) });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 70), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), parent.layout_result.height, 0.01);
}

test "measureNode: border contributes to intrinsic size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .border = Border.all(5, .{ 1, 1, 1, 1 }) });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 60), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), parent.layout_result.height, 0.01);
}

test "measureNode: asymmetric padding contributes by side" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .padding = .{ .top = 4, .right = 6, .bottom = 8, .left = 10 } });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 66), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 32), parent.layout_result.height, 0.01);
}

test "measureNode: margin included in intrinsic size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 }, .margin = Spacing.all(8) });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 66), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 36), parent.layout_result.height, 0.01);
}

test "measureNode: absolute child excluded from intrinsic size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column });
    defer parent.deinit();

    const flow_child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    const abs_child = try makeNode(alloc, .{
        .position = .absolute,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 200 },
        .top = 0,
        .left = 0,
    });
    try parent.addChild(flow_child);
    try parent.addChild(abs_child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 50), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), parent.layout_result.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), abs_child.layout_result.width, 0.01);
}

test "measureNode: display none child excluded from intrinsic size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column });
    defer parent.deinit();

    const visible = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    const hidden = try makeNode(alloc, .{ .display = .none, .width = .{ .exact = 200 }, .height = .{ .exact = 200 } });
    try parent.addChild(visible);
    try parent.addChild(hidden);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 50), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), parent.layout_result.height, 0.01);
}

test "measureNode: flex_grow distributes remaining space in row" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .width = .{ .exact = 400 } });
    defer parent.deinit();

    const fixed = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 20 } });
    const grow = try makeNode(alloc, .{ .flex_grow = 1, .height = .{ .exact = 20 } });
    try parent.addChild(fixed);
    try parent.addChild(grow);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 300), grow.layout_result.width, 0.01);
}

test "measureNode: flex_grow allocation is clamped by child max width" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .width = .{ .exact = 400 } });
    defer parent.deinit();

    const fixed = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 20 } });
    const grow = try makeNode(alloc, .{ .flex_grow = 1, .max_width = .{ .exact = 180 }, .height = .{ .exact = 20 } });
    try parent.addChild(fixed);
    try parent.addChild(grow);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 180), grow.layout_result.width, 0.01);
}

test "measureNode: full child uses parent content box" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 200 },
        .padding = Spacing.all(10),
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .Full, .height = .Full });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 280), child.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 180), child.layout_result.height, 0.01);
}

test "measureNode: fractional widths split row" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .width = .{ .exact = 300 } });
    defer parent.deinit();

    const a = try makeNode(alloc, .{ .width = Size.fraction(2, 5), .height = .{ .exact = 20 } });
    const b = try makeNode(alloc, .{ .width = Size.fraction(3, 5), .height = .{ .exact = 20 } });
    try parent.addChild(a);
    try parent.addChild(b);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 120), a.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 180), b.layout_result.width, 0.01);
}

test "measureNode: flex_grow splits proportionally" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .width = .{ .exact = 300 } });
    defer parent.deinit();

    const a = try makeNode(alloc, .{ .flex_grow = 1, .height = .{ .exact = 20 } });
    const b = try makeNode(alloc, .{ .flex_grow = 2, .height = .{ .exact = 20 } });
    try parent.addChild(a);
    try parent.addChild(b);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 100), a.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), b.layout_result.width, 0.01);
}

test "measureNode: flex_grow in column distributes height" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const fixed = try makeNode(alloc, .{ .height = .{ .exact = 50 }, .width = .{ .exact = 20 } });
    const grow = try makeNode(alloc, .{ .flex_grow = 1, .width = .{ .exact = 20 } });
    try parent.addChild(fixed);
    try parent.addChild(grow);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 150), grow.layout_result.height, 0.01);
}

test "measureNode: overflow scroll keeps constrained layout and content size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .overflow_y = .scroll });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 180 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 170 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 300, true);

    try testing.expectApproxEqAbs(@as(f32, 100), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), parent.layout_result.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), parent.layout_result.content_width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 350), parent.layout_result.content_height, 0.01);
}

test "measureNode: gap added between row children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .gap = 10 });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 110), parent.layout_result.width, 0.01);
}

test "measureNode: gap added between column children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .gap = 8 });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    const c3 = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 76), parent.layout_result.height, 0.01);
}

test "measureNode: grid columns equal width cells" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .display = .grid,
        .grid_columns = 3,
        .width = .{ .exact = 300 },
    });
    defer parent.deinit();

    for (0..6) |_| {
        const c = try makeNode(alloc, .{ .height = .{ .exact = 40 } });
        try parent.addChild(c);
    }

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 80), parent.layout_result.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), parent.children.items[0].layout_result.width, 0.01);
}

test "measureNode: grid template rows mix fixed and auto tracks" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .display = .grid,
        .width = .{ .exact = 210 },
        .gap = 10,
        .grid_template_columns = GridTemplate.fromSlice(&.{
            .{ .fr = 1.0 },
            .{ .fr = 1.0 },
        }),
        .grid_template_rows = GridTemplate.fromSlice(&.{
            .{ .exact = 30.0 },
            .{ .Auto = {} },
        }),
    });
    defer parent.deinit();

    const c0 = try makeNode(alloc, .{ .height = .{ .exact = 18 } });
    const c1 = try makeNode(alloc, .{
        .height = .{ .exact = 50 },
        .grid_row_start = 2,
    });
    try parent.addChild(c0);
    try parent.addChild(c1);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 90), parent.layout_result.height, 0.01);
}

test "measureNode: grid column span stretches auto-width child across tracks" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .display = .grid,
        .width = .{ .exact = 320 },
        .gap = 10,
        .grid_template_columns = GridTemplate.fromSlice(&.{
            .{ .fr = 1.0 },
            .{ .fr = 1.0 },
            .{ .fr = 1.0 },
        }),
    });
    defer parent.deinit();

    const span_two = try makeNode(alloc, .{
        .height = .{ .exact = 32 },
        .grid_column_span = 2,
    });
    const regular = try makeNode(alloc, .{ .height = .{ .exact = 20 } });
    try parent.addChild(span_two);
    try parent.addChild(regular);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 210), span_two.layout_result.width, 0.01);
}

test "measureNode: nested flex containers" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const root = try makeNode(alloc, .{ .direction = .Row });
    defer root.deinit();

    const col1 = try makeNode(alloc, .{ .direction = .Column });
    const col2 = try makeNode(alloc, .{ .direction = .Column });

    const a = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 20 } });
    const b = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 30 } });
    const c = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 15 } });

    try col1.addChild(a);
    try col1.addChild(b);
    try col2.addChild(c);
    try root.addChild(col1);
    try root.addChild(col2);

    measureNode(root, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 40), col1.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), col1.layout_result.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), root.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), root.layout_result.height, 0.01);
}

test "measureNode: text auto-wrap uses parent content width when max_width is zero" {
    const alloc = testing.allocator;
    var tl = OptionTrackingTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 96 } });
    defer parent.deinit();

    const child = try makeTextNode(alloc, .{}, "abcdefghijklmnopqrst", 0.0);
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expect(tl.last_wrap);
    try testing.expectApproxEqAbs(@as(f32, 96), tl.last_max_width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 96), child.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 32), child.layout_result.height, 0.01);
}

test "measureNode: white_space NoWrap disables implicit parent wrapping" {
    const alloc = testing.allocator;
    var tl = OptionTrackingTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 80 } });
    defer parent.deinit();

    const child = try makeTextNode(alloc, .{ .white_space = .NoWrap }, "abcdefghijklmnopqrst", 0.0);
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expect(!tl.last_wrap);
    try testing.expectApproxEqAbs(@as(f32, 0), tl.last_max_width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 160), child.layout_result.width, 0.01);
}

test "measureNode: text line_height override propagates to measurement" {
    const alloc = testing.allocator;
    var tl = OptionTrackingTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 96 } });
    defer parent.deinit();

    const child = try makeTextNode(alloc, .{ .line_height = 24.0 }, "abcdefghijklmnopqrst", 0.0);
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 24), tl.last_line_height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 48), child.layout_result.height, 0.01);
}

test "measureNode: text_input wraps by default and grows in height" {
    const alloc = testing.allocator;
    var tl = OptionTrackingTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 80 } });
    defer parent.deinit();

    const child = try makeTextInputNode(alloc, .{}, "abcdefghijklmnopqrst", 0.0);
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expect(tl.last_wrap);
    try testing.expect(!tl.last_ellipsis);
    try testing.expectApproxEqAbs(@as(f32, 80), tl.last_max_width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), child.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 32), child.layout_result.height, 0.01);
}

test "measureNode: text_input no-wrap ellipsis auto-constrains to parent width" {
    const alloc = testing.allocator;
    var tl = OptionTrackingTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 80 } });
    defer parent.deinit();

    const child = try makeTextInputNode(alloc, .{
        .white_space = .NoWrap,
        .text_overflow = .Ellipsis,
    }, "abcdefghijklmnopqrst", 0.0);
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expect(!tl.last_wrap);
    try testing.expect(tl.last_ellipsis);
    try testing.expectApproxEqAbs(@as(f32, 80), tl.last_max_width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), child.layout_result.width, 0.01);
}

test "measureNode: flex_wrap row wraps children to new line" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .flex_wrap = .Wrap,
        .gap = 10,
        .width = .{ .exact = 100 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 10 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 10 } });
    const c3 = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 10 } });
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 30), parent.layout_result.height, 0.01);
}

test "measureNode: flex_wrap column wraps children to new column" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .flex_wrap = .Wrap,
        .gap = 10,
        .height = .{ .exact = 100 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 20 }, .height = .{ .exact = 40 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 20 }, .height = .{ .exact = 40 } });
    const c3 = try makeNode(alloc, .{ .width = .{ .exact = 20 }, .height = .{ .exact = 40 } });
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 50), parent.layout_result.width, 0.01);
}

test "arrangeNode: column positions children vertically" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 100 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 60 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 10, 20);

    try testing.expectApproxEqAbs(@as(f32, 10), parent.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), parent.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), c1.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), c2.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), c2.layout_result.y, 0.01); // 20 + 40
}

test "arrangeNode: row positions children horizontally" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .width = .{ .exact = 200 }, .height = .{ .exact = 50 } });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 80 }, .height = .{ .exact = 50 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), c2.layout_result.x, 0.01);
}

test "arrangeNode: flex_wrap row places overflowing children on next line" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .flex_wrap = .Wrap,
        .gap = 10,
        .width = .{ .exact = 100 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 10 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 10 } });
    const c3 = try makeNode(alloc, .{ .width = .{ .exact = 40 }, .height = .{ .exact = 10 } });
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), c2.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), c3.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), c3.layout_result.y, 0.01);
}

test "arrangeNode: flex_wrap column places overflowing children on next column" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .flex_wrap = .Wrap,
        .gap = 10,
        .height = .{ .exact = 100 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 20 }, .height = .{ .exact = 40 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 20 }, .height = .{ .exact = 40 } });
    const c3 = try makeNode(alloc, .{ .width = .{ .exact = 20 }, .height = .{ .exact = 40 } });
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), c2.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), c3.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), c3.layout_result.y, 0.01);
}

test "arrangeNode: two full-width row children overflow like CSS" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .width = .{ .exact = 300 }, .height = .{ .exact = 60 } });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .Full, .height = .Full });
    const c2 = try makeNode(alloc, .{ .width = .Full, .height = .Full });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 300), c1.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), c2.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), c2.layout_result.x, 0.01);
}

test "arrangeNode: padding offsets children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .padding = Spacing.all(15), .width = .{ .exact = 200 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 15), child.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 15), child.layout_result.y, 0.01);
}

test "arrangeNode: border offsets children like CSS" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .border = Border.all(8, .{ 1, 1, 1, 1 }), .width = .{ .exact = 200 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 8), child.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 8), child.layout_result.y, 0.01);
}

test "arrangeNode: absolute positioning uses inset box" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .width = .{ .exact = 400 },
        .height = .{ .exact = 300 },
        .padding = Spacing.all(6),
        .border = Border.all(4, .{ 1, 1, 1, 1 }),
    });
    defer parent.deinit();

    const abs_child = try makeNode(alloc, .{
        .position = .absolute,
        .top = 50,
        .left = 80,
        .width = .{ .exact = 100 },
        .height = .{ .exact = 60 },
    });
    try parent.addChild(abs_child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 10, 20);

    try testing.expectApproxEqAbs(@as(f32, 100), abs_child.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), abs_child.layout_result.y, 0.01);
}

test "arrangeNode: margin offsets child within parent" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 200 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 }, .margin = Spacing.all(12) });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 12), child.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 12), child.layout_result.y, 0.01);
}

test "arrangeNode: asymmetric margin offsets flow start" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 200 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 20 }, .margin = .{ .top = 7, .left = 11 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 11), child.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 7), child.layout_result.y, 0.01);
}

test "arrangeNode: gap separates column children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .gap = 10, .width = .{ .exact = 100 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), c2.layout_result.y, 0.01);
}

test "arrangeNode: scroll offsets translate flow children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .overflow_y = .scroll,
        .width = .{ .exact = 100 },
        .height = .{ .exact = 60 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    parent.scroll_y = 15.0;

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, -15), c1.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 25), c2.layout_result.y, 0.01);
}

test "arrangeNode: gap separates row children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Row, .gap = 12, .width = .{ .exact = 200 }, .height = .{ .exact = 50 } });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 72), c2.layout_result.x, 0.01); // 60 + 12
}

test "arrangeNode: justify_content center in row" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .justify_content = .Center,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 50 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 50 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 100), child.layout_result.x, 0.01);
}

test "arrangeNode: justify_content center in column" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .justify_content = .Center,
        .width = .{ .exact = 100 },
        .height = .{ .exact = 300 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 60 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 120), child.layout_result.y, 0.01);
}

test "arrangeNode: justify_content end in row" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .justify_content = .End,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 50 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 50 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 200), child.layout_result.x, 0.01);
}

test "arrangeNode: justify_content space_between distributes space evenly" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .justify_content = .SpaceBetween,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 50 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    const c3 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 120), c2.layout_result.x, 0.01); // 60 + 60
    try testing.expectApproxEqAbs(@as(f32, 240), c3.layout_result.x, 0.01); // 120 + 60 + 60
}

test "arrangeNode: justify_content space_around" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .justify_content = .SpaceAround,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 50 },
    });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 50 } });
    try parent.addChild(c1);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 45), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 195), c2.layout_result.x, 0.01);
}

test "arrangeNode: align_items center in row" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .align_items = .Center,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 40 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 30), child.layout_result.y, 0.01);
}

test "arrangeNode: align_items center in column" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Column,
        .align_items = .Center,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 60 }, .height = .{ .exact = 40 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 70), child.layout_result.x, 0.01);
}

test "arrangeNode: align_items end in row" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .direction = .Row,
        .align_items = .End,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 40 } });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 60), child.layout_result.y, 0.01);
}

test "arrangeNode: absolute positioning with top/left" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .width = .{ .exact = 400 }, .height = .{ .exact = 300 } });
    defer parent.deinit();

    const abs_child = try makeNode(alloc, .{
        .position = .absolute,
        .top = 50,
        .left = 80,
        .width = .{ .exact = 100 },
        .height = .{ .exact = 60 },
    });
    try parent.addChild(abs_child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 10, 20);

    try testing.expectApproxEqAbs(@as(f32, 90), abs_child.layout_result.x, 0.01); // 10+80
    try testing.expectApproxEqAbs(@as(f32, 70), abs_child.layout_result.y, 0.01); // 20+50
}

test "arrangeNode: absolute positioning with bottom/right" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .width = .{ .exact = 400 }, .height = .{ .exact = 300 } });
    defer parent.deinit();

    const abs_child = try makeNode(alloc, .{
        .position = .absolute,
        .bottom = 20,
        .right = 30,
        .width = .{ .exact = 100 },
        .height = .{ .exact = 60 },
    });
    try parent.addChild(abs_child);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 270), abs_child.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 220), abs_child.layout_result.y, 0.01);
}

test "arrangeNode: absolute child does not displace flow children" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 300 }, .height = .{ .exact = 300 } });
    defer parent.deinit();

    const flow1 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 50 } });
    const flow2 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 50 } });
    const abs = try makeNode(alloc, .{
        .position = .absolute,
        .top = 100,
        .left = 0,
        .width = .{ .exact = 50 },
        .height = .{ .exact = 50 },
    });
    try parent.addChild(flow1);
    try parent.addChild(flow2);
    try parent.addChild(abs);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), flow1.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), flow2.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), abs.layout_result.y, 0.01);
}

test "arrangeNode: grid places children in columns" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .display = .grid,
        .grid_columns = 2,
        .gap = 10,
        .width = .{ .exact = 210 }, // cell_w = (210 - 10) / 2 = 100
        .height = .{ .exact = 200 },
    });
    defer parent.deinit();

    const c0 = try makeNode(alloc, .{ .height = .{ .exact = 50 } });
    const c1 = try makeNode(alloc, .{ .height = .{ .exact = 50 } });
    const c2 = try makeNode(alloc, .{ .height = .{ .exact = 50 } });
    const c3 = try makeNode(alloc, .{ .height = .{ .exact = 50 } });
    try parent.addChild(c0);
    try parent.addChild(c1);
    try parent.addChild(c2);
    try parent.addChild(c3);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c0.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), c1.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), c0.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), c2.layout_result.y, 0.01);
}

test "arrangeNode: grid explicit row and column start place child in target cell" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .display = .grid,
        .grid_columns = 2,
        .gap = 10,
        .width = .{ .exact = 210 },
        .height = .{ .exact = 200 },
    });
    defer parent.deinit();

    const c0 = try makeNode(alloc, .{ .height = .{ .exact = 20 } });
    const explicit = try makeNode(alloc, .{
        .height = .{ .exact = 20 },
        .grid_column_start = 2,
        .grid_row_start = 2,
    });
    const auto = try makeNode(alloc, .{ .height = .{ .exact = 20 } });
    try parent.addChild(c0);
    try parent.addChild(explicit);
    try parent.addChild(auto);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c0.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), auto.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), explicit.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), explicit.layout_result.y, 0.01);
}

test "arrangeNode: grid row span blocks auto-placement cells" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .display = .grid,
        .grid_columns = 2,
        .gap = 10,
        .width = .{ .exact = 210 },
    });
    defer parent.deinit();

    const tall = try makeNode(alloc, .{ .height = .{ .exact = 40 }, .grid_row_span = 2 });
    const top_right = try makeNode(alloc, .{ .height = .{ .exact = 30 } });
    const bottom_right = try makeNode(alloc, .{ .height = .{ .exact = 30 } });
    try parent.addChild(tall);
    try parent.addChild(top_right);
    try parent.addChild(bottom_right);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), tall.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), tall.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), top_right.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), top_right.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 110), bottom_right.layout_result.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), bottom_right.layout_result.y, 0.01);
}

test "arrangeNode: display none children are skipped" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{ .direction = .Column, .width = .{ .exact = 100 }, .height = .{ .exact = 200 } });
    defer parent.deinit();

    const c1 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    const c_hidden = try makeNode(alloc, .{ .display = .none, .width = .{ .exact = 100 }, .height = .{ .exact = 100 } });
    const c2 = try makeNode(alloc, .{ .width = .{ .exact = 100 }, .height = .{ .exact = 40 } });
    try parent.addChild(c1);
    try parent.addChild(c_hidden);
    try parent.addChild(c2);

    measureNode(parent, &tl, 800, 600, true);
    arrangeNode(parent, 0, 0);

    try testing.expectApproxEqAbs(@as(f32, 0), c1.layout_result.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), c2.layout_result.y, 0.01);
}

test "style: default background_color is transparent" {
    const style = Style{};
    try testing.expectEqual(@as(f32, 0), style.background_color[3]);
}

test "style: default opacity is fully opaque" {
    const style = Style{};
    try testing.expectApproxEqAbs(@as(f32, 1.0), style.opacity, 0.0001);
}

test "style: visual properties can be set inline" {
    const s = Style{
        .opacity = 0.35,
        .background_color = .{ 1, 0, 0, 1 },
        .border = Border.all(2, .{ 0, 0, 1, 1 }),
        .corner_radius = CornerRadius.all(8),
        .shadow_color = .{ 0, 0, 0, 0.5 },
        .shadow_offset = .{ 4, 4 },
        .shadow_blur = 6,
        .text_color = .{ 1, 1, 1, 1 },
    };
    try testing.expectApproxEqAbs(@as(f32, 1), s.background_color[3], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2), s.border.top.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 8), s.corner_radius.top_left, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.shadow_color[3], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.35), s.opacity, 0.01);
}

test "box_sizing: border_box (default) - outer == stated size, content shrinks by padding" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const node = try makeNode(alloc, .{
        .box_sizing = .border_box,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
        .padding = Spacing.all(20),
    });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 200), node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), node.layout_result.height, 0.01);
}

test "box_sizing: border_box default matches explicit .border_box" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const a = try makeNode(alloc, .{
        .width = .{ .exact = 160 },
        .height = .{ .exact = 80 },
        .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
    });
    defer a.deinit();

    const b_node = try makeNode(alloc, .{
        .box_sizing = .border_box,
        .width = .{ .exact = 160 },
        .height = .{ .exact = 80 },
        .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
    });
    defer b_node.deinit();

    measureNode(a, &tl, 800, 600, true);
    measureNode(b_node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(a.layout_result.width, b_node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(a.layout_result.height, b_node.layout_result.height, 0.01);
}

test "box_sizing: content_box - outer grows by padding, children get full stated size" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .box_sizing = .content_box,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
        .padding = Spacing.all(20),
        .direction = .Column,
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{
        .width = .Full,
        .height = .{ .exact = 30 },
    });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 240), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 140), parent.layout_result.height, 0.01);

    try testing.expectApproxEqAbs(@as(f32, 200), child.layout_result.width, 0.01);
}

test "box_sizing: content_box vs border_box with same padding produce different outer sizes" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const border = try makeNode(alloc, .{
        .box_sizing = .border_box,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
        .padding = Spacing.all(20),
    });
    defer border.deinit();

    const content = try makeNode(alloc, .{
        .box_sizing = .content_box,
        .width = .{ .exact = 200 },
        .height = .{ .exact = 100 },
        .padding = Spacing.all(20),
    });
    defer content.deinit();

    measureNode(border, &tl, 800, 600, true);
    measureNode(content, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 200), border.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 240), content.layout_result.width, 0.01);

    try testing.expectApproxEqAbs(@as(f32, 100), border.layout_result.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 140), content.layout_result.height, 0.01);
}

test "box_sizing: content_box respects min/max bounds on the outer box" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const node = try makeNode(alloc, .{
        .box_sizing = .content_box,
        .width = .{ .exact = 80 },
        .padding = Spacing.all(20),
        .max_width = .{ .exact = 100 },
    });
    defer node.deinit();

    measureNode(node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 100), node.layout_result.width, 0.01);
}

test "box_sizing: content_box auto width behaves identically to border_box auto width" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const border_node = try makeNode(alloc, .{
        .box_sizing = .border_box,
        .direction = .Column,
        .padding = Spacing.all(10),
    });
    defer border_node.deinit();
    const bc = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 30 } });
    try border_node.addChild(bc);

    const content_node = try makeNode(alloc, .{
        .box_sizing = .content_box,
        .direction = .Column,
        .padding = Spacing.all(10),
    });
    defer content_node.deinit();
    const cc = try makeNode(alloc, .{ .width = .{ .exact = 50 }, .height = .{ .exact = 30 } });
    try content_node.addChild(cc);

    measureNode(border_node, &tl, 800, 600, true);
    measureNode(content_node, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(border_node.layout_result.width, content_node.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(border_node.layout_result.height, content_node.layout_result.height, 0.01);
}

test "box_sizing: content_box with flex-grow child fills stated content width" {
    const alloc = testing.allocator;
    var tl = PanicTextLayouter{};

    const parent = try makeNode(alloc, .{
        .box_sizing = .content_box,
        .direction = .Row,
        .width = .{ .exact = 300 },
        .height = .{ .exact = 60 },
        .padding = Spacing.all(20),
    });
    defer parent.deinit();

    const child = try makeNode(alloc, .{ .flex_grow = 1 });
    try parent.addChild(child);

    measureNode(parent, &tl, 800, 600, true);

    try testing.expectApproxEqAbs(@as(f32, 340), parent.layout_result.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), child.layout_result.width, 0.01);
}
