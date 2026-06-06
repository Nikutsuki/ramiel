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
const EFFECT_COLOR_GLYPH = assets.EFFECT_COLOR_GLYPH;

/// Sizes below this use the FreeType-hinted bitmap atlas; at/above goes MSDF.
/// 22 keeps common body sizes (16-20) sharp via hinted bitmaps.
pub const BITMAP_THRESHOLD_PX: f32 = 22.0;

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

    /// Bindless atlas index this glyph samples from. With font fallback a single
    /// run can mix atlases (e.g. text in the MSDF atlas, emoji in the color one).
    atlas_id: u32 = 0,
    /// EFFECT_MSDF_TEXT / EFFECT_BITMAP_TEXT / EFFECT_COLOR_GLYPH for this glyph.
    effect: u32 = 0,
    /// MSDF px-range padding for this glyph's font (0 for bitmap/color glyphs).
    sdf_padding: f32 = 0,
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

pub const FontFeature = struct {
    tag: [4]u8,
    value: u32 = 1,
};

fn featTag(s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

const MeasureCache = struct {
    const max_entries = 16384;

    const Key = struct {
        content_hash: u64,
        features: u64,
        font: usize,
        font_size: u32,
        line_height: u32,
        max_width: u32,
        flags: u8,
    };

    const Entry = struct {
        content: []u8,
        metrics: []GlyphMetric,
        width: f32,
        height: f32,
        is_bitmap: bool,
        last_used: u64,
    };
    tick: u64 = 0,

    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,

    fn evictIfFull(self: *MeasureCache, a: std.mem.Allocator) void {
        if (self.map.count() < max_entries) return;
        var lo: u64 = std.math.maxInt(u64);
        var hi: u64 = 0;
        var it = self.map.iterator();
        while (it.next()) |e| {
            lo = @min(lo, e.value_ptr.last_used);
            hi = @max(hi, e.value_ptr.last_used);
        }
        const cutoff = lo + (hi - lo) / 2;
        var doomed = std.ArrayList(Key).empty;
        defer doomed.deinit(a);
        it = self.map.iterator();
        while (it.next()) |e| if (e.value_ptr.last_used <= cutoff) (doomed.append(a, e.key_ptr.*) catch {});
        for (doomed.items) |k| {
            const e = self.map.fetchRemove(k).?;
            a.free(e.value.content);
            a.free(e.value.metrics);
        }
    }

    fn clearEntries(self: *MeasureCache, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            allocator.free(e.value_ptr.content);
            allocator.free(e.value_ptr.metrics);
        }
        self.map.clearRetainingCapacity();
    }

    fn deinit(self: *MeasureCache, allocator: std.mem.Allocator) void {
        self.clearEntries(allocator);
        self.map.deinit(allocator);
    }
};

