const std = @import("std");
const batcher_mod = @import("../renderer/vulkan/batcher.zig");
const QuadBatcher = batcher_mod.QuadBatcher;
const RoundedRectStyle = batcher_mod.RoundedRectStyle;
const packColor = batcher_mod.packColor;
const Border = @import("layout.zig").Border;
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const TextLayouter = @import("../renderer/font/text_layouter.zig").TextLayouter;
const Style = @import("layout.zig").Style;
const LayoutResult = @import("layout.zig").LayoutResult;
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

pub const HoverAnim = struct {
    start_time: f64,
    from: f32,
    to: f32,
    duration: f64,
    timing: EasingFunction,
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
        placeholder_color: ?[4]f32 = null,
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

        allocator: std.mem.Allocator = undefined,
        parent: ?*Node(MessageT) = null,
        children: std.ArrayList(*Node(MessageT)),

        flags: InvalidationState = .{},

        is_focusable: bool = false,
        is_focused: bool = false,
        is_hovered: bool = false,
        lock_pointer_on_drag: bool = false,

        hover_anim: ?HoverAnim = null,

        text_selection: ?TextSelection = null,

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

        pub fn deinit(self: *@This()) void {
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
                else => {},
            }

            for (self.children.items) |child| {
                child.deinit();
            }
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

        fn resolveAccumulatedTranslate(self: *const @This()) [2]f32 {
            var dx: f32 = 0.0;
            var dy: f32 = 0.0;
            var cur: ?*const @This() = self;

            while (cur) |node| {
                dx += node.style.transform.translate[0];
                dy += node.style.transform.translate[1];
                cur = node.parent;
            }

            return .{ dx, dy };
        }

        pub fn getTransformedRect(self: *const @This()) TransformedRect {
            const raw_x = self.layout_result.x;
            const raw_y = self.layout_result.y;
            const raw_w = self.layout_result.width;
            const raw_h = self.layout_result.height;
            const tr = self.style.transform;
            const accumulated_translate = self.resolveAccumulatedTranslate();

            const exact_x = raw_x + accumulated_translate[0] + (raw_w - raw_w * tr.scale) * 0.5;
            const exact_y = raw_y + accumulated_translate[1] + (raw_h - raw_h * tr.scale) * 0.5;
            const exact_w = raw_w * tr.scale;
            const exact_h = raw_h * tr.scale;

            const abs_x = @round(exact_x);
            const abs_y = @round(exact_y);

            return .{
                .x = abs_x,
                .y = abs_y,
                .width = @round(exact_x + exact_w) - abs_x,
                .height = @round(exact_y + exact_h) - abs_y,
                .local_scale = tr.scale,
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
            const thumb_x = transformed.x + transformed.width - thumb_w - 2.0 * transformed.local_scale;

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

            const thumb_y = transformed.y + transformed.height - thumb_h - 2.0 * transformed.local_scale;

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

        fn colorWithOpacity(color: [4]f32, opacity: f32) [4]f32 {
            return .{ color[0], color[1], color[2], std.math.clamp(color[3] * opacity, 0.0, 1.0) };
        }

        /// Used as the placeholder color when no explicit `placeholder_color` is
        /// set on the input. Half-alpha of the active text color.
        fn mutedFallback(color: [4]f32) [4]f32 {
            return .{ color[0], color[1], color[2], color[3] * 0.45 };
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
            try self.renderWithOpacity(batcher, text_layouter, time, 1.0, 0.0, 0.0, 0, false);
        }

        pub fn renderPortal(
            self: *const @This(),
            batcher: *QuadBatcher,
            text_layouter: *TextLayouter,
            time: f32,
        ) !void {
            try self.renderWithOpacity(batcher, text_layouter, time, 1.0, 0.0, 0.0, 0, true);
        }

        fn renderWithOpacity(
            self: *const @This(),
            batcher: *QuadBatcher,
            text_layouter: *TextLayouter,
            time: f32,
            parent_opacity: f32,
            parent_dx: f32,
            parent_dy: f32,
            parent_z: @TypeOf(self.style.z_index),
            is_portal_pass: bool,
        ) !void {
            if (self.style.display == .none) return;
            if (self.payload == .portal and !is_portal_pass) return;

            const tr = self.style.transform;
            const raw_x = self.layout_result.x;
            const raw_y = self.layout_result.y;
            const raw_w = self.layout_result.width;
            const raw_h = self.layout_result.height;

            const exact_x = raw_x + tr.translate[0] + parent_dx + (raw_w - raw_w * tr.scale) * 0.5;
            const exact_y = raw_y + tr.translate[1] + parent_dy + (raw_h - raw_h * tr.scale) * 0.5;
            const exact_w = raw_w * tr.scale;
            const exact_h = raw_h * tr.scale;

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

            const bg_base = if (self.style.hover_color) |hc| blk: {
                const t = std.math.clamp(self.style._hover_blend, 0.0, 1.0);
                const a = self.style.background_color;
                break :blk [4]f32{
                    a[0] + (hc[0] - a[0]) * t,
                    a[1] + (hc[1] - a[1]) * t,
                    a[2] + (hc[2] - a[2]) * t,
                    a[3] + (hc[3] - a[3]) * t,
                };
            } else self.style.background_color;
            const bg = colorWithOpacity(bg_base, combined_opacity);

            const backdrop_blur = @max(0.0, self.style.backdrop_blur);
            const element_blur = @max(0.0, self.style.blur);

            const has_any_visual =
                bg[3] > 0 or
                backdrop_blur > 0 or
                element_blur > 0 or
                self.style.border.hasAny() or
                self.style.outline.hasAny() or
                self.style.corner_radius.hasAny();

            if (has_any_visual) {
                const bdr = self.style.border;
                const otl = self.style.outline;

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
                    },
                    rotation,
                );
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
                        const text_weight = self.style.font_weight;

                        if (self.text_selection) |sel| {
                            const start = @min(sel.anchor, sel.focus);
                            const end = @max(sel.anchor, sel.focus);
                            if (start != end) {
                                for (cache.metrics) |m| {
                                    if (m.byte_offset >= start and m.byte_offset < end) {
                                        try batcher.addRect(
                                            abs_x + m.x,
                                            abs_y + m.y,
                                            m.width,
                                            m.height,
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
                            const glyph_x = abs_x + m.render_x;
                            const glyph_y = abs_y + m.render_y;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w),
                                snapSize(glyph_y, m.render_h),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }
                    }
                },

                .text_input => |ti| {
                    const pad = self.style.padding;
                    const bdr = self.style.border;

                    const inset_left = (pad.left + @max(0.0, bdr.left.width)) * tr.scale;
                    const inset_top = (pad.top + @max(0.0, bdr.top.width)) * tr.scale;
                    const inset_bottom = (pad.bottom + @max(0.0, bdr.bottom.width)) * tr.scale;

                    const cache = self.layout_result.text_cache;

                    const font_scale = if (self.style.font_size > 0.0) (self.style.font_size / ti.font.base_size) else 1.0;
                    const fallback_line_h = if (cache.line_height > 0.0) cache.line_height else (ti.font.line_height * font_scale);

                    const active_text_h = if (cache.height > 0.0) cache.height else fallback_line_h;

                    const inner_h = h - inset_top - inset_bottom;
                    const scaled_text_h = active_text_h * tr.scale;
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
                        const text_weight = self.style.font_weight;

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = text_x + m.render_x;
                            const glyph_y = text_y + m.render_y;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w),
                                snapSize(glyph_y, m.render_h),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }
                    }

                    if (self.is_focused and !is_offscreen) {
                        var cursor_x: f32 = text_x;
                        var cursor_y: f32 = text_y;

                        const cursor_h: f32 = fallback_line_h * tr.scale;

                        const metrics = self.layout_result.text_cache.metrics;
                        var max_metric_index: usize = 0;
                        for (metrics) |m| {
                            max_metric_index = @max(max_metric_index, m.byte_offset + m.byte_length);
                            if (ti.cursor_index == m.byte_offset) {
                                cursor_x = text_x + m.x;
                                cursor_y = text_y + m.y;
                                break;
                            }
                            if (ti.cursor_index >= m.byte_offset + m.byte_length) {
                                cursor_x = text_x + m.x + m.width;
                                cursor_y = text_y + m.y;
                            }
                        }

                        if (ti.buffer.items.len > 0 and (metrics.len == 0 or max_metric_index <= 1)) {
                            const clamped_idx = @min(ti.cursor_index, ti.buffer.items.len);
                            const ratio = @as(f32, @floatFromInt(clamped_idx)) /
                                @as(f32, @floatFromInt(ti.buffer.items.len));
                            cursor_x = text_x + self.layout_result.text_cache.width * ratio;
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
                                            text_x + m.x,
                                            text_y + m.y,
                                            m.width,
                                            m.height,
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

                    const inset_left = (pad.left + @max(0.0, bdr.left.width)) * tr.scale;
                    const inset_top = (pad.top + @max(0.0, bdr.top.width)) * tr.scale;
                    const inset_bottom = (pad.bottom + @max(0.0, bdr.bottom.width)) * tr.scale;

                    const cache = self.layout_result.text_cache;
                    const font_scale = if (self.style.font_size > 0.0) (self.style.font_size / ta.font.base_size) else 1.0;
                    const fallback_line_h = if (cache.line_height > 0.0) cache.line_height else (ta.font.line_height * font_scale);

                    const text_x = abs_x + inset_left;
                    const text_y = abs_y + inset_top - ta.scroll_y * tr.scale;

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
                        const inset_right = (pad.right + @max(0.0, bdr.right.width)) * tr.scale;
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
                                                    text_x + line_start_x,
                                                    text_y + line_y,
                                                    line_end_x - line_start_x,
                                                    line_h * tr.scale,
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
                                            text_x + line_start_x,
                                            text_y + line_y,
                                            line_end_x - line_start_x,
                                            line_h * tr.scale,
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
                        const text_weight = self.style.font_weight;

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = text_x + m.render_x;
                            const glyph_y = text_y + m.render_y;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w),
                                snapSize(glyph_y, m.render_h),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }

                        if (self.is_focused and !is_offscreen) {
                            var cursor_x: f32 = text_x;
                            var cursor_y: f32 = text_y;
                            var cursor_h: f32 = fallback_line_h * tr.scale;

                            const metrics = cache.metrics;
                            var max_metric_index: usize = 0;

                            for (metrics) |m| {
                                max_metric_index = @max(max_metric_index, m.byte_offset + m.byte_length);

                                if (ta.cursor_index == m.byte_offset) {
                                    cursor_x = text_x + m.x;
                                    cursor_y = text_y + m.y;
                                    cursor_h = m.height * tr.scale;
                                    break;
                                }

                                if (ta.cursor_index >= m.byte_offset + m.byte_length) {
                                    cursor_x = text_x + m.x + m.width;
                                    cursor_y = text_y + m.y;
                                    cursor_h = m.height * tr.scale;

                                    if (m.byte_length > 0 and m.width == 0 and m.byte_offset < ta.buffer.items.len and ta.buffer.items[m.byte_offset] == '\n') {
                                        cursor_x = text_x;
                                        cursor_y = text_y + m.y + m.height;
                                    }
                                }
                            }

                            if (ta.buffer.items.len > 0 and (metrics.len == 0 or max_metric_index <= 1)) {
                                const clamped_idx = @min(ta.cursor_index, ta.buffer.items.len);
                                const ratio = @as(f32, @floatFromInt(clamped_idx)) /
                                    @as(f32, @floatFromInt(ta.buffer.items.len));
                                cursor_x = text_x + cache.width * ratio;
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
                        const text_weight = self.style.font_weight;

                        for (cache.metrics) |m| {
                            if (!m.is_visible) continue;
                            const combined_id: u32 = m.effect | (m.atlas_id & 0xFFFF);
                            const glyph_corner_radii: [4]f32 = .{ text_weight, m.sdf_padding, 0, 0 };
                            const glyph_x = abs_x + m.render_x;
                            const glyph_y = abs_y + m.render_y;
                            try batcher.addGlyphQuad(
                                snapPixel(glyph_x),
                                snapPixel(glyph_y),
                                snapSize(glyph_x, m.render_w),
                                snapSize(glyph_y, m.render_h),
                                m.uv_min,
                                m.uv_max,
                                text_color,
                                combined_id,
                                glyph_corner_radii,
                            );
                        }
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
                            canvas_payload.target.gpu_texture.tex_id,
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
                const clip_radii = if (self.style.corner_radius.hasAny())
                    self.style.corner_radius.toArray()
                else
                    [4]f32{ 0.0, 0.0, 0.0, 0.0 };
                try batcher.pushScissor(
                    abs_x,
                    abs_y,
                    @max(0.0, w),
                    @max(0.0, h),
                    clip_radii,
                );
            }

            const accumulated_dx = parent_dx + tr.translate[0];
            const accumulated_dy = parent_dy + tr.translate[1];

            for (self.children.items) |child| {
                try child.renderWithOpacity(
                    batcher,
                    text_layouter,
                    time,
                    combined_opacity,
                    accumulated_dx,
                    accumulated_dy,
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
