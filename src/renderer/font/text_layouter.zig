const std = @import("std");
const Vertex = @import("../vulkan/vertex.zig").Vertex;
const QuadBatcher = @import("../vulkan/batcher.zig").QuadBatcher;
const Core = @import("../vulkan/core.zig").Core;
const font_module = @import("font_registry.zig");
const FontRegistry = font_module.FontRegistry;
const FontData = font_module.FontData;
const FontSystem = @import("font_system.zig").FontSystem;
const c = font_module.c;

const assets = @import("../../assets.zig");
const EFFECT_MSDF_TEXT = assets.EFFECT_MSDF_TEXT;
const EFFECT_BITMAP_TEXT = assets.EFFECT_BITMAP_TEXT;

/// Below this effective pixel size, glyphs render via the FreeType-hinted bitmap atlas.
/// At or above, they render via MSDF.
pub const BITMAP_THRESHOLD_PX: f32 = 18.0;

fn snapPixel(value: f32) f32 {
    return @round(value);
}

fn snapSize(origin: f32, size: f32) f32 {
    return @max(1.0, @round(origin + size) - @round(origin));
}

const TextSegment = struct {
    font_name: []const u8,
    start_byte: usize,
    end_byte: usize,
};

pub const GlyphMetric = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    byte_offset: usize,
    byte_length: usize,

    render_x: f32,
    render_y: f32,
    render_w: f32,
    render_h: f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    is_visible: bool,
};

pub const MeasureResult = struct {
    width: f32,
    height: f32,
    metrics: []GlyphMetric,
    /// True when the bitmap (hinted FreeType) path was used; node renderers
    /// must then sample from `font.bitmap_atlas_tex_id` with EFFECT_BITMAP_TEXT.
    is_bitmap: bool = false,
};

pub const TextBounds = struct {
    width: f32,
    height: f32,
};

pub const LayoutOptions = struct {
    max_width: f32 = 0.0,
    wrap: bool = true,
    ellipsis: bool = false,
    line_height: f32 = 0.0,
    font_size: f32 = 0.0,
};