pub const TextLayouter = struct {
    allocator: std.mem.Allocator,
    hb_buffer: *c.hb_buffer_t,
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),

    core: ?*const Core = null,
    font_registry: ?*FontRegistry = null,
    /// Back-pointer to the owning FontSystem, used for per-codepoint font
    /// fallback during measurement. Null until the first font is loaded.
    font_system: ?*FontSystem = null,
    font_features: []const FontFeature = &.{},
    measure_cache: MeasureCache = .{},

    fn shapeBuffer(self: *TextLayouter, hb_font: anytype) void {
        if (self.font_features.len == 0) {
            c.hb_shape(hb_font, self.hb_buffer, null, 0);
            return;
        }
        var buf: [64]c.hb_feature_t = undefined;
        const n = @min(self.font_features.len, buf.len);
        for (self.font_features[0..n], 0..) |f, i| {
            buf[i] = .{ .tag = featTag(&f.tag), .value = f.value, .start = 0, .end = std.math.maxInt(c_uint) };
        }
        c.hb_shape(hb_font, self.hb_buffer, &buf[0], @intCast(n));
    }

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

            self.shapeBuffer(font_data.hb_font);

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

    /// Resolve which loaded font should render `cp`, preferring the requested
    /// (primary) font and falling back through the FontSystem's default chain.
    /// Returns `primary` when nothing in the chain has the glyph (renders tofu).
    fn resolveFontForCp(self: *TextLayouter, primary: *FontData, cp: u21) *FontData {
        if (c.FT_Get_Char_Index(primary.ft_face, cp) != 0) return primary;
        if (self.font_system) |fs| {
            for (fs.default_fallback_chain.items) |name| {
                if (fs.font_registry.fonts.getPtr(name)) |fd| {
                    if (fd != primary and c.FT_Get_Char_Index(fd.ft_face, cp) != 0) return fd;
                }
            }
        }
        return primary;
    }

    /// Per-segment rendering parameters derived from a run's resolved font.
    const SegParams = struct {
        font: *FontData,
        is_color: bool,
        use_bitmap: bool,
        target_px_u: u32,
        metric_scale: f32,
        glyph_scale: f32,
        atlas_id: u32,
        effect: u32,
        sdf_padding: f32,
    };

    fn deriveSegParams(font: *FontData, target_size: f32, font_size: f32) SegParams {
        const is_color = font.is_color;
        const use_bitmap = is_color or (font_size > 0.0 and target_size < BITMAP_THRESHOLD_PX);
        const target_px_u: u32 = if (is_color)
            font.color_strike_px
        else if (use_bitmap)
            @intFromFloat(@max(@round(target_size), 1.0))
        else
            0;
        const metric_scale: f32 = if (is_color)
            target_size / font.base_size
        else if (use_bitmap)
            @as(f32, @floatFromInt(target_px_u)) / font.base_size
        else
            target_size / font.base_size;
        return .{
            .font = font,
            .is_color = is_color,
            .use_bitmap = use_bitmap,
            .target_px_u = target_px_u,
            .metric_scale = metric_scale,
            .glyph_scale = if (use_bitmap and !is_color) 1.0 else metric_scale,
            .atlas_id = if (use_bitmap) font.bitmap_atlas_tex_id else font.atlas_tex_id,
            .effect = if (is_color) EFFECT_COLOR_GLYPH else if (use_bitmap) EFFECT_BITMAP_TEXT else EFFECT_MSDF_TEXT,
            .sdf_padding = if (use_bitmap) 0 else font.sdf_padding,
        };
    }

    fn measureKey(self: *TextLayouter, font_data: *FontData, text: []const u8, options: LayoutOptions) MeasureCache.Key {
        var fh = std.hash.Wyhash.init(0);
        for (self.font_features) |f| {
            fh.update(&f.tag);
            fh.update(std.mem.asBytes(&f.value));
        }
        return .{
            .content_hash = std.hash.Wyhash.hash(0, text),
            .features = fh.final(),
            .font = @intFromPtr(font_data),
            .font_size = @bitCast(options.font_size),
            .line_height = @bitCast(options.line_height),
            .max_width = @bitCast(options.max_width),
            .flags = @as(u8, @intFromBool(options.wrap)) | (@as(u8, @intFromBool(options.ellipsis)) << 1),
        };
    }

    fn cacheStore(self: *TextLayouter, key: MeasureCache.Key, text: []const u8, measured: MeasureResult) void {
        const a = self.allocator;
        if (self.measure_cache.map.count() >= MeasureCache.max_entries and !self.measure_cache.map.contains(key)) {
            self.measure_cache.evictIfFull(a);
        }
        const content = a.dupe(u8, text) catch return;
        const metrics = a.dupe(GlyphMetric, measured.metrics) catch {
            a.free(content);
            return;
        };
        const gop = self.measure_cache.map.getOrPut(a, key) catch {
            a.free(content);
            a.free(metrics);
            return;
        };
        if (gop.found_existing) {
            a.free(gop.value_ptr.content);
            a.free(gop.value_ptr.metrics);
        }
        gop.value_ptr.* = .{
            .content = content,
            .metrics = metrics,
            .width = measured.width,
            .height = measured.height,
            .is_bitmap = measured.is_bitmap,
            .last_used = self.measure_cache.tick,
        };
        self.measure_cache.tick += 1;
    }

    pub fn measureTextCached(
        self: *TextLayouter,
        allocator: std.mem.Allocator,
        font_data: *FontData,
        text: []const u8,
        options: LayoutOptions,
    ) MeasureResult {
        if (text.len == 0) return self.measureTextWithOptions(allocator, font_data, text, options);

        const key = self.measureKey(font_data, text, options);
        if (self.measure_cache.map.getPtr(key)) |e| {
            if (std.mem.eql(u8, e.content, text)) {
                e.last_used = self.measure_cache.tick;
                self.measure_cache.tick += 1;
                return .{
                    .width = e.width,
                    .height = e.height,
                    .is_bitmap = e.is_bitmap,
                    .metrics = allocator.dupe(GlyphMetric, e.metrics) catch @panic("OOM while duping cached text metrics"),
                };
            }
        }

        const measured = self.measureTextWithOptions(allocator, font_data, text, options);
        self.cacheStore(key, text, measured);
        return measured;
    }

    pub fn measureTextWithOptions(
        self: *TextLayouter,
        allocator: std.mem.Allocator,
        font_data: *FontData,
        text: []const u8,
        options: LayoutOptions,
    ) MeasureResult {
        if (text.len == 0) return .{ .width = 0, .height = 0, .metrics = &.{}, .is_bitmap = false };

        var metrics = std.ArrayList(GlyphMetric).empty;
        defer metrics.deinit(allocator);

        // Target size and the baseline/line box come from the primary (requested)
        // font, so a mixed-font run (e.g. text plus fallback emoji) shares one
        // baseline rather than each segment using its own ascender.
        const target_size = if (options.font_size > 0.0) options.font_size else font_data.base_size;
        const primary = deriveSegParams(font_data, target_size, options.font_size);
        const ascender_target = font_data.ascender * primary.metric_scale;
        const line_height = if (options.line_height > 0.0) options.line_height else (font_data.line_height * primary.metric_scale);

        const max_width = @max(0.0, options.max_width);
        const wrap_enabled = options.wrap and max_width > 0.0;
        const ellipsis_enabled = options.ellipsis and !options.wrap and max_width > 0.0;
        const clip_enabled = !options.wrap and !options.ellipsis and max_width > 0.0;

        const dot_glyph_id: u32 = @intCast(c.FT_Get_Char_Index(font_data.ft_face, '.'));
        if (self.core) |core| {
            if (self.font_registry) |reg| {
                if (primary.use_bitmap) {
                    reg.ensureBitmapGlyph(core, font_data, dot_glyph_id, primary.target_px_u) catch {};
                } else {
                    reg.ensureGlyph(core, font_data, dot_glyph_id) catch {};
                }
            }
        }
        const dot_advance: f32 = if (primary.use_bitmap) blk: {
            const dk = font_module.bitmapGlyphKey(dot_glyph_id, primary.target_px_u);
            if (font_data.bitmap_glyphs.get(dk)) |bg| break :blk bg.advance * primary.glyph_scale;
            break :blk font_data.line_height * 0.33 * primary.metric_scale;
        } else (if (font_data.glyphs.get(dot_glyph_id)) |dot_glyph| dot_glyph.advance else font_data.line_height * 0.33) * primary.metric_scale;
        const ellipsis_width = dot_advance * 3.0;

        // Split the text into runs of a single resolved font (font fallback).
        const Segment = struct { font: *FontData, start: usize, end: usize };
        var segments = std.ArrayList(Segment).empty;
        defer segments.deinit(allocator);
        if (std.unicode.Utf8View.init(text)) |view| {
            var iter = view.iterator();
            var cur_font: ?*FontData = null;
            var cur_start: usize = 0;
            while (iter.nextCodepointSlice()) |slice| {
                const cp = std.unicode.utf8Decode(slice) catch continue;
                const off = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);
                const f = self.resolveFontForCp(font_data, cp);
                if (cur_font == null) {
                    cur_font = f;
                    cur_start = off;
                } else if (cur_font.? != f) {
                    segments.append(allocator, .{ .font = cur_font.?, .start = cur_start, .end = off }) catch @panic("OOM in TextLayouter");
                    cur_font = f;
                    cur_start = off;
                }
            }
            if (cur_font) |f| segments.append(allocator, .{ .font = f, .start = cur_start, .end = text.len }) catch @panic("OOM in TextLayouter");
        } else |_| {
            segments.append(allocator, .{ .font = font_data, .start = 0, .end = text.len }) catch @panic("OOM in TextLayouter");
        }

        var cursor_x: f32 = 0.0;
        var cursor_y: f32 = 0.0;
        var max_x: f32 = 0.0;
        var truncated = false;
        var stop = false;

        var last_safe_break_x: f32 = 0.0;
        var have_safe_break = false;
        var last_safe_break_metric_idx: usize = 0;

        for (segments.items) |segment| {
            if (stop) break;
            const seg = deriveSegParams(segment.font, target_size, options.font_size);

            c.hb_buffer_clear_contents(self.hb_buffer);
            c.hb_buffer_add_utf8(self.hb_buffer, text.ptr, @intCast(text.len), @intCast(segment.start), @intCast(segment.end - segment.start));
            c.hb_buffer_guess_segment_properties(self.hb_buffer);
            self.shapeBuffer(seg.font.hb_font);

            var glyph_count: u32 = 0;
            const glyph_info = c.hb_buffer_get_glyph_infos(self.hb_buffer, &glyph_count);
            const glyph_pos = c.hb_buffer_get_glyph_positions(self.hb_buffer, &glyph_count);

            var j: usize = 0;
            while (j < glyph_count) : (j += 1) {
                const codepoint = glyph_info[j].codepoint;

                if (self.core) |core| {
                    if (self.font_registry) |reg| {
                        if (seg.use_bitmap) {
                            reg.ensureBitmapGlyph(core, seg.font, codepoint, seg.target_px_u) catch |err| {
                                std.log.err("TextLayouter: failed to ensure bitmap glyph {d}@{d}px: {s}", .{ codepoint, seg.target_px_u, @errorName(err) });
                            };
                        } else {
                            reg.ensureGlyph(core, seg.font, codepoint) catch |err| {
                                std.log.err("TextLayouter: failed to ensure glyph {d}: {s}", .{ codepoint, @errorName(err) });
                            };
                        }
                    }
                }

                const glyph_opt: ?font_module.GlyphInfo = if (seg.use_bitmap)
                    seg.font.bitmap_glyphs.get(font_module.bitmapGlyphKey(codepoint, seg.target_px_u))
                else
                    seg.font.glyphs.get(codepoint);

                const hb_advance = (@as(f32, @floatFromInt(glyph_pos[j].x_advance)) / 64.0) * seg.metric_scale;
                const x_advance: f32 = if (seg.use_bitmap) blk: {
                    if (glyph_opt) |g| break :blk g.advance * seg.glyph_scale;
                    break :blk hb_advance;
                } else hb_advance;
                const cluster = glyph_info[j].cluster;
                const cluster_in_bounds = cluster < text.len;
                const is_space = cluster_in_bounds and text[cluster] == ' ';
                const is_newline = cluster_in_bounds and text[cluster] == '\n';

                const byte_length: usize = if (j + 1 < glyph_count)
                    glyph_info[j + 1].cluster - cluster
                else
                    segment.end - cluster;

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
                    have_safe_break = false;
                    continue;
                }

                if (is_space) {
                    have_safe_break = true;
                    last_safe_break_x = cursor_x + x_advance;
                    last_safe_break_metric_idx = metrics.items.len;
                }

                if (wrap_enabled and cursor_x + x_advance > max_width) {
                    if (have_safe_break and last_safe_break_metric_idx < metrics.items.len) {
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
                        have_safe_break = false;
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
                            stop = true;
                            break;
                        }
                        if (cursor_x + x_advance > max_width - ellipsis_width and j + 1 < glyph_count) {
                            truncated = true;
                            stop = true;
                            break;
                        }
                    } else if (clip_enabled and cursor_x + x_advance > max_width) {
                        stop = true;
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
                    render_x = cursor_x + (@as(f32, @floatFromInt(glyph_pos[j].x_offset)) / 64.0) * seg.metric_scale + glyph.bearing[0] * seg.glyph_scale;
                    render_y = cursor_y + (@as(f32, @floatFromInt(glyph_pos[j].y_offset)) / 64.0) * seg.metric_scale - glyph.bearing[1] * seg.glyph_scale + ascender_target;
                    render_w = glyph.size[0] * seg.glyph_scale;
                    render_h = glyph.size[1] * seg.glyph_scale;
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
                    .atlas_id = seg.atlas_id,
                    .effect = seg.effect,
                    .sdf_padding = seg.sdf_padding,
                }) catch @panic("OOM in TextLayouter");

                cursor_x += x_advance;
            }
        }

        if (ellipsis_enabled and truncated) {
            const dot_glyph: ?font_module.GlyphInfo = if (primary.use_bitmap)
                font_data.bitmap_glyphs.get(font_module.bitmapGlyphKey(dot_glyph_id, primary.target_px_u))
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
                    render_x = cursor_x + glyph.bearing[0] * primary.glyph_scale;
                    render_y = cursor_y - glyph.bearing[1] * primary.glyph_scale + ascender_target;
                    render_w = glyph.size[0] * primary.glyph_scale;
                    render_h = glyph.size[1] * primary.glyph_scale;
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
                    .atlas_id = primary.atlas_id,
                    .effect = primary.effect,
                    .sdf_padding = primary.sdf_padding,
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
                .is_bitmap = primary.use_bitmap,
            };
        }

        const owned_metrics = allocator.alloc(GlyphMetric, metrics.items.len) catch @panic("OOM in TextLayouter");
        @memcpy(owned_metrics, metrics.items);

        return .{
            .width = max_x,
            .height = final_height,
            .metrics = owned_metrics,
            .is_bitmap = primary.use_bitmap,
        };
    }

    pub fn deinit(self: *TextLayouter) void {
        self.measure_cache.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        c.hb_buffer_destroy(self.hb_buffer);
    }
};
