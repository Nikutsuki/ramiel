const std = @import("std");
const vk = @import("../../vk.zig");
const Core = @import("../vulkan/core.zig").Core;
const Texture = @import("../vulkan/texture.zig").Texture;
const TextureRegistry = @import("../vulkan/texture_registry.zig").TextureRegistry;
const ShelfAllocator = @import("./shelf_allocator.zig").ShelfAllocator;
const Buffer = @import("../vulkan/buffer.zig").Buffer;

const vk_common = @import("../vulkan/vk_common.zig").c;

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});

extern fn msdfgen_generate_glyph_rgba(
    ft_face: c.FT_Face,
    glyph_index: c_uint,
    width: c_int,
    height: c_int,
    bearing_x: f64,
    bearing_y: f64,
    px_range: f64,
    shape_scale: f64,
    out_rgba: [*]u8,
) c_int;

pub const FontSource = union(enum) {
    memory: []const u8,
    path: [:0]const u8,
};

pub const GlyphInfo = struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    size: [2]f32,
    bearing: [2]f32,
    advance: f32,
};

pub const FontData = struct {
    ft_face: c.FT_Face,
    ft_face_bitmap: c.FT_Face,
    hb_font: *c.hb_font_t,
    atlas_texture: Texture,
    atlas_tex_id: u32,
    glyphs: std.AutoHashMap(u32, GlyphInfo),
    allocator: ShelfAllocator,

    bitmap_atlas_texture: Texture,
    bitmap_atlas_tex_id: u32,
    /// Key packs `(pixel_size << 32) | glyph_index`.
    bitmap_glyphs: std.AutoHashMap(u64, GlyphInfo),
    bitmap_allocator: ShelfAllocator,
    /// Last pixel size set on `ft_face_bitmap`. Avoids redundant FT_Set_Pixel_Sizes.
    bitmap_face_px: u32,

    line_height: f32,
    ascender: f32,
    descender: f32,
    sdf_padding: f32,
    base_size: f32,

    pub fn deinit(self: *FontData, core: *const Core) void {
        self.glyphs.deinit();
        self.bitmap_glyphs.deinit();
        self.atlas_texture.deinit(core);
        self.bitmap_atlas_texture.deinit(core);
        c.hb_font_destroy(self.hb_font);
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_Face(self.ft_face_bitmap);
    }
};

pub inline fn bitmapGlyphKey(glyph_index: u32, pixel_size: u32) u64 {
    return (@as(u64, pixel_size) << 32) | @as(u64, glyph_index);
}

pub const PendingCopy = struct {
    image: vk.Image,
    region: vk.BufferImageCopy,
};