pub const TextLayouter = struct {
    allocator: std.mem.Allocator,
    hb_buffer: *c.hb_buffer_t,
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),

    core: ?*const Core = null,
    font_registry: ?*FontRegistry = null,

    pub fn init(allocator: std.mem.Allocator) !TextLayouter {
        const hb_buffer = c.hb_buffer_create() orelse return error.HarfBuzzBufferCreationFailed;
        return TextLayouter{
            .allocator = allocator,
            .hb_buffer = hb_buffer,
            .vertices = std.ArrayList(Vertex).empty,
            .indices = std.ArrayList(u32).empty,
            .core = null,
            .font_registry = null,
        };
    }

    pub fn layoutText(
        self: *TextLayouter,
        font_system: *FontSystem,
        requested_font_name: ?[]const u8,
        text: []const u8,
        x: f32,
        y: f32,
        max_width: f32,
        color: [4]f32,
        weight: f32,
    ) !void {
        try self.layoutTextWithOptions(
            font_system,
            requested_font_name,
            text,
            x,
            y,
            color,
            weight,
            .{
                .max_width = max_width,
            },
        );
    }

    pub fn layoutTextWithOptions(
        self: *TextLayouter,
        font_system: *FontSystem,
        requested_font_name: ?[]const u8,
        text: []const u8,
        x: f32,
        y: f32,
        color: [4]f32,
        weight: f32,
        options: LayoutOptions,
    ) !void {
        if (text.len == 0) return;

        var segments = std.ArrayList(TextSegment).empty;
        defer segments.deinit(self.allocator);

        var utf8_view = try std.unicode.Utf8View.init(text);
        var iter = utf8_view.iterator();

        var current_segment = TextSegment{
            .font_name = "",
            .start_byte = 0,
            .end_byte = 0,
        };

        while (iter.nextCodepointSlice()) |slice| {
            const codepoint = std.unicode.utf8Decode(slice) catch continue;
            const resolved_font = font_system.resolveFontForCodepoint(requested_font_name, codepoint);

            const byte_offset = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);

            if (current_segment.start_byte == current_segment.end_byte) {
                current_segment.font_name = resolved_font;
                current_segment.end_byte = byte_offset + slice.len;
            } else if (std.mem.eql(u8, current_segment.font_name, resolved_font)) {
                current_segment.end_byte = byte_offset + slice.len;
            } else {
                try segments.append(self.allocator, current_segment);
                current_segment = .{
                    .font_name = resolved_font,
                    .start_byte = byte_offset,
                    .end_byte = byte_offset + slice.len,
                };
            }
        }
        if (current_segment.end_byte > current_segment.start_byte) {
            try segments.append(self.allocator, current_segment);
        }

        const max_width = @max(0.0, options.max_width);
        const wrap_enabled = options.wrap and max_width > 0.0;
        const ellipsis_enabled = options.ellipsis and !options.wrap and max_width > 0.0;
        const clip_enabled = !options.wrap and !options.ellipsis and max_width > 0.0;

        var cursor_x: f32 = 0.0;
        var cursor_y: f32 = 0.0;
        var truncated = false;

        var last_safe_break: ?usize = null;
        var last_safe_break_x: f32 = 0.0;
        var last_safe_break_v_idx: usize = self.vertices.items.len;

        for (segments.items) |segment| {
            if (truncated) break;

            const font_data = font_system.font_registry.fonts.getPtr(segment.font_name) orelse continue;

            const target_size = if (options.font_size > 0.0) options.font_size else font_data.base_size;
            const use_bitmap = options.font_size > 0.0 and target_size < BITMAP_THRESHOLD_PX;
            const target_px_u: u32 = if (use_bitmap)
                @intFromFloat(@max(@round(target_size), 1.0))
            else
                0;
            const target_px_f: f32 = @floatFromInt(target_px_u);

            const metric_scale: f32 = if (use_bitmap)
                target_px_f / font_data.base_size
            else if (options.font_size > 0.0)
                options.font_size / font_data.base_size
            else
                1.0;
            const glyph_scale: f32 = if (use_bitmap) 1.0 else metric_scale;
            const ascender_target = font_data.ascender * metric_scale;

            const line_height = if (options.line_height > 0.0) options.line_height else (font_data.line_height * metric_scale);

            c.hb_buffer_clear_contents(self.hb_buffer);
            c.hb_buffer_add_utf8(self.hb_buffer, text.ptr, @intCast(text.len), @intCast(segment.start_byte), @intCast(segment.end_byte - segment.start_byte));
            c.hb_buffer_guess_segment_properties(self.hb_buffer);

            c.hb_shape(font_data.hb_font, self.hb_buffer, null, 0);

            var glyph_count: u32 = 0;
            const glyph_info = c.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
            const glyph_pos = c.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

            const dot_glyph_id: u32 = @intCast(c.FT_Get_Char_Index(font_data.ft_face, '.'));

            if (self.core) |core| {
                if (self.font_registry) |reg| {
                    if (use_bitmap) {
                        reg.ensureBitmapGlyph(core, font_data, dot_glyph_id, target_px_u) catch {};
                    } else {
                        reg.ensureGlyph(core, font_data, dot_glyph_id) catch {};
                    }
                }
            }

            const dot_advance: f32 = if (use_bitmap) blk: {
                const dk = font_module.bitmapGlyphKey(dot_glyph_id, target_px_u);
                if (font_data.bitmap_glyphs.get(dk)) |bg| break :blk bg.advance;
                break :blk font_data.line_height * 0.33 * metric_scale;
            } else (if (font_data.glyphs.get(dot_glyph_id)) |dot_glyph| dot_glyph.advance else font_data.line_height * 0.33) * metric_scale;
            const ellipsis_width = dot_advance * 3.0;

            const atlas_tex_id: u32 = if (use_bitmap) font_data.bitmap_atlas_tex_id else font_data.atlas_tex_id;
            const effect_flag: u32 = if (use_bitmap) EFFECT_BITMAP_TEXT else EFFECT_MSDF_TEXT;
            const combined_id: u32 = effect_flag | (atlas_tex_id & 0xFFFF);
            const glyph_corner_radii: [4]f32 = if (use_bitmap)
                [4]f32{ weight, 0, 0, 0 }
            else
                [4]f32{ weight, font_data.sdf_padding, 0, 0 };

            var i: usize = 0;
            while (i < glyph_count) : (i += 1) {
                const codepoint = glyph_info[i].codepoint;

                if (self.core) |core| {
                    if (self.font_registry) |reg| {
                        if (use_bitmap) {
                            reg.ensureBitmapGlyph(core, font_data, codepoint, target_px_u) catch |err| {
                                std.log.err("TextLayouter: failed to ensure bitmap glyph {d}@{d}px: {s}", .{ codepoint, target_px_u, @errorName(err) });
                            };
                        } else {
                            reg.ensureGlyph(core, font_data, codepoint) catch |err| {
                                std.log.err("TextLayouter: failed to ensure glyph {d}: {s}", .{ codepoint, @errorName(err) });
                            };
                        }
                    }
                }

                const glyph_opt: ?font_module.GlyphInfo = if (use_bitmap)
                    font_data.bitmap_glyphs.get(font_module.bitmapGlyphKey(codepoint, target_px_u))
                else
                    font_data.glyphs.get(codepoint);

                const hb_advance = (@as(f32, @floatFromInt(glyph_pos[i].x_advance)) / 64.0) * metric_scale;
                const x_advance: f32 = if (use_bitmap) blk: {
                    if (glyph_opt) |g| break :blk g.advance;
                    break :blk hb_advance;
                } else hb_advance;
                const cluster = glyph_info[i].cluster;
                const cluster_in_bounds = cluster < text.len;
                const is_space = cluster_in_bounds and text[cluster] == ' ';
                const is_newline = cluster_in_bounds and text[cluster] == '\n';

                if (is_newline) {
                    cursor_x = 0.0;
                    cursor_y += line_height;
                    last_safe_break = null;
                    continue;
                }

                if (is_space) {
                    last_safe_break = cluster;
                    last_safe_break_x = cursor_x + x_advance;
                    last_safe_break_v_idx = self.vertices.items.len;
                }

                if (wrap_enabled and cursor_x + x_advance > max_width) {
                    if (last_safe_break != null and last_safe_break.? < cluster) {
                        const shift_x = last_safe_break_x;
                        const shift_y = line_height;

                        for (self.vertices.items[last_safe_break_v_idx..]) |*v| {
                            v.pos[0] -= shift_x;
                            v.pos[1] += shift_y;
                        }

                        cursor_x -= shift_x;
                        cursor_y += shift_y;

                        last_safe_break = null;
                    } else {
                        cursor_x = 0.0;
                        cursor_y += line_height;
                    }
                }

                if (!wrap_enabled and max_width > 0.0) {
                    if (ellipsis_enabled) {
                        if (cursor_x + x_advance > max_width) {
                            truncated = true;
                            break;
                        }

                        if (cursor_x + x_advance > max_width - ellipsis_width and i + 1 < glyph_count) {
                            truncated = true;
                            break;
                        }
                    } else if (clip_enabled and cursor_x + x_advance > max_width) {
                        truncated = true;
                        break;
                    }
                }

                if (glyph_opt) |glyph| {
                    const px = x + cursor_x + glyph.bearing[0] * glyph_scale;
                    const py = y + cursor_y - glyph.bearing[1] * glyph_scale + ascender_target;

                    const pw = glyph.size[0] * glyph_scale;
                    const ph = glyph.size[1] * glyph_scale;

                    const base_idx: u32 = @intCast(self.vertices.items.len);
                    const sx = snapPixel(px);
                    const sy = snapPixel(py);
                    const sw = snapSize(px, pw);
                    const sh = snapSize(py, ph);

                    const quads = [_]Vertex{
                        .{ .pos = .{ sx, sy }, .uv = .{ glyph.uv_min[0], glyph.uv_min[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                        .{ .pos = .{ sx + sw, sy }, .uv = .{ glyph.uv_max[0], glyph.uv_min[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                        .{ .pos = .{ sx + sw, sy + sh }, .uv = .{ glyph.uv_max[0], glyph.uv_max[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                        .{ .pos = .{ sx, sy + sh }, .uv = .{ glyph.uv_min[0], glyph.uv_max[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                    };

                    try self.vertices.appendSlice(self.allocator, &quads);

                    const quad_indices = [_]u32{
                        base_idx, base_idx + 1, base_idx + 2,
                        base_idx, base_idx + 2, base_idx + 3,
                    };

                    try self.indices.appendSlice(self.allocator, &quad_indices);
                }

                cursor_x += x_advance;
            }

            if (ellipsis_enabled and truncated and dot_glyph_id != 0) {
                const dot_glyph_opt: ?font_module.GlyphInfo = if (use_bitmap)
                    font_data.bitmap_glyphs.get(font_module.bitmapGlyphKey(dot_glyph_id, target_px_u))
                else
                    font_data.glyphs.get(dot_glyph_id);
                if (dot_glyph_opt) |glyph| {
                    var dot_i: usize = 0;
                    while (dot_i < 3 and cursor_x + dot_advance <= max_width + 0.01) : (dot_i += 1) {
                        const px = x + cursor_x + (@as(f32, @floatFromInt(glyph_pos[i].x_offset)) / 64.0) * metric_scale + glyph.bearing[0] * glyph_scale;
                        const py = y + cursor_y + (@as(f32, @floatFromInt(glyph_pos[i].y_offset)) / 64.0) * metric_scale - glyph.bearing[1] * glyph_scale + ascender_target;

                        const pw = glyph.size[0] * glyph_scale;
                        const ph = glyph.size[1] * glyph_scale;

                        const base_idx: u32 = @intCast(self.vertices.items.len);
                        const sx = snapPixel(px);
                        const sy = snapPixel(py);
                        const sw = snapSize(px, pw);
                        const sh = snapSize(py, ph);

                        const quads = [_]Vertex{
                            .{ .pos = .{ sx, sy }, .uv = .{ glyph.uv_min[0], glyph.uv_min[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                            .{ .pos = .{ sx + sw, sy }, .uv = .{ glyph.uv_max[0], glyph.uv_min[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                            .{ .pos = .{ sx + sw, sy + sh }, .uv = .{ glyph.uv_max[0], glyph.uv_max[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                            .{ .pos = .{ sx, sy + sh }, .uv = .{ glyph.uv_min[0], glyph.uv_max[1] }, .color = color, .tex_id = combined_id, .corner_radii = glyph_corner_radii },
                        };

                        try self.vertices.appendSlice(self.allocator, &quads);

                        const quad_indices = [_]u32{
                            base_idx, base_idx + 1, base_idx + 2,
                            base_idx, base_idx + 2, base_idx + 3,
                        };

                        try self.indices.appendSlice(self.allocator, &quad_indices);

                        cursor_x += dot_advance;
                    }
                }
            }
        }
    }

    pub fn flushToBatcher(self: *TextLayouter, batcher: *QuadBatcher) !void {
        var layer = batcher.current_layer orelse unreachable;
        const index_offset: u32 = @intCast(layer.vertices.items.len);
        const sc = batcher.current_scissor;
        const clip_rect: [4]f32 = .{
            @floatFromInt(sc.offset.x),
            @floatFromInt(sc.offset.y),
            @floatFromInt(sc.offset.x + @as(i32, @intCast(sc.extent.width))),
            @floatFromInt(sc.offset.y + @as(i32, @intCast(sc.extent.height))),
        };

        var i_v: usize = 0;
        while (i_v < self.vertices.items.len) : (i_v += 1) {
            var v = self.vertices.items[i_v];
            v.clip_rect = clip_rect;
            try layer.vertices.append(batcher.allocator, v);
        }

        var i: usize = 0;
        while (i < self.indices.items.len) : (i += 1) {
            try layer.indices.append(batcher.allocator, self.indices.items[i] + index_offset);
        }

        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }

    pub fn measureText(self: *TextLayouter, allocator: std.mem.Allocator, font_data: *FontData, text: []const u8, max_width: f32) MeasureResult {
        return self.measureTextWithOptions(allocator, font_data, text, .{
            .max_width = max_width,
        });
    }

    pub fn measureTextWithOptions(
        self: *TextLayouter,
        allocator: std.mem.Allocator,
        font_data: *FontData,
        text: []const u8,
        options: LayoutOptions,
    ) MeasureResult {
        if (text.len == 0) return .{ .width = 0, .height = 0, .metrics = &.{}, .is_bitmap = false };

        c.hb_buffer_clear_contents(self.hb_buffer);
        c.hb_buffer_add_utf8(self.hb_buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(self.hb_buffer);

        c.hb_shape(font_data.hb_font, self.hb_buffer, null, 0);

        var glyph_count: u32 = 0;
        const glyph_info = c.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
        const glyph_pos = c.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

        var metrics = std.ArrayList(GlyphMetric).empty;
        defer metrics.deinit(allocator);

        const target_size = if (options.font_size > 0.0) options.font_size else font_data.base_size;
        const use_bitmap = options.font_size > 0.0 and target_size < BITMAP_THRESHOLD_PX;
        const target_px_u: u32 = if (use_bitmap)
            @intFromFloat(@max(@round(target_size), 1.0))
        else
            0;
        const target_px_f: f32 = @floatFromInt(target_px_u);

        const metric_scale: f32 = if (use_bitmap)
            target_px_f / font_data.base_size
        else if (options.font_size > 0.0)
            options.font_size / font_data.base_size
        else
            1.0;
        const glyph_scale: f32 = if (use_bitmap) 1.0 else metric_scale;
        const ascender_target = font_data.ascender * metric_scale;

        const line_height = if (options.line_height > 0.0) options.line_height else (font_data.line_height * metric_scale);
        const max_width = @max(0.0, options.max_width);
        const wrap_enabled = options.wrap and max_width > 0.0;
        const ellipsis_enabled = options.ellipsis and !options.wrap and max_width > 0.0;
        const clip_enabled = !options.wrap and !options.ellipsis and max_width > 0.0;

        const dot_glyph_id: u32 = @intCast(c.FT_Get_Char_Index(font_data.ft_face, '.'));

        if (self.core) |core| {
            if (self.font_registry) |reg| {
                if (use_bitmap) {
                    reg.ensureBitmapGlyph(core, font_data, dot_glyph_id, target_px_u) catch {};
                } else {
                    reg.ensureGlyph(core, font_data, dot_glyph_id) catch {};
                }
            }
        }

        const dot_advance: f32 = if (use_bitmap) blk: {
            const dk = font_module.bitmapGlyphKey(dot_glyph_id, target_px_u);
            if (font_data.bitmap_glyphs.get(dk)) |bg| break :blk bg.advance;
            break :blk font_data.line_height * 0.33 * metric_scale;
        } else (if (font_data.glyphs.get(dot_glyph_id)) |dot_glyph| dot_glyph.advance else font_data.line_height * 0.33) * metric_scale;
        const ellipsis_width = dot_advance * 3.0;

        var cursor_x: f32 = 0.0;
        var cursor_y: f32 = 0.0;
        var max_x: f32 = 0.0;
        var truncated = false;

        var last_safe_break: ?usize = null;
        var last_safe_break_x: f32 = 0.0;
        var last_safe_break_metric_idx: usize = 0;

        var i: usize = 0;
        while (i < glyph_count) : (i += 1) {
            const codepoint = glyph_info[i].codepoint;

            if (self.core) |core| {
                if (self.font_registry) |reg| {
                    if (use_bitmap) {
                        reg.ensureBitmapGlyph(core, font_data, codepoint, target_px_u) catch |err| {
                            std.log.err("TextLayouter: failed to ensure bitmap glyph {d}@{d}px: {s}", .{ codepoint, target_px_u, @errorName(err) });
                        };
                    } else {
                        reg.ensureGlyph(core, font_data, codepoint) catch |err| {
                            std.log.err("TextLayouter: failed to ensure glyph {d}: {s}", .{ codepoint, @errorName(err) });
                        };
                    }
                }
            }

            const glyph_opt: ?font_module.GlyphInfo = if (use_bitmap)
                font_data.bitmap_glyphs.get(font_module.bitmapGlyphKey(codepoint, target_px_u))
            else
                font_data.glyphs.get(codepoint);

            const hb_advance = (@as(f32, @floatFromInt(glyph_pos[i].x_advance)) / 64.0) * metric_scale;
            const x_advance: f32 = if (use_bitmap) blk: {
                if (glyph_opt) |g| break :blk g.advance;
                break :blk hb_advance;
            } else hb_advance;
            const cluster = glyph_info[i].cluster;
            const cluster_in_bounds = cluster < text.len;
            const is_space = cluster_in_bounds and text[cluster] == ' ';
            const is_newline = cluster_in_bounds and text[cluster] == '\n';

            const byte_length: usize = if (i + 1 < glyph_count)
                glyph_info[i + 1].cluster - cluster
            else
                text.len - cluster;

            if (is_newline) {
                metrics.append(allocator, .{
                    .x = cursor_x,
                    .y = cursor_y,
                    .width = 0.0,
                    .height = line_height,
                    .byte_offset = cluster,
                    .byte_length = byte_length,
                    .render_x = 0.0,
                    .render_y = 0.0,
                    .render_w = 0.0,
                    .render_h = 0.0,
                    .uv_min = .{ 0.0, 0.0 },
                    .uv_max = .{ 0.0, 0.0 },
                    .is_visible = false,
                }) catch @panic("OOM in TextLayouter");

                max_x = @max(max_x, cursor_x);
                cursor_x = 0.0;
                cursor_y += line_height;
                last_safe_break = null;
                continue;
            }

            if (is_space) {
                last_safe_break = i;
                last_safe_break_x = cursor_x + x_advance;
                last_safe_break_metric_idx = metrics.items.len;
            }

            if (wrap_enabled and cursor_x + x_advance > max_width) {
                if (last_safe_break != null and last_safe_break.? < i) {
                    const shift_x = last_safe_break_x;
                    const shift_y = line_height;
                    for (metrics.items[last_safe_break_metric_idx..]) |*m| {
                        m.x -= shift_x;
                        m.y += shift_y;
                        m.render_x -= shift_x;
                        m.render_y += shift_y;
                    }

                    max_x = @max(max_x, last_safe_break_x);
                    cursor_x -= shift_x;
                    cursor_y += line_height;
                    last_safe_break = null;
                } else {
                    max_x = @max(max_x, cursor_x);
                    cursor_x = 0.0;
                    cursor_y += line_height;
                }
            }

            if (!wrap_enabled and max_width > 0.0) {
                if (ellipsis_enabled) {
                    if (cursor_x + x_advance > max_width) {
                        truncated = true;
                        break;
                    }

                    if (cursor_x + x_advance > max_width - ellipsis_width and i + 1 < glyph_count) {
                        truncated = true;
                        break;
                    }
                } else if (clip_enabled and cursor_x + x_advance > max_width) {
                    break;
                }
            }

            var is_visible = false;
            var render_x: f32 = 0.0;
            var render_y: f32 = 0.0;
            var render_w: f32 = 0.0;
            var render_h: f32 = 0.0;
            var uv_min: [2]f32 = .{ 0.0, 0.0 };
            var uv_max: [2]f32 = .{ 0.0, 0.0 };

            if (glyph_opt) |glyph| {
                render_x = cursor_x + (@as(f32, @floatFromInt(glyph_pos[i].x_offset)) / 64.0) * metric_scale + glyph.bearing[0] * glyph_scale;
                render_y = cursor_y + (@as(f32, @floatFromInt(glyph_pos[i].y_offset)) / 64.0) * metric_scale - glyph.bearing[1] * glyph_scale + ascender_target;
                render_w = glyph.size[0] * glyph_scale;
                render_h = glyph.size[1] * glyph_scale;
                uv_min = glyph.uv_min;
                uv_max = glyph.uv_max;
                is_visible = !is_space and !is_newline;
            }

            metrics.append(allocator, .{
                .x = cursor_x,
                .y = cursor_y,
                .width = x_advance,
                .height = line_height,
                .byte_offset = cluster,
                .byte_length = byte_length,
                .render_x = render_x,
                .render_y = render_y,
                .render_w = render_w,
                .render_h = render_h,
                .uv_min = uv_min,
                .uv_max = uv_max,
                .is_visible = is_visible,
            }) catch @panic("OOM in TextLayouter");

            cursor_x += x_advance;
        }

        if (ellipsis_enabled and truncated) {
            const dot_glyph: ?font_module.GlyphInfo = if (use_bitmap)
                font_data.bitmap_glyphs.get(font_module.bitmapGlyphKey(dot_glyph_id, target_px_u))
            else
                font_data.glyphs.get(dot_glyph_id);
            var dot_i: usize = 0;
            while (dot_i < 3 and cursor_x + dot_advance <= max_width + 0.01) : (dot_i += 1) {
                var is_visible = false;
                var render_x: f32 = 0.0;
                var render_y: f32 = 0.0;
                var render_w: f32 = 0.0;
                var render_h: f32 = 0.0;
                var uv_min: [2]f32 = .{ 0.0, 0.0 };
                var uv_max: [2]f32 = .{ 0.0, 0.0 };

                if (dot_glyph) |glyph| {
                    render_x = cursor_x + glyph.bearing[0] * glyph_scale;
                    render_y = cursor_y - glyph.bearing[1] * glyph_scale + ascender_target;
                    render_w = glyph.size[0] * glyph_scale;
                    render_h = glyph.size[1] * glyph_scale;
                    uv_min = glyph.uv_min;
                    uv_max = glyph.uv_max;
                    is_visible = true;
                }

                metrics.append(allocator, .{
                    .x = cursor_x,
                    .y = cursor_y,
                    .width = dot_advance,
                    .height = line_height,
                    .byte_offset = text.len,
                    .byte_length = 0,
                    .render_x = render_x,
                    .render_y = render_y,
                    .render_w = render_w,
                    .render_h = render_h,
                    .uv_min = uv_min,
                    .uv_max = uv_max,
                    .is_visible = is_visible,
                }) catch @panic("OOM in TextLayouter");
                cursor_x += dot_advance;
            }
        }

        max_x = @max(max_x, cursor_x);

        const final_height = cursor_y + line_height;
        if (metrics.items.len == 0) {
            return .{
                .width = max_x,
                .height = final_height,
                .metrics = &.{},
                .is_bitmap = use_bitmap,
            };
        }

        const owned_metrics = allocator.alloc(GlyphMetric, metrics.items.len) catch @panic("OOM in TextLayouter");
        @memcpy(owned_metrics, metrics.items);

        return .{
            .width = max_x,
            .height = final_height,
            .metrics = owned_metrics,
            .is_bitmap = use_bitmap,
        };
    }

    pub fn deinit(self: *TextLayouter) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        c.hb_buffer_destroy(self.hb_buffer);
    }
};
