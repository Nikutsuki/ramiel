const std = @import("std");
const batcher_mod = @import("../renderer/vulkan/batcher.zig");
const QuadBatcher = batcher_mod.QuadBatcher;
const RoundedRectStyle = batcher_mod.RoundedRectStyle;
const packColor = batcher_mod.packColor;
const Border = @import("layout.zig").Border;
const msdfWeightFor = @import("layout.zig").msdfWeightFor;
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const TextLayouter = @import("../renderer/font/text_layouter.zig").TextLayouter;
const Style = @import("layout.zig").Style;
const LayoutResult = @import("layout.zig").LayoutResult;
const TextLayoutMetric = @import("layout.zig").TextLayoutMetric;
const NodeId = @import("types.zig").NodeId;
const assets = @import("../assets.zig");
const EasingFunction = @import("../animation/easing.zig").EasingFunction;
const AnimatedState = @import("../renderer/image_animation.zig").AnimatedState;
const Canvas = @import("../renderer/canvas.zig").Canvas;
const VideoPlayback = @import("../video/playback.zig").VideoPlayback;
const paint_context_mod = @import("paint_context.zig");
const PaintContext = paint_context_mod.PaintContext;
const types = @import("types.zig");
const EventType = types.EventType;
const EventBinding = types.EventBinding;
const computeMediaFit = @import("layout.zig").computeMediaFit;
const layout_mod = @import("layout.zig");

pub const HoverAnim = struct {
    start_time: f64,
    from: f32,
    to: f32,
    duration: f64,
    timing: EasingFunction,
};

pub const RichTextSpanMask = packed struct {
    text_color: bool = false,
    background_color: bool = false,
    text_decoration: bool = false,
};

pub const RichTextSpan = struct {
    start: usize,
    end: usize,
    style: Style = .{},
    mask: RichTextSpanMask = .{},
};

pub const RenderPayload = union(enum) {
    pub const ImageFallbackState = enum { missing, decoding, ready };
    none,
    fragment,
    container,
    portal,
    text: struct {
        content: []u8,
        font: *FontData,
        max_width: f32,
    },
    image: struct {
        tex_id: u32,
        tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        intrinsic_size: [2]f32 = .{ 0.0, 0.0 },
        custom_params: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        alt_text: []u8 = &.{},
        alt_font: ?*FontData = null,
        fallback_state: ImageFallbackState = .ready,
        animation: ?*const AnimatedState = null,
        start_time: f64 = 0.0,
    },
    canvas: struct {
        target: *Canvas,
        tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        custom_params: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        pan_x: f32 = 0.0,
        pan_y: f32 = 0.0,
        zoom: f32 = 1.0,
    },
    text_input: struct {
        buffer: std.ArrayList(u8),
        cursor_index: usize,
        selection_anchor: ?usize = null,
        font: *FontData,
        max_width: f32 = 0.0,
        /// Rendered when buffer is empty. Contributes to layout (so the box keeps
        /// its intrinsic height) and rendered in `placeholder_color`.
        placeholder: []const u8 = "",
        placeholder_color: ?layout_mod.Color = null,
    },
    text_area: struct {
        buffer: std.ArrayList(u8),
        cursor_index: usize,
        selection_anchor: ?usize = null,
        font: *FontData,
        max_width: f32 = 0.0,
        scroll_y: f32 = 0.0,
        target_nav_x: f32 = 0.0,
    },
    video: struct {
        playback: *const VideoPlayback,
        tint: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        custom_params: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    },
    rich_text: struct {
        content: []u8,
        font: *FontData,
        max_width: f32,
        spans: []RichTextSpan = &.{},
    },

    custom_paint: struct {
        paint_fn: paint_context_mod.PaintFn,
        userdata: ?*const anyopaque = null,
        revision: u64 = 0,
    },
};

pub const TextSelection = struct {
    anchor: usize,
    focus: usize,
};

pub const HitTestKind = enum(u8) { none, glyphs, atomic };

pub const InvalidationState = packed struct {
    position: bool = true,
    size: bool = true,
    content: bool = true,

    pub fn any(self: InvalidationState) bool {
        return self.position or self.size or self.content;
    }
};