pub const FontRegistry = struct {
    allocator: std.mem.Allocator,

    ft_library: c.FT_Library,

    fonts: std.StringHashMap(FontData),

    staging_buffer: ?Buffer = null,
    staging_offset: vk.DeviceSize = 0,
    pending_copies: std.ArrayList(PendingCopy),

    pub fn init(allocator: std.mem.Allocator) !FontRegistry {
        var ft_library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;

        return FontRegistry{
            .allocator = allocator,
            .ft_library = ft_library,
            .fonts = std.StringHashMap(FontData).init(allocator),
            .pending_copies = std.ArrayList(PendingCopy).empty,
            .staging_buffer = null,
            .staging_offset = 0,
        };
    }

    fn openFace(self: *FontRegistry, source: FontSource) !c.FT_Face {
        var face: c.FT_Face = undefined;
        switch (source) {
            .memory => {
                const mem = source.memory;
                if (c.FT_New_Memory_Face(self.ft_library, mem.ptr, @intCast(mem.len), 0, &face) != 0) {
                    return error.FontLoadFailed;
                }
            },
            .path => {
                if (c.FT_New_Face(self.ft_library, source.path.ptr, 0, &face) != 0) {
                    return error.FontLoadFailed;
                }
            },
        }
        return face;
    }

    pub fn loadFont(
        self: *FontRegistry,
        core: *const Core,
        texture_registry: *TextureRegistry,
        name: []const u8,
        source: FontSource,
        base_resolution: u32,
    ) !void {
        const face = try self.openFace(source);
        errdefer _ = c.FT_Done_Face(face);

        const face_bitmap = try self.openFace(source);
        errdefer _ = c.FT_Done_Face(face_bitmap);

        _ = c.FT_Set_Pixel_Sizes(face, 0, base_resolution);

        const metrics = face.*.size.*.metrics;
        const ft_line_height = @as(f32, @floatFromInt(metrics.height)) / 64.0;
        const ft_ascender = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
        const ft_descender = @as(f32, @floatFromInt(metrics.descender)) / 64.0;

        const sdf_padding = @max(2.0, @as(f32, @floatFromInt(base_resolution)) * 0.25);

        const hb_font = c.hb_ft_font_create(face, null) orelse return error.HarfBuzzFontCreationFailed;
        c.hb_ft_font_set_load_flags(hb_font, c.FT_LOAD_DEFAULT);

        var line_height = ft_line_height;
        var ascender = ft_ascender;
        var descender = ft_descender;

        var hb_extents: c.hb_font_extents_t = undefined;
        if (c.hb_font_get_h_extents(hb_font, &hb_extents) != 0) {
            const hb_ascender = @as(f32, @floatFromInt(hb_extents.ascender)) / 64.0;
            const hb_descender = @as(f32, @floatFromInt(hb_extents.descender)) / 64.0;
            const hb_line_height = @as(f32, @floatFromInt(hb_extents.ascender - hb_extents.descender + hb_extents.line_gap)) / 64.0;

            ascender = hb_ascender;
            descender = hb_descender;
            line_height = @max(hb_line_height, hb_ascender - hb_descender);
        }

        const atlas_width: u32 = 2048;
        const atlas_height: u32 = 2048;

        const empty_pixels = try self.allocator.alloc(u8, atlas_width * atlas_height * 4);
        defer self.allocator.free(empty_pixels);
        @memset(empty_pixels, 0);

        const atlas_texture = try Texture.init(core, atlas_width, atlas_height, empty_pixels);
        const bitmap_atlas_texture = try Texture.init(core, atlas_width, atlas_height, empty_pixels);

        const glyphs = std.AutoHashMap(u32, GlyphInfo).init(self.allocator);
        const bitmap_glyphs = std.AutoHashMap(u64, GlyphInfo).init(self.allocator);

        const atlas_tex_id = texture_registry.registerRawView(atlas_texture.view);
        const bitmap_atlas_tex_id = texture_registry.registerRawView(bitmap_atlas_texture.view);

        try self.fonts.put(name, FontData{
            .ft_face = face,
            .ft_face_bitmap = face_bitmap,
            .hb_font = hb_font,
            .atlas_texture = atlas_texture,
            .atlas_tex_id = atlas_tex_id,
            .glyphs = glyphs,
            .allocator = ShelfAllocator.init(atlas_width, atlas_height),

            .bitmap_atlas_texture = bitmap_atlas_texture,
            .bitmap_atlas_tex_id = bitmap_atlas_tex_id,
            .bitmap_glyphs = bitmap_glyphs,
            .bitmap_allocator = ShelfAllocator.init(atlas_width, atlas_height),
            .bitmap_face_px = 0,

            .line_height = line_height,
            .ascender = ascender,
            .descender = descender,
            .sdf_padding = sdf_padding,
            .base_size = @as(f32, @floatFromInt(base_resolution)),
        });
    }

    pub fn ensureGlyph(self: *FontRegistry, core: *const Core, font_data: *FontData, glyph_index: u32) !void {
        if (font_data.glyphs.contains(glyph_index)) return;

        if (c.FT_Load_Glyph(font_data.ft_face, glyph_index, c.FT_LOAD_DEFAULT) != 0) return error.FTLoadFailed;

        const glyph_metrics = font_data.ft_face.*.glyph.*.metrics;
        const glyph_width_px = @max(@as(f32, @floatFromInt(glyph_metrics.width)) / 64.0, 1.0);
        const glyph_height_px = @max(@as(f32, @floatFromInt(glyph_metrics.height)) / 64.0, 1.0);

        const glyph_w: u32 = @intFromFloat(@ceil(glyph_width_px + 2.0 * font_data.sdf_padding));
        const glyph_h: u32 = @intFromFloat(@ceil(glyph_height_px + 2.0 * font_data.sdf_padding));

        const bearing_x = @as(f32, @floatFromInt(glyph_metrics.horiBearingX)) / 64.0 - font_data.sdf_padding;
        const bearing_y = @as(f32, @floatFromInt(glyph_metrics.horiBearingY)) / 64.0 + font_data.sdf_padding;

        const margin = 1;
        const pos = font_data.allocator.allocate(glyph_w + margin, glyph_h + margin) orelse {
            @panic("Atlas is full. Eviction not implemented.");
        };

        const dest_x = pos[0];
        const dest_y = pos[1];

        if (self.staging_buffer == null) {
            const staging_size = 4 * 1024 * 1024; // 4MB
            self.staging_buffer = try Buffer.init(
                core,
                staging_size,
                .{ .transfer_src_bit = true },
                vk_common.VMA_MEMORY_USAGE_CPU_ONLY,
                @intCast(vk_common.VMA_ALLOCATION_CREATE_MAPPED_BIT),
            );
        }

        const buffer_size: vk.DeviceSize = glyph_w * glyph_h * 4;

        const shape_scale = @as(f64, @floatCast(font_data.base_size)) / @as(f64, @floatFromInt(font_data.ft_face.*.units_per_EM));

        self.staging_offset = std.mem.alignForward(vk.DeviceSize, self.staging_offset, 4);

        if (self.staging_offset + buffer_size > self.staging_buffer.?.size) {
            @panic("Font staging buffer overflow. Frame generated too many new glyphs.");
        }

        const mapped_ptr = @as([*]u8, @ptrCast(self.staging_buffer.?.mapped_ptr.?))[self.staging_offset..];

        const msdf_ok = msdfgen_generate_glyph_rgba(
            font_data.ft_face,
            glyph_index,
            @intCast(glyph_w),
            @intCast(glyph_h),
            @as(f64, @floatCast(bearing_x)),
            @as(f64, @floatCast(bearing_y)),
            @as(f64, @floatCast(font_data.sdf_padding)),
            shape_scale,
            mapped_ptr,
        ) != 0;

        if (!msdf_ok) {
            @memset(mapped_ptr[0..buffer_size], 0);
        }

        try self.pending_copies.append(self.allocator, .{ .image = font_data.atlas_texture.image, .region = .{
            .buffer_offset = self.staging_offset,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = @intCast(dest_x), .y = @intCast(dest_y), .z = 0 },
            .image_extent = .{ .width = glyph_w, .height = glyph_h, .depth = 1 },
        } });

        self.staging_offset += buffer_size;

        const atlas_width = @as(f32, @floatFromInt(font_data.atlas_texture.width));
        const atlas_height = @as(f32, @floatFromInt(font_data.atlas_texture.height));

        try font_data.glyphs.put(glyph_index, GlyphInfo{
            .uv_min = .{ @as(f32, @floatFromInt(dest_x)) / atlas_width, @as(f32, @floatFromInt(dest_y)) / atlas_height },
            .uv_max = .{ @as(f32, @floatFromInt(dest_x + glyph_w)) / atlas_width, @as(f32, @floatFromInt(dest_y + glyph_h)) / atlas_height },
            .size = .{ @as(f32, @floatFromInt(glyph_w)), @as(f32, @floatFromInt(glyph_h)) },
            .bearing = .{ bearing_x, bearing_y },
            .advance = @as(f32, @floatFromInt(font_data.ft_face.*.glyph.*.advance.x >> 6)),
        });
    }

    pub fn ensureBitmapGlyph(
        self: *FontRegistry,
        core: *const Core,
        font_data: *FontData,
        glyph_index: u32,
        pixel_size: u32,
    ) !void {
        const key = bitmapGlyphKey(glyph_index, pixel_size);
        if (font_data.bitmap_glyphs.contains(key)) return;

        if (font_data.bitmap_face_px != pixel_size) {
            if (c.FT_Set_Pixel_Sizes(font_data.ft_face_bitmap, 0, pixel_size) != 0) return error.FTSetSizeFailed;
            font_data.bitmap_face_px = pixel_size;
        }

        const load_flags: c_int = @as(c_int, c.FT_LOAD_RENDER) | @as(c_int, c.FT_LOAD_TARGET_NORMAL);
        if (c.FT_Load_Glyph(font_data.ft_face_bitmap, glyph_index, load_flags) != 0) return error.FTLoadFailed;

        const slot = font_data.ft_face_bitmap.*.glyph;
        const bitmap = slot.*.bitmap;
        const bw: u32 = bitmap.width;
        const bh: u32 = bitmap.rows;
        const advance_px: f32 = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0;

        if (bw == 0 or bh == 0) {
            try font_data.bitmap_glyphs.put(key, GlyphInfo{
                .uv_min = .{ 0.0, 0.0 },
                .uv_max = .{ 0.0, 0.0 },
                .size = .{ 0.0, 0.0 },
                .bearing = .{ @floatFromInt(slot.*.bitmap_left), @floatFromInt(slot.*.bitmap_top) },
                .advance = advance_px,
            });
            return;
        }

        const margin: u32 = 1;
        const pos = font_data.bitmap_allocator.allocate(bw + margin, bh + margin) orelse {
            @panic("Bitmap atlas is full. Eviction not implemented.");
        };
        const dest_x = pos[0];
        const dest_y = pos[1];

        if (self.staging_buffer == null) {
            const staging_size = 4 * 1024 * 1024; // 4MB
            self.staging_buffer = try Buffer.init(
                core,
                staging_size,
                .{ .transfer_src_bit = true },
                vk_common.VMA_MEMORY_USAGE_CPU_ONLY,
                @intCast(vk_common.VMA_ALLOCATION_CREATE_MAPPED_BIT),
            );
        }

        const buffer_size: vk.DeviceSize = bw * bh * 4;
        self.staging_offset = std.mem.alignForward(vk.DeviceSize, self.staging_offset, 4);

        if (self.staging_offset + buffer_size > self.staging_buffer.?.size) {
            @panic("Font staging buffer overflow. Frame generated too many new glyphs.");
        }

        const mapped_ptr = @as([*]u8, @ptrCast(self.staging_buffer.?.mapped_ptr.?))[self.staging_offset..];

        const src_buffer = bitmap.buffer;
        const pitch: i32 = bitmap.pitch;
        const pitch_abs: u32 = @intCast(if (pitch < 0) -pitch else pitch);
        var row: u32 = 0;
        while (row < bh) : (row += 1) {
            const src_row_index: u32 = if (pitch < 0) (bh - 1 - row) else row;
            const src_row = @as([*]const u8, @ptrCast(src_buffer)) + src_row_index * pitch_abs;
            var col: u32 = 0;
            while (col < bw) : (col += 1) {
                const cov = src_row[col];
                const dst = (row * bw + col) * 4;
                mapped_ptr[dst + 0] = cov;
                mapped_ptr[dst + 1] = cov;
                mapped_ptr[dst + 2] = cov;
                mapped_ptr[dst + 3] = cov;
            }
        }

        try self.pending_copies.append(self.allocator, .{ .image = font_data.bitmap_atlas_texture.image, .region = .{
            .buffer_offset = self.staging_offset,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = @intCast(dest_x), .y = @intCast(dest_y), .z = 0 },
            .image_extent = .{ .width = bw, .height = bh, .depth = 1 },
        } });

        self.staging_offset += buffer_size;

        const atlas_w_f = @as(f32, @floatFromInt(font_data.bitmap_atlas_texture.width));
        const atlas_h_f = @as(f32, @floatFromInt(font_data.bitmap_atlas_texture.height));

        try font_data.bitmap_glyphs.put(key, GlyphInfo{
            .uv_min = .{ @as(f32, @floatFromInt(dest_x)) / atlas_w_f, @as(f32, @floatFromInt(dest_y)) / atlas_h_f },
            .uv_max = .{ @as(f32, @floatFromInt(dest_x + bw)) / atlas_w_f, @as(f32, @floatFromInt(dest_y + bh)) / atlas_h_f },
            .size = .{ @as(f32, @floatFromInt(bw)), @as(f32, @floatFromInt(bh)) },
            .bearing = .{ @floatFromInt(slot.*.bitmap_left), @floatFromInt(slot.*.bitmap_top) },
            .advance = advance_px,
        });
    }

    pub fn flushUploads(self: *FontRegistry, core: *const Core, cmd: vk.CommandBuffer) !void {
        if (self.pending_copies.items.len == 0) return;

        var unique_images = std.AutoHashMap(vk.Image, void).init(self.allocator);
        defer unique_images.deinit();

        for (self.pending_copies.items) |copy| {
            try unique_images.put(copy.image, {});
        }

        var it = unique_images.keyIterator();
        while (it.next()) |img_ptr| {
            try core.transitionImageLayoutCmd(cmd, img_ptr.*, .shader_read_only_optimal, .transfer_dst_optimal);
        }

        it = unique_images.keyIterator();
        while (it.next()) |img_ptr| {
            const img = img_ptr.*;
            var regions = std.ArrayList(vk.BufferImageCopy).empty;
            defer regions.deinit(self.allocator);

            for (self.pending_copies.items) |copy| {
                if (copy.image == img) {
                    try regions.append(self.allocator, copy.region);
                }
            }
            core.vkd.cmdCopyBufferToImage(cmd, self.staging_buffer.?.handle, img, .transfer_dst_optimal, regions.items);
        }

        it = unique_images.keyIterator();
        while (it.next()) |img_ptr| {
            try core.transitionImageLayoutCmd(cmd, img_ptr.*, .transfer_dst_optimal, .shader_read_only_optimal);
        }

        self.staging_offset = 0;
        self.pending_copies.clearRetainingCapacity();
    }

    pub fn deinit(self: *FontRegistry, core: *const Core) void {
        var it = self.fonts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(core);
        }
        self.fonts.deinit();

        if (self.staging_buffer) |*buf| {
            buf.deinit(core);
        }
        self.pending_copies.deinit(self.allocator);

        _ = c.FT_Done_FreeType(self.ft_library);
    }
};