pub fn Node(comptime MessageT: type) type {
    return struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
        width: f32 = 0.0,
        height: f32 = 0.0,

        clip_children: bool = false,
        scroll_x: f32 = 0.0,
        scroll_y: f32 = 0.0,

        prev_desc_scroll_x: f32 = 0.0,
        prev_desc_scroll_y: f32 = 0.0,

        style: Style = .{},
        layout_result: LayoutResult = .{},
        payload: RenderPayload = .none,
        id: ?NodeId = null,

        child_memo_key: u64 = 0,

        allocator: std.mem.Allocator = undefined,
        parent: ?*Node(MessageT) = null,
        children: std.ArrayList(*Node(MessageT)),

        flags: InvalidationState = .{},

        is_focusable: bool = false,
        is_focused: bool = false,
        is_hovered: bool = false,
        lock_pointer_on_drag: bool = false,
        /// Marks this node as a custom input widget that owns its own
        /// keyboard/text handling. When the focused node has this flag set,
        /// the framework skips default Tab focus-traversal and the
        /// tree-walking Ctrl+C / Ctrl+A clipboard path. When set on any
        /// ancestor of a click target, the framework also skips initiating
        /// its visual text selection on `.text` payloads in the subtree —
        /// so the widget can drive its own selection model from raw
        /// pointer events.
        claims_input: bool = false,

        hover_anim: ?HoverAnim = null,

        text_selection: ?TextSelection = null,

        hit_byte_start: u32 = 0,
        hit_byte_end: u32 = 0,
        hit_test_kind: HitTestKind = .none,

        events: []const EventBinding(MessageT) = &.{},

        pub const ScrollbarThumbRect = struct {
            x: f32,
            y: f32,
            width: f32,
            height: f32,
            max_scroll: f32,
            track_height: f32,
        };

        pub const TransformedRect = struct {
            x: f32,
            y: f32,
            width: f32,
            height: f32,
            local_scale: f32,
        };

        pub fn init() @This() {
            return .{
                .children = std.ArrayList(*@This()).empty,
            };
        }

        pub fn getEventMessage(self: *const Node(MessageT), event_type: EventType) ?MessageT {
            for (self.events) |binding| {
                if (binding.event == event_type) {
                    if (binding.msg) |m| return m;
                }
            }
            return null;
        }

        pub fn hasEventBinding(self: *const Node(MessageT), event_type: EventType) bool {
            for (self.events) |binding| {
                if (binding.event == event_type) {
                    if (binding.msg != null) return true;
                    if (binding.handler != null) return true;
                }
            }
            return false;
        }

        pub fn tickHoverAnims(self: *@This(), current_time: f64) bool {
            var any_active = false;
            if (self.hover_anim) |anim| {
                const elapsed = current_time - anim.start_time;
                if (anim.duration <= 0.0 or elapsed >= anim.duration) {
                    self.style._hover_blend = anim.to;
                    self.hover_anim = null;
                } else {
                    const raw: f32 = @floatCast(elapsed / anim.duration);
                    const t = anim.timing.apply(raw);
                    self.style._hover_blend = anim.from + (anim.to - anim.from) * t;
                    any_active = true;
                }
            }
            for (self.children.items) |child| {
                if (child.tickHoverAnims(current_time)) any_active = true;
            }
            return any_active;
        }

        pub fn freeOwn(self: *@This()) void {
            self.layout_result.text_cache.clear(self.allocator);

            if (self.events.len > 0) {
                freeEventPayloads(MessageT, self.allocator, self.events);
                self.allocator.free(self.events);
            }

            switch (self.payload) {
                .text => |t| self.allocator.free(t.content),
                .image => |img| self.allocator.free(img.alt_text),
                .text_input => |*ti| ti.buffer.deinit(self.allocator),
                .text_area => |*ta| ta.buffer.deinit(self.allocator),
                .rich_text => |rt| {
                    self.allocator.free(rt.content);
                    self.allocator.free(rt.spans);
                },
                else => {},
            }
        }

        pub fn deinit(self: *@This()) void {
            for (self.children.items) |child| {
                child.deinit();
            }
            self.freeOwn();
            self.children.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn addChild(self: *@This(), child: *Node(MessageT)) !void {
            if (child.payload == .fragment) {
                for (child.children.items) |grandchild| {
                    grandchild.parent = self;
                    try self.children.append(self.allocator, grandchild);
                }
                child.children.clearRetainingCapacity();
                child.children.deinit(child.allocator);
                child.layout_result.text_cache.clear(child.allocator);
                child.allocator.destroy(child);
                return;
            }

            child.parent = self;
            try self.children.append(self.allocator, child);
        }

        pub fn clipsChildren(self: *const @This()) bool {
            return self.clip_children or
                self.style.overflow_x != .visible or
                self.style.overflow_y != .visible;
        }

        const RenderTransform = struct { scale: f32, tx: f32, ty: f32 };

        fn resolveRenderTransform(self: *const @This()) RenderTransform {
            const parent = if (self.parent) |p|
                p.resolveRenderTransform()
            else
                RenderTransform{ .scale = 1.0, .tx = 0.0, .ty = 0.0 };

            const tr = self.style.transform;
            const f = clampScale(tr.scale);
            const raw_x = self.layout_result.x;
            const raw_y = self.layout_result.y;
            const cx = raw_x + self.layout_result.width * 0.5;
            const cy = raw_y + self.layout_result.height * 0.5;

            return .{
                .scale = parent.scale * f,
                .tx = parent.scale * (cx * (1.0 - f) + tr.translate[0]) + parent.tx,
                .ty = parent.scale * (cy * (1.0 - f) + tr.translate[1]) + parent.ty,
            };
        }

        pub fn getTransformedRect(self: *const @This()) TransformedRect {
            const t = self.resolveRenderTransform();
            const raw_x = self.layout_result.x;
            const raw_y = self.layout_result.y;
            const raw_w = self.layout_result.width;
            const raw_h = self.layout_result.height;

            const exact_x = t.scale * raw_x + t.tx;
            const exact_y = t.scale * raw_y + t.ty;
            const exact_w = raw_w * t.scale;
            const exact_h = raw_h * t.scale;

            const abs_x = @round(exact_x);
            const abs_y = @round(exact_y);

            return .{
                .x = abs_x,
                .y = abs_y,
                .width = @round(exact_x + exact_w) - abs_x,
                .height = @round(exact_y + exact_h) - abs_y,
                .local_scale = t.scale,
            };
        }

        pub fn getVerticalScrollbarThumbRect(self: *const @This()) ?ScrollbarThumbRect {
            if (self.style.overflow_y != .scroll) return null;

            const transformed = self.getTransformedRect();
            if (transformed.local_scale <= 0.0 or transformed.width <= 0.0 or transformed.height <= 0.0) return null;

            const content_h = self.layout_result.content_height;
            const view_h = self.layout_result.height;
            if (content_h <= view_h or view_h <= 0.0) return null;

            const thumb_w = @max(0.0, self.style.scrollbar_width * transformed.local_scale);
            if (thumb_w <= 0.0) return null;

            const min_thumb_h = @max(1.0, self.style.scrollbar_min_height * transformed.local_scale);
            const visible_ratio = view_h / content_h;
            const thumb_h = @min(transformed.height, @max(min_thumb_h, transformed.height * visible_ratio));

            const max_scroll = @max(0.0, content_h - view_h);
            if (max_scroll <= 0.0) return null;

            const track_height = @max(0.0, transformed.height - thumb_h);
            const scroll_ratio = std.math.clamp(self.scroll_y / max_scroll, 0.0, 1.0);
            const thumb_y = transformed.y + track_height * scroll_ratio;

            const thumb_x = transformed.x + transformed.width - thumb_w;

            return .{
                .x = thumb_x,
                .y = thumb_y,
                .width = thumb_w,
                .height = thumb_h,
                .max_scroll = max_scroll,
                .track_height = track_height,
            };
        }

        pub fn getHorizontalScrollbarThumbRect(self: *const @This()) ?ScrollbarThumbRect {
            if (self.style.overflow_x != .scroll) return null;

            const transformed = self.getTransformedRect();
            if (transformed.local_scale <= 0.0 or transformed.width <= 0.0 or transformed.height <= 0.0) return null;

            const content_w = self.layout_result.content_width;
            const view_w = self.layout_result.width;
            if (content_w <= view_w or view_w <= 0.0) return null;

            const thumb_h = @max(0.0, self.style.scrollbar_width * transformed.local_scale);
            if (thumb_h <= 0.0) return null;

            const min_thumb_w = @max(1.0, self.style.scrollbar_min_height * transformed.local_scale);
            const visible_ratio = view_w / content_w;
            const thumb_w = @min(transformed.width, @max(min_thumb_w, transformed.width * visible_ratio));

            const max_scroll = @max(0.0, content_w - view_w);
            if (max_scroll <= 0.0) return null;

            const track_width = @max(0.0, transformed.width - thumb_w);
            const scroll_ratio = std.math.clamp(self.scroll_x / max_scroll, 0.0, 1.0);
            const thumb_x = transformed.x + track_width * scroll_ratio;

            const thumb_y = transformed.y + transformed.height - thumb_h;

            return .{
                .x = thumb_x,
                .y = thumb_y,
                .width = thumb_w,
                .height = thumb_h,
                .max_scroll = max_scroll,
                .track_height = track_width, // Repurposed conceptually as track_width
            };
        }

        fn clampOpacity(opacity: f32) f32 {
            return std.math.clamp(opacity, 0.0, 1.0);
        }

        fn clampScale(scale: f32) f32 {
            return @max(scale, 0.00);
        }

        fn colorWithOpacity(color: anytype, opacity: f32) [4]f32 {
            const c = if (@TypeOf(color) == layout_mod.Color) color.toArray() else color;
            return .{ c[0], c[1], c[2], std.math.clamp(c[3] * opacity, 0.0, 1.0) };
        }

        fn emitTextDecorations(
            batcher: *QuadBatcher,
            metrics: []const TextLayoutMetric,
            font: *const FontData,
            style: *const Style,
            abs_x: f32,
            abs_y: f32,
            base_color: layout_mod.Color,
            opacity: f32,
            scale: f32,
        ) !void {
            const decoration = style.text_decoration;
            if (!decoration.line.hasAny()) return;
            if (metrics.len == 0) return;

            const font_scale: f32 = if (style.font_size > 0.0)
                style.font_size / font.base_size
            else
                1.0;
            const thickness_px: f32 = if (decoration.thickness > 0)
                decoration.thickness
            else
                @max(1.0, font.underline_thickness * font_scale);
            const ascender_scaled = font.ascender * font_scale;
            const underline_dy = -font.underline_position * font_scale + decoration.offset;
            const strike_dy = font.strikethrough_position * font_scale + decoration.offset;
            // + thickness_px keeps the overline below the cap line instead of
            // half-clipping above the text node.
            const overline_dy = -ascender_scaled + thickness_px + decoration.offset;

            const deco_color = colorWithOpacity(decoration.color orelse base_color, opacity);

            var line_start: usize = 0;
            var idx: usize = 1;
            while (idx <= metrics.len) : (idx += 1) {
                const end_of_line = idx == metrics.len or metrics[idx].y != metrics[line_start].y;
                if (!end_of_line) continue;

                const slice = metrics[line_start..idx];
                if (slice.len == 0) {
                    line_start = idx;
                    continue;
                }

                const first = slice[0];
                const last = slice[slice.len - 1];
                const left = first.x;
                const right = last.x + last.width;
                const width = right - left;
                if (width <= 0) {
                    line_start = idx;
                    continue;
                }
                const baseline_y = first.y + ascender_scaled;

                if (decoration.line.underline) {
                    emitOneDecorationLine(batcher, abs_x + left * scale, abs_y + (baseline_y + underline_dy) * scale, width * scale, thickness_px * scale, deco_color, decoration.shape) catch |err| return err;
                }
                if (decoration.line.line_through) {
                    emitOneDecorationLine(batcher, abs_x + left * scale, abs_y + (baseline_y + strike_dy) * scale, width * scale, thickness_px * scale, deco_color, decoration.shape) catch |err| return err;
                }
                if (decoration.line.overline) {
                    emitOneDecorationLine(batcher, abs_x + left * scale, abs_y + (baseline_y + overline_dy) * scale, width * scale, thickness_px * scale, deco_color, decoration.shape) catch |err| return err;
                }

                line_start = idx;
            }
        }

        /// Solid/double rects pixel-snap; otherwise a thin line straddles two
        /// rows of AA and ~halves its coverage on each, vanishing visually.
        fn emitOneDecorationLine(
            batcher: *QuadBatcher,
            x: f32,
            center_y: f32,
            width: f32,
            thickness: f32,
            color: [4]f32,
            shape: @import("layout.zig").TextDecorationShape,
        ) !void {
            switch (shape) {
                .solid => {
                    const t = @max(@round(thickness), 1.0);
                    const y0 = @round(center_y - t * 0.5);
                    try batcher.addRect(x, y0, width, t, color, 0, 0, .{ 0, 0, 0, 0 });
                },
                .double => {
                    const t = @max(@round(thickness), 1.0);
                    const y_upper = @round(center_y - t * 1.5);
                    const y_lower = @round(center_y + t * 0.5);
                    try batcher.addRect(x, y_upper, width, t, color, 0, 0, .{ 0, 0, 0, 0 });
                    try batcher.addRect(x, y_lower, width, t, color, 0, 0, .{ 0, 0, 0, 0 });
                },
                .wavy => {
                    // Patterned shapes need ~1.5px to survive AA at body sizes.
                    const t = @max(thickness, 1.5);
                    const period = @max(t * 4.0, 6.0);
                    const amp = @max(t * 1.2, 2.0);
                    const quad_h = (amp + t) * 2.0;
                    try batcher.addDecorationLine(
                        x,
                        center_y - quad_h * 0.5,
                        width,
                        quad_h,
                        color,
                        batcher_mod.DECORATION_MODE_WAVY,
                        period,
                        amp,
                        t,
                    );
                },
                .dotted => {
                    const t = @max(thickness, 1.5);
                    const period = @max(t * 2.4, 4.0);
                    const quad_h = t * 2.0;
                    try batcher.addDecorationLine(
                        x,
                        center_y - quad_h * 0.5,
                        width,
                        quad_h,
                        color,
                        batcher_mod.DECORATION_MODE_DOTTED,
                        period,
                        0.0,
                        t,
                    );
                },
                .dashed => {
                    const t = @max(thickness, 1.5);
                    const period = @max(t * 5.0, 8.0);
                    const quad_h = t * 2.0;
                    try batcher.addDecorationLine(
                        x,
                        center_y - quad_h * 0.5,
                        width,
                        quad_h,
                        color,
                        batcher_mod.DECORATION_MODE_DASHED,
                        period,
                        0.0,
                        t,
                    );
                },
            }
        }

        /// Used as the placeholder color when no explicit `placeholder_color` is
        /// set on the input. Half-alpha of the active text color.
        fn mutedFallback(color: layout_mod.Color) layout_mod.Color {
            return color.scaleAlpha(0.45);
        }

        fn snapPixel(value: f32) f32 {
            return @round(value);
        }

        fn snapSize(origin: f32, size: f32) f32 {
            return @max(1.0, @round(origin + size) - @round(origin));
        }

        pub fn render(
            self: *const @This(),
            batcher: *QuadBatcher,
            text_layouter: *TextLayouter,
            time: f32,
        ) !void {
            try self.renderWithOpacity(batcher, text_layouter, time, 1.0, 1.0, 0.0, 0.0, 0, false);
        }

        pub fn renderPortal(
            self: *const @This(),
            batcher: *QuadBatcher,
            text_layouter: *TextLayouter,
            time: f32,
        ) !void {
            try self.renderWithOpacity(batcher, text_layouter, time, 1.0, 1.0, 0.0, 0.0, 0, true);
        }

        fn renderWithOpacity(
            self: *const @This(),
            batcher: *QuadBatcher,
            text_layouter: *TextLayouter,
            time: f32,
            parent_opacity: f32,
            parent_scale: f32,
            parent_dx: f32,
            parent_dy: f32,
            parent_z: @TypeOf(self.style.z_index),
            is_portal_pass: bool,
        ) !void {
            if (self.style.display == .none) return;
            if (self.payload == .portal and !is_portal_pass) return;

            const zoom_saved = layout_mod.active_zoom;
            if (self.style.zoom_override) |z| layout_mod.active_zoom = z;
            defer layout_mod.active_zoom = zoom_saved;

            const tr = self.style.transform;
            const raw_x = self.layout_result.x;
            const raw_y = self.layout_result.y;
            const raw_w = self.layout_result.width;
            const raw_h = self.layout_result.height;

            const f = clampScale(tr.scale);
            const self_scale = parent_scale * f;

            const cx = raw_x + raw_w * 0.5;
            const cy = raw_y + raw_h * 0.5;

            const self_tx = parent_scale * (cx * (1.0 - f) + tr.translate[0]) + parent_dx;
            const self_ty = parent_scale * (cy * (1.0 - f) + tr.translate[1]) + parent_dy;

            const exact_x = self_scale * raw_x + self_tx;
            const exact_y = self_scale * raw_y + self_ty;
            const exact_w = raw_w * self_scale;
            const exact_h = raw_h * self_scale;

            const abs_x = @round(exact_x);
            const abs_y = @round(exact_y);
            const w = @round(exact_x + exact_w) - abs_x;
            const h = @round(exact_y + exact_h) - abs_y;

            const active_scissor = batcher.current_scissor;
            const clip_min_x: f32 = @floatFromInt(active_scissor.offset.x);
            const clip_min_y: f32 = @floatFromInt(active_scissor.offset.y);
            const clip_max_x: f32 = clip_min_x + @as(f32, @floatFromInt(active_scissor.extent.width));
            const clip_max_y: f32 = clip_min_y + @as(f32, @floatFromInt(active_scissor.extent.height));

            const margin: f32 = 128.0;
            const is_node_offscreen =
                (abs_x + w < clip_min_x - margin) or
                (abs_x > clip_max_x + margin) or
                (abs_y + h < clip_min_y - margin) or
                (abs_y > clip_max_y + margin);

            if (is_node_offscreen) return;

            const combined_opacity = clampOpacity(parent_opacity) * clampOpacity(self.style.opacity);
            if (combined_opacity <= 0.001) return;

            const rotation = tr.rotate;

            const effective_z = parent_z + self.style.z_index;

            try batcher.setZIndex(effective_z);

            const shadow_color = colorWithOpacity(self.style.shadow_color, combined_opacity);
            if (shadow_color[3] > 0) {
                const blur = self.style.shadow_blur;
                try batcher.addRoundedRect(
                    abs_x + self.style.shadow_offset[0] - blur,
                    abs_y + self.style.shadow_offset[1] - blur,
                    w + blur * 2.0,
                    h + blur * 2.0,
                    shadow_color,
                    .{
                        .radii = self.style.corner_radius.toArray(),
                        .softness = @max(blur, self.style.corner_softness),
                    },
                    rotation,
                );
            }

            const bg_base: layout_mod.Color = if (self.style.hover_color) |hc| blk: {
                const t = std.math.clamp(self.style._hover_blend, 0.0, 1.0);
                break :blk layout_mod.Color.lerp(self.style.background_color, hc, t);
            } else self.style.background_color;
            const bg = colorWithOpacity(bg_base, combined_opacity);

            const backdrop_blur = @max(0.0, self.style.backdrop_blur);
            const element_blur = @max(0.0, self.style.blur);
            const noise = @max(0.0, self.style.noise);

            const has_any_visual =
                bg[3] > 0 or
                backdrop_blur > 0 or
                element_blur > 0 or
                noise > 0 or
                self.style.border.hasAny() or
                self.style.outline.hasAny() or
                self.style.corner_radius.hasAny();

            if (has_any_visual) {
                const bdr = self.style.border;
                const otl = self.style.outline;

                const can_skip_sdf = !self.style.corner_radius.hasAny() and
                    !otl.hasAny() and
                    backdrop_blur == 0.0 and
                    element_blur == 0.0 and
                    noise == 0.0 and
                    rotation == 0.0;

                if (can_skip_sdf) {
                    if (bg[3] > 0) try batcher.addRect(abs_x, abs_y, w, h, bg, 0, 0, .{ 0, 0, 0, 0 });
                    if (bdr.hasAny()) {
                        const wt = @max(0.0, bdr.top.width);
                        const wr = @max(0.0, bdr.right.width);
                        const wb = @max(0.0, bdr.bottom.width);
                        const wl = @max(0.0, bdr.left.width);
                        const ct = colorWithOpacity(bdr.top.color, combined_opacity);
                        const cr = colorWithOpacity(bdr.right.color, combined_opacity);
                        const cb = colorWithOpacity(bdr.bottom.color, combined_opacity);
                        const cl = colorWithOpacity(bdr.left.color, combined_opacity);
                        if (wt > 0 and ct[3] > 0) try batcher.addRect(abs_x, abs_y, w, wt, ct, 0, 0, .{ 0, 0, 0, 0 });
                        if (wb > 0 and cb[3] > 0) try batcher.addRect(abs_x, abs_y + h - wb, w, wb, cb, 0, 0, .{ 0, 0, 0, 0 });
                        if (wl > 0 and cl[3] > 0) try batcher.addRect(abs_x, abs_y, wl, h, cl, 0, 0, .{ 0, 0, 0, 0 });
                        if (wr > 0 and cr[3] > 0) try batcher.addRect(abs_x + w - wr, abs_y, wr, h, cr, 0, 0, .{ 0, 0, 0, 0 });
                    }
                } else {
                    const bdr_top = colorWithOpacity(bdr.top.color, combined_opacity);
                    const bdr_right = colorWithOpacity(bdr.right.color, combined_opacity);
                    const bdr_bottom = colorWithOpacity(bdr.bottom.color, combined_opacity);
                    const bdr_left = colorWithOpacity(bdr.left.color, combined_opacity);

                    const otl_top = colorWithOpacity(otl.top.color, combined_opacity);
                    const otl_right = colorWithOpacity(otl.right.color, combined_opacity);
                    const otl_bottom = colorWithOpacity(otl.bottom.color, combined_opacity);
                    const otl_left = colorWithOpacity(otl.left.color, combined_opacity);

                    try batcher.addRoundedRect(
                        abs_x,
                        abs_y,
                        w,
                        h,
                        bg,
                        .{
                            .radii = self.style.corner_radius.toArray(),
                            .softness = self.style.corner_softness,
                            .border_widths = bdr.widths(),
                            .border_colors = .{
                                packColor(bdr_top),
                                packColor(bdr_right),
                                packColor(bdr_bottom),
                                packColor(bdr_left),
                            },
                            .outline_widths = otl.widths(),
                            .outline_colors = .{
                                packColor(otl_top),
                                packColor(otl_right),
                                packColor(otl_bottom),
                                packColor(otl_left),
                            },
                            .backdrop_blur = backdrop_blur,
                            .element_blur = element_blur,
                            .noise = noise,
                        },
                        rotation,
                    );
                }
            }

            switch (self.payload) {
                .container, .none, .fragment, .portal => {},

                .text => {
                    const sc = batcher.current_scissor;
                    const view_min_x: f32 = @floatFromInt(sc.offset.x);
                    const view_min_y: f32 = @floatFromInt(sc.offset.y);
                    const view_max_x: f32 = @floatFromInt(sc.offset.x + @as(i32, @intCast(sc.extent.width)));
                    const view_max_y: f32 = @floatFromInt(sc.offset.y + @as(i32, @intCast(sc.extent.height)));

                    const node_max_x = abs_x + w;
                    const node_max_y = abs_y + h;
                    const is_offscreen = node_max_x <= view_min_x or abs_x >= view_max_x or
                        node_max_y <= view_min_y or abs_y >= view_max_y;

                    if (!is_offscreen) {
                        const cache = self.layout_result.text_cache;
                        const selection_color = colorWithOpacity(.{ 0.2, 0.4, 0.8, 0.5 }, combined_opacity);
                        const text_color = colorWithOpacity(self.style.text_color, combined_opacity);
                        const text_weight = msdfWeightFor(self.style.font_weight);

                        if (self.text_selection) |sel| {
                            const start = @min(sel.anchor, sel.focus);
                            const end = @max(sel.anchor, sel.focus);
                            if (start != end) {
                                for (cache.metrics) |m| {
                                    if (m.byte_offset >= start and m.byte_offset < end) {
                                        try batcher.addRect(
                                            abs_x + m.x * self_scale,
                                            abs_y + m.y * self_scale,
                                            m.width * self_scale,
                                            m.height * self_scale,
                                            selection_color,
                                            0,
                                            0,
                                            .{ 0.0, 0.0, 0.0, 0.0 },
                                        );
                                    }
                                }
                            }
                        }

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = abs_x + m.render_x * self_scale;
                            const glyph_y = abs_y + m.render_y * self_scale;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w * self_scale),
                                snapSize(glyph_y, m.render_h * self_scale),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }

                        try emitTextDecorations(
                            batcher,
                            cache.metrics,
                            self.payload.text.font,
                            &self.style,
                            abs_x,
                            abs_y,
                            self.style.text_color,
                            combined_opacity,
                            self_scale,
                        );
                    }
                },

                .rich_text => |rt| {
                    const sc = batcher.current_scissor;
                    const view_min_x: f32 = @floatFromInt(sc.offset.x);
                    const view_min_y: f32 = @floatFromInt(sc.offset.y);
                    const view_max_x: f32 = @floatFromInt(sc.offset.x + @as(i32, @intCast(sc.extent.width)));
                    const view_max_y: f32 = @floatFromInt(sc.offset.y + @as(i32, @intCast(sc.extent.height)));
                    const node_max_x = abs_x + w;
                    const node_max_y = abs_y + h;
                    const is_offscreen = node_max_x <= view_min_x or abs_x >= view_max_x or
                        node_max_y <= view_min_y or abs_y >= view_max_y;

                    if (!is_offscreen) {
                        const cache = self.layout_result.text_cache;
                        const selection_color = colorWithOpacity(.{ 0.2, 0.4, 0.8, 0.5 }, combined_opacity);
                        for (rt.spans) |span| {
                            if (!span.mask.background_color) continue;
                            const color = colorWithOpacity(span.style.background_color, combined_opacity);

                            for (cache.metrics) |m| {
                                if (!m.is_visible or !metricIntersectsSpan(m, span)) continue;
                                try batcher.addRect(abs_x + m.x * self_scale, abs_y + m.y * self_scale, m.width * self_scale, m.height * self_scale, color, 0, 0, .{ 0, 0, 0, 0 });
                            }
                        }

                        if (self.text_selection) |sel| {
                            const start = @min(sel.anchor, sel.focus);
                            const end = @max(sel.anchor, sel.focus);
                            if (start != end) {
                                for (cache.metrics) |m| {
                                    if (m.byte_offset >= start and m.byte_offset < end) {
                                        try batcher.addRect(
                                            abs_x + m.x * self_scale,
                                            abs_y + m.y * self_scale,
                                            m.width * self_scale,
                                            m.height * self_scale,
                                            selection_color,
                                            0,
                                            0,
                                            .{ 0.0, 0.0, 0.0, 0.0 },
                                        );
                                    }
                                }
                            }
                        }

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            var effective_style = self.style;
                            applySpanStyle(&effective_style, rt.spans, m.byte_offset);

                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const text_color = colorWithOpacity(effective_style.text_color, combined_opacity);
                            const text_weight = msdfWeightFor(effective_style.font_weight);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = abs_x + m.render_x * self_scale;
                            const glyph_y = abs_y + m.render_y * self_scale;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w * self_scale),
                                snapSize(glyph_y, m.render_h * self_scale),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }

                        try emitTextDecorations(
                            batcher,
                            cache.metrics,
                            rt.font,
                            &self.style,
                            abs_x,
                            abs_y,
                            self.style.text_color,
                            combined_opacity,
                            self_scale,
                        );
                    }
                },

                .text_input => |ti| {
                    const pad = self.style.padding;
                    const bdr = self.style.border;

                    const inset_left = (pad.left + @max(0.0, bdr.left.width)) * self_scale * layout_mod.active_zoom;
                    const inset_top = (pad.top + @max(0.0, bdr.top.width)) * self_scale * layout_mod.active_zoom;
                    const inset_bottom = (pad.bottom + @max(0.0, bdr.bottom.width)) * self_scale * layout_mod.active_zoom;

                    const cache = self.layout_result.text_cache;

                    const font_scale = if (self.style.font_size > 0.0) (self.style.font_size * layout_mod.active_zoom / ti.font.base_size) else 1.0;
                    const fallback_line_h = if (cache.line_height > 0.0) cache.line_height else (ti.font.line_height * font_scale);

                    const active_text_h = if (cache.height > 0.0) cache.height else fallback_line_h;

                    const inner_h = h - inset_top - inset_bottom;
                    const scaled_text_h = active_text_h * self_scale;
                    const align_offset_y = @max(0.0, @round((inner_h - scaled_text_h) / 2.0));

                    const text_x = abs_x + inset_left;
                    const text_y = abs_y + inset_top + align_offset_y;

                    const selection_color = colorWithOpacity(.{ 0.2, 0.4, 0.8, 0.5 }, combined_opacity);

                    const sc = batcher.current_scissor;
                    const view_min_x: f32 = @floatFromInt(sc.offset.x);
                    const view_min_y: f32 = @floatFromInt(sc.offset.y);
                    const view_max_x: f32 = @floatFromInt(sc.offset.x + @as(i32, @intCast(sc.extent.width)));
                    const view_max_y: f32 = @floatFromInt(sc.offset.y + @as(i32, @intCast(sc.extent.height)));
                    const node_max_x = abs_x + w;
                    const node_max_y = abs_y + h;
                    const is_offscreen = node_max_x <= view_min_x or abs_x >= view_max_x or
                        node_max_y <= view_min_y or abs_y >= view_max_y;

                    if (!is_offscreen) {
                        const showing_placeholder = ti.buffer.items.len == 0 and ti.placeholder.len > 0;
                        const base_color = if (showing_placeholder)
                            (ti.placeholder_color orelse mutedFallback(self.style.text_color))
                        else
                            self.style.text_color;
                        const text_color = colorWithOpacity(base_color, combined_opacity);
                        const text_weight = msdfWeightFor(self.style.font_weight);

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = text_x + m.render_x * self_scale;
                            const glyph_y = text_y + m.render_y * self_scale;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w * self_scale),
                                snapSize(glyph_y, m.render_h * self_scale),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }

                        try emitTextDecorations(
                            batcher,
                            cache.metrics,
                            ti.font,
                            &self.style,
                            text_x,
                            text_y,
                            self.style.text_color,
                            combined_opacity,
                            self_scale,
                        );
                    }

                    if (self.is_focused and !is_offscreen) {
                        var cursor_x: f32 = text_x;
                        var cursor_y: f32 = text_y;

                        const cursor_h: f32 = fallback_line_h * self_scale;

                        const metrics = self.layout_result.text_cache.metrics;
                        var max_metric_index: usize = 0;
                        for (metrics) |m| {
                            max_metric_index = @max(max_metric_index, m.byte_offset + m.byte_length);
                            if (ti.cursor_index == m.byte_offset) {
                                cursor_x = text_x + m.x * self_scale;
                                cursor_y = text_y + m.y * self_scale;
                                break;
                            }
                            if (ti.cursor_index >= m.byte_offset + m.byte_length) {
                                cursor_x = text_x + m.x * self_scale + m.width * self_scale;
                                cursor_y = text_y + m.y * self_scale;
                            }
                        }

                        if (ti.buffer.items.len > 0 and (metrics.len == 0 or max_metric_index <= 1)) {
                            const clamped_idx = @min(ti.cursor_index, ti.buffer.items.len);
                            const ratio = @as(f32, @floatFromInt(clamped_idx)) /
                                @as(f32, @floatFromInt(ti.buffer.items.len));
                            cursor_x = text_x + self.layout_result.text_cache.width * ratio * self_scale;
                        }

                        const alpha = @abs(std.math.sin(time * 5.0));
                        try batcher.addRect(
                            cursor_x,
                            cursor_y,
                            2.0,
                            cursor_h,
                            .{ 1.0, 1.0, 1.0, alpha * combined_opacity },
                            0,
                            0,
                            .{ 0, 0, 0, 0 },
                        );

                        if (ti.selection_anchor) |anchor| {
                            const start = @min(anchor, ti.cursor_index);
                            const end = @max(anchor, ti.cursor_index);
                            if (start != end) {
                                for (metrics) |m| {
                                    if (m.byte_offset >= start and m.byte_offset < end) {
                                        try batcher.addRect(
                                            text_x + m.x * self_scale,
                                            text_y + m.y * self_scale,
                                            m.width * self_scale,
                                            m.height * self_scale,
                                            selection_color,
                                            0,
                                            0,
                                            .{ 0.0, 0.0, 0.0, 0.0 },
                                        );
                                    }
                                }
                            }
                        }
                    }
                },

                .text_area => |ta| {
                    const pad = self.style.padding;
                    const bdr = self.style.border;

                    const inset_left = (pad.left + @max(0.0, bdr.left.width)) * self_scale * layout_mod.active_zoom;
                    const inset_top = (pad.top + @max(0.0, bdr.top.width)) * self_scale * layout_mod.active_zoom;
                    const inset_bottom = (pad.bottom + @max(0.0, bdr.bottom.width)) * self_scale * layout_mod.active_zoom;

                    const cache = self.layout_result.text_cache;
                    const font_scale = if (self.style.font_size > 0.0) (self.style.font_size * layout_mod.active_zoom / ta.font.base_size) else 1.0;
                    const fallback_line_h = if (cache.line_height > 0.0) cache.line_height else (ta.font.line_height * font_scale);

                    const text_x = abs_x + inset_left;
                    const text_y = abs_y + inset_top - ta.scroll_y * self_scale;

                    const selection_color = colorWithOpacity(.{ 0.2, 0.4, 0.8, 0.5 }, combined_opacity);

                    const sc = batcher.current_scissor;
                    const view_min_x: f32 = @floatFromInt(sc.offset.x);
                    const view_min_y: f32 = @floatFromInt(sc.offset.y);
                    const view_max_x: f32 = @floatFromInt(sc.offset.x + @as(i32, @intCast(sc.extent.width)));
                    const view_max_y: f32 = @floatFromInt(sc.offset.y + @as(i32, @intCast(sc.extent.height)));
                    const node_max_x = abs_x + w;
                    const node_max_y = abs_y + h;
                    const is_offscreen = node_max_x <= view_min_x or abs_x >= view_max_x or
                        node_max_y <= view_min_y or abs_y >= view_max_y;

                    if (!is_offscreen) {
                        const inset_right = (pad.right + @max(0.0, bdr.right.width)) * self_scale * layout_mod.active_zoom;
                        const inner_x = abs_x + inset_left;
                        const inner_y = abs_y + inset_top;
                        const inner_w = @max(0.0, w - inset_left - inset_right);
                        const inner_h = @max(0.0, h - inset_top - inset_bottom);

                        try batcher.pushScissor(inner_x, inner_y, inner_w, inner_h, .{ 0.0, 0.0, 0.0, 0.0 });
                        defer batcher.popScissor() catch {};

                        if (self.is_focused) {
                            if (ta.selection_anchor) |anchor| {
                                const start = @min(anchor, ta.cursor_index);
                                const end = @max(anchor, ta.cursor_index);
                                if (start != end) {
                                    var line_active = false;
                                    var line_y: f32 = 0.0;
                                    var line_h: f32 = 0.0;
                                    var line_start_x: f32 = 0.0;
                                    var line_end_x: f32 = 0.0;

                                    for (cache.metrics) |m| {
                                        if (m.byte_offset < start or m.byte_offset >= end) continue;

                                        if (!line_active or @abs(m.y - line_y) > 0.01) {
                                            if (line_active and line_end_x > line_start_x) {
                                                try batcher.addRect(
                                                    text_x + line_start_x * self_scale,
                                                    text_y + line_y * self_scale,
                                                    (line_end_x - line_start_x) * self_scale,
                                                    line_h * self_scale,
                                                    selection_color,
                                                    0,
                                                    0,
                                                    .{ 0.0, 0.0, 0.0, 0.0 },
                                                );
                                            }

                                            line_active = true;
                                            line_y = m.y;
                                            line_h = m.height;
                                            line_start_x = m.x;
                                            line_end_x = m.x + m.width;
                                        } else {
                                            line_start_x = @min(line_start_x, m.x);
                                            line_end_x = @max(line_end_x, m.x + m.width);
                                            line_h = @max(line_h, m.height);
                                        }
                                    }

                                    if (line_active and line_end_x > line_start_x) {
                                        try batcher.addRect(
                                            text_x + line_start_x * self_scale,
                                            text_y + line_y * self_scale,
                                            (line_end_x - line_start_x) * self_scale,
                                            line_h * self_scale,
                                            selection_color,
                                            0,
                                            0,
                                            .{ 0.0, 0.0, 0.0, 0.0 },
                                        );
                                    }
                                }
                            }
                        }

                        const text_color = colorWithOpacity(self.style.text_color, combined_opacity);
                        const text_weight = msdfWeightFor(self.style.font_weight);

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = text_x + m.render_x * self_scale;
                            const glyph_y = text_y + m.render_y * self_scale;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w * self_scale),
                                snapSize(glyph_y, m.render_h * self_scale),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }

                        try emitTextDecorations(
                            batcher,
                            cache.metrics,
                            ta.font,
                            &self.style,
                            text_x,
                            text_y,
                            self.style.text_color,
                            combined_opacity,
                            self_scale,
                        );

                        if (self.is_focused and !is_offscreen) {
                            var cursor_x: f32 = text_x;
                            var cursor_y: f32 = text_y;
                            var cursor_h: f32 = fallback_line_h * self_scale;

                            const metrics = cache.metrics;
                            var max_metric_index: usize = 0;

                            for (metrics) |m| {
                                max_metric_index = @max(max_metric_index, m.byte_offset + m.byte_length);

                                if (ta.cursor_index == m.byte_offset) {
                                    cursor_x = text_x + m.x * self_scale;
                                    cursor_y = text_y + m.y * self_scale;
                                    cursor_h = m.height * self_scale;
                                    break;
                                }

                                if (ta.cursor_index >= m.byte_offset + m.byte_length) {
                                    cursor_x = text_x + (m.x + m.width) * self_scale;
                                    cursor_y = text_y + m.y * self_scale;
                                    cursor_h = m.height * self_scale;

                                    if (m.byte_length > 0 and m.width == 0 and m.byte_offset < ta.buffer.items.len and ta.buffer.items[m.byte_offset] == '\n') {
                                        cursor_x = text_x;
                                        cursor_y = text_y + (m.y + m.height) * self_scale;
                                    }
                                }
                            }

                            if (ta.buffer.items.len > 0 and (metrics.len == 0 or max_metric_index <= 1)) {
                                const clamped_idx = @min(ta.cursor_index, ta.buffer.items.len);
                                const ratio = @as(f32, @floatFromInt(clamped_idx)) /
                                    @as(f32, @floatFromInt(ta.buffer.items.len));
                                cursor_x = text_x + cache.width * ratio * self_scale;
                                cursor_y = text_y;
                            }

                            const alpha = @abs(std.math.sin(time * 5.0));
                            try batcher.addRect(
                                cursor_x,
                                cursor_y,
                                2.0,
                                @max(1.0, cursor_h),
                                .{ 1.0, 1.0, 1.0, alpha * combined_opacity },
                                0,
                                0,
                                .{ 0, 0, 0, 0 },
                            );
                        }
                    }
                },

                .image => |img| {
                    if (img.fallback_state != .ready and img.alt_text.len > 0 and img.alt_font != null) {
                        const cache = self.layout_result.text_cache;
                        const text_color = colorWithOpacity(self.style.text_color, combined_opacity);
                        const text_weight = msdfWeightFor(self.style.font_weight);

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = abs_x + m.render_x * self_scale;
                            const glyph_y = abs_y + m.render_y * self_scale;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w * self_scale),
                                snapSize(glyph_y, m.render_h * self_scale),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }

                        try emitTextDecorations(
                            batcher,
                            cache.metrics,
                            img.alt_font.?,
                            &self.style,
                            abs_x,
                            abs_y,
                            self.style.text_color,
                            combined_opacity,
                            self_scale,
                        );
                    } else {
                        var effect_flags: u32 = 0;
                        if (backdrop_blur > 0.0) effect_flags |= assets.EFFECT_BACKDROP_BLUR;
                        if (element_blur > 0.0) effect_flags |= assets.EFFECT_ELEMENT_BLUR;

                        var params = img.custom_params;
                        params[0] = backdrop_blur;
                        params[1] = element_blur;

                        var base_uv_min: [2]f32 = .{ 0.0, 0.0 };
                        var base_uv_max: [2]f32 = .{ 1.0, 1.0 };

                        if (img.animation) |anim| {
                            if (anim.total_duration_ms > 0 and anim.frames.len > 0) {
                                const elapsed_s: f64 = @max(0.0, @as(f64, time) - img.start_time);
                                const elapsed_ms: u32 = @intFromFloat(@mod(elapsed_s * 1000.0, @as(f64, @floatFromInt(anim.total_duration_ms))));
                                var acc: u32 = 0;
                                var picked: usize = anim.frames.len - 1;
                                for (anim.frames, 0..) |frame, idx| {
                                    acc += frame.delay_ms;
                                    if (elapsed_ms < acc) {
                                        picked = idx;
                                        break;
                                    }
                                }
                                base_uv_min = anim.frames[picked].uv_min;
                                base_uv_max = anim.frames[picked].uv_max;
                            }
                        }

                        const fit_data = computeMediaFit(
                            abs_x,
                            abs_y,
                            w,
                            h,
                            img.intrinsic_size[0],
                            img.intrinsic_size[1],
                            self.style.object_fit,
                        );

                        const final_uv_min = .{
                            base_uv_min[0] + fit_data.uv_min[0] * (base_uv_max[0] - base_uv_min[0]),
                            base_uv_min[1] + fit_data.uv_min[1] * (base_uv_max[1] - base_uv_min[1]),
                        };
                        const final_uv_max = .{
                            base_uv_min[0] + fit_data.uv_max[0] * (base_uv_max[0] - base_uv_min[0]),
                            base_uv_min[1] + fit_data.uv_max[1] * (base_uv_max[1] - base_uv_min[1]),
                        };

                        try batcher.addRectUV(
                            fit_data.x,
                            fit_data.y,
                            fit_data.w,
                            fit_data.h,
                            final_uv_min,
                            final_uv_max,
                            colorWithOpacity(img.tint, combined_opacity),
                            img.tex_id,
                            effect_flags,
                            params,
                            rotation,
                        );
                    }
                },

                .canvas => |canvas_payload| {
                    var effect_flags: u32 = 0;
                    if (backdrop_blur > 0.0) effect_flags |= assets.EFFECT_BACKDROP_BLUR;
                    if (element_blur > 0.0) effect_flags |= assets.EFFECT_ELEMENT_BLUR;

                    var params = canvas_payload.custom_params;
                    params[0] = backdrop_blur;
                    params[1] = element_blur;

                    const img_w = @as(f32, @floatFromInt(canvas_payload.target.width));
                    const img_h = @as(f32, @floatFromInt(canvas_payload.target.height));

                    const zoom = @max(0.0001, canvas_payload.zoom);
                    const pan_x = canvas_payload.pan_x;
                    const pan_y = canvas_payload.pan_y;

                    const center_x = w / 2.0;
                    const center_y = h / 2.0;

                    const start_x = abs_x + center_x + pan_x - (img_w / 2.0) * zoom;
                    const start_y = abs_y + center_y + pan_y - (img_h / 2.0) * zoom;
                    const screen_w = img_w * zoom;
                    const screen_h = img_h * zoom;

                    const clip_x = @max(start_x, abs_x);
                    const clip_y = @max(start_y, abs_y);
                    const clip_r = @min(start_x + screen_w, abs_x + w);
                    const clip_b = @min(start_y + screen_h, abs_y + h);
                    const clip_w = clip_r - clip_x;
                    const clip_h = clip_b - clip_y;

                    if (clip_w > 0.0 and clip_h > 0.0) {
                        const uv0_x = (clip_x - start_x) / screen_w;
                        const uv0_y = (clip_y - start_y) / screen_h;
                        const uv1_x = (clip_r - start_x) / screen_w;
                        const uv1_y = (clip_b - start_y) / screen_h;

                        try batcher.addRectUV(
                            clip_x,
                            clip_y,
                            clip_w,
                            clip_h,
                            .{ uv0_x, uv0_y },
                            .{ uv1_x, uv1_y },
                            colorWithOpacity(canvas_payload.tint, combined_opacity),
                            canvas_payload.target.texId(),
                            effect_flags,
                            params,
                            rotation,
                        );
                    }
                },
                .custom_paint => |cp| {
                    var pctx = PaintContext{
                        .batcher = batcher,
                        .bounds = .{ .x = abs_x, .y = abs_y, .width = w, .height = h },
                        .opacity = combined_opacity,
                    };
                    try cp.paint_fn(&pctx, cp.userdata);
                },
                .video => |v| {
                    const tex = v.playback.texture orelse return;
                    if (tex.descriptor_set == .null_handle) return;

                    var effect_flags: u32 = 0;
                    if (backdrop_blur > 0.0) effect_flags |= assets.EFFECT_BACKDROP_BLUR;
                    if (element_blur > 0.0) effect_flags |= assets.EFFECT_ELEMENT_BLUR;

                    var params = v.custom_params;
                    params[0] = backdrop_blur;
                    params[1] = element_blur;

                    const v_w = @as(f32, @floatFromInt(v.playback.width));
                    const v_h = @as(f32, @floatFromInt(v.playback.height));

                    const fit_data = computeMediaFit(
                        abs_x,
                        abs_y,
                        w,
                        h,
                        v_w,
                        v_h,
                        self.style.object_fit,
                    );

                    try batcher.addVideoRectUV(
                        fit_data.x,
                        fit_data.y,
                        fit_data.w,
                        fit_data.h,
                        fit_data.uv_min,
                        fit_data.uv_max,
                        colorWithOpacity(v.tint, combined_opacity),
                        tex.y_plane.tex_id,
                        tex.descriptor_set,
                        effect_flags,
                        params,
                    );
                },
            }

            const needs_clip = self.clipsChildren();
            if (needs_clip) {
                const bdr = self.style.border;
                const inset_l = @max(0.0, bdr.left.width);
                const inset_t = @max(0.0, bdr.top.width);
                const inset_r = @max(0.0, bdr.right.width);
                const inset_b = @max(0.0, bdr.bottom.width);
                const clip_radii = if (self.style.corner_radius.hasAny()) blk: {
                    const r = self.style.corner_radius.toArray();
                    const max_inset = @max(@max(inset_l, inset_t), @max(inset_r, inset_b));
                    break :blk [4]f32{
                        @max(0.0, r[0] - max_inset),
                        @max(0.0, r[1] - max_inset),
                        @max(0.0, r[2] - max_inset),
                        @max(0.0, r[3] - max_inset),
                    };
                } else [4]f32{ 0.0, 0.0, 0.0, 0.0 };
                try batcher.pushScissor(
                    abs_x + inset_l,
                    abs_y + inset_t,
                    @max(0.0, w - inset_l - inset_r),
                    @max(0.0, h - inset_t - inset_b),
                    clip_radii,
                );
            }

            for (self.children.items) |child| {
                try child.renderWithOpacity(
                    batcher,
                    text_layouter,
                    time,
                    combined_opacity,
                    self_scale,
                    self_tx,
                    self_ty,
                    effective_z,
                    is_portal_pass,
                );
            }

            if (needs_clip) {
                try batcher.popScissor();
            }

            if (self.getVerticalScrollbarThumbRect()) |thumb| {
                const radius = @min(self.style.scrollbar_radius, @min(thumb.width, thumb.height) / 2.0);
                try batcher.addRoundedRect(
                    thumb.x,
                    thumb.y,
                    thumb.width,
                    thumb.height,
                    colorWithOpacity(self.style.scrollbar_color, combined_opacity),
                    .{
                        .radii = .{ radius, radius, radius, radius },
                        .softness = 1.0,
                    },
                    0.0, // scrollbars do not inherit parent rotation
                );
            }

            if (self.getHorizontalScrollbarThumbRect()) |thumb| {
                const radius = @min(self.style.scrollbar_radius, @min(thumb.width, thumb.height) / 2.0);
                try batcher.addRoundedRect(
                    thumb.x,
                    thumb.y,
                    thumb.width,
                    thumb.height,
                    colorWithOpacity(self.style.scrollbar_color, combined_opacity),
                    .{ .radii = .{ radius, radius, radius, radius }, .softness = 1.0 },
                    0.0,
                );
            }
        }

        pub fn markContentDirty(self: *@This()) void {
            if (self.flags.content) return;
            self.flags.content = true;
            self.flags.size = true;
            self.flags.position = true;
            if (self.parent) |p| p.markSizeDirty();
        }

        pub fn markSizeDirty(self: *@This()) void {
            if (self.flags.size) return;
            self.flags.size = true;
            self.flags.position = true;
            if (self.parent) |p| p.markSizeDirty();
        }

        pub fn markPositionDirty(self: *@This()) void {
            if (self.flags.position) return;
            self.flags.position = true;
            if (self.parent) |p| p.markPositionDirty();
        }

        pub fn scrollDescendantIntoViewX(self: *@This(), child: *const Node(MessageT), padding: f32) bool {
            const visible_w = self.layout_result.width;
            if (visible_w <= 0.0) return false;

            const visible_left = self.layout_result.x;
            const visible_right = visible_left + visible_w;
            const child_left = child.layout_result.x;
            const child_right = child_left + child.layout_result.width;

            var delta: f32 = 0.0;
            if (child_left < visible_left + padding) {
                delta = child_left - (visible_left + padding);
            } else if (child_right > visible_right - padding) {
                delta = child_right - (visible_right - padding);
            } else {
                return false;
            }

            const max_scroll = @max(0.0, self.layout_result.content_width - visible_w);
            const new_scroll = std.math.clamp(self.scroll_x + delta, 0.0, max_scroll);
            if (@abs(new_scroll - self.scroll_x) <= 0.01) return false;

            self.scroll_x = new_scroll;
            self.prev_desc_scroll_x = new_scroll;
            self.markPositionDirty();
            return true;
        }

        pub fn markDirty(self: *@This()) void {
            self.markContentDirty();
        }

        pub fn markDirtyWithAncestors(self: *@This()) void {
            var cur: ?*Node(MessageT) = self;
            while (cur) |node| {
                node.flags = .{};
                cur = node.parent;
            }
        }

        pub fn setText(self: *Node(MessageT), new_text: []const u8) !void {
            if (self.payload != .text) return error.InvalidNodeType;
            if (std.mem.eql(u8, self.payload.text.content, new_text)) return;
            self.allocator.free(self.payload.text.content);
            self.payload.text.content = try self.allocator.dupe(u8, new_text);
            self.markContentDirty();
        }

        pub fn setColor(self: *Node(MessageT), new_color: [4]f32) void {
            self.style.background_color = new_color;
        }

        pub fn setTextColor(self: *Node(MessageT), new_color: [4]f32) void {
            switch (self.payload) {
                .image => self.payload.image.tint = new_color,
                .canvas => self.payload.canvas.tint = new_color,
                else => self.style.text_color = new_color,
            }
        }

        pub fn debugPrint(self: *const Node(MessageT), depth: usize) void {
            var i: usize = 0;
            while (i < depth) : (i += 1) std.debug.print("  ", .{});

            switch (self.payload) {
                .container => std.debug.print("Container", .{}),
                .image => std.debug.print("Image", .{}),
                .canvas => std.debug.print("Canvas", .{}),
                .portal => std.debug.print("Portal", .{}),
                .video => std.debug.print("Video", .{}),
                .text_input => |ti| std.debug.print("TextInput(\"{s}\")", .{ti.buffer.items}),
                .text_area => |ta| std.debug.print("TextArea(\"{s}\")", .{ta.buffer.items}),
                .text => |t| {
                    if (t.content.len > 15)
                        std.debug.print("Text(\"{s}...\")", .{t.content[0..15]})
                    else
                        std.debug.print("Text(\"{s}\")", .{t.content});
                },
                .none => std.debug.print("Root/Wrapper", .{}),
                .fragment => std.debug.print("Fragment", .{}),
                .custom_paint => std.debug.print("CustomPaint", .{}),
            }

            std.debug.print(" [x:{d:.1} y:{d:.1} w:{d:.1} h:{d:.1}]", .{
                self.layout_result.x,
                self.layout_result.y,
                self.layout_result.width,
                self.layout_result.height,
            });

            if (self.style.background_color[3] > 0) {
                std.debug.print(" bg:[{d:.2},{d:.2},{d:.2},{d:.2}]", .{
                    self.style.background_color[0],
                    self.style.background_color[1],
                    self.style.background_color[2],
                    self.style.background_color[3],
                });
            }

            std.debug.print("\n", .{});

            for (self.children.items) |child| {
                child.debugPrint(depth + 1);
            }
        }
    };
}

fn metricIntersectsSpan(m: TextLayoutMetric, span: RichTextSpan) bool {
    const a0 = m.byte_offset;
    const a1 = m.byte_offset + m.byte_length;
    return a0 < span.end and a1 > span.start;
}

fn applySpanStyle(base: *Style, spans: []const RichTextSpan, byte_offset: usize) void {
    for (spans) |span| {
        if (byte_offset < span.start or byte_offset >= span.end) continue;
        if (span.mask.text_color) base.text_color = span.style.text_color;
        if (span.mask.background_color) base.background_color = span.style.background_color;
        if (span.mask.text_decoration) base.text_decoration = span.style.text_decoration;
    }
}

pub fn freeEventPayloads(comptime MessageT: type, allocator: std.mem.Allocator, events: []const types.EventBinding(MessageT)) void {
    for (events) |binding| {
        if (binding.destroy_userdata) |destroy_userdata| {
            destroy_userdata(binding.userdata, allocator);
        }
    }
}

pub fn dupeMessageBinding(comptime MessageT: type, event: EventType, msg: MessageT) types.EventBinding(MessageT) {
    return .{
        .event = event,
        .msg = msg,
        .userdata = null,
        .destroy_userdata = null,
        .handler = null,
    };
}

pub fn destroyOwnedEventUserdata(comptime T: type) *const fn (?*const anyopaque, std.mem.Allocator) void {
    return struct {
        fn destroy(userdata: ?*const anyopaque, allocator: std.mem.Allocator) void {
            const ptr: *T = @ptrCast(@alignCast(@constCast(userdata orelse return)));
            allocator.destroy(ptr);
        }
    }.destroy;
}
