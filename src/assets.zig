const std = @import("std");

pub const TEXTURE_INDEX_MASK: u32 = 0x0000FFFF;
pub const EFFECT_MASK: u32 = 0xFFFF0000;

pub const EFFECT_SDF_ROUNDED: u32 = 1 << 16;
pub const EFFECT_BACKDROP_BLUR: u32 = 1 << 17;
pub const EFFECT_MSDF_TEXT: u32 = 1 << 18;
pub const EFFECT_ELEMENT_BLUR: u32 = 1 << 19;
pub const EFFECT_BITMAP_TEXT: u32 = 1 << 20;
pub const EFFECT_COLOR_GLYPH: u32 = 1 << 21;
pub const EFFECT_DECORATION_LINE: u32 = 1 << 22;

pub const NO_TEXTURE: u32 = 0xFFFF;

pub const TextureId = enum {
    blank_canvas,
    blur_material,
    sdf,
    text,
};

pub fn getTextureData(id: TextureId) []const u8 {
    return switch (id) {
        .blank_canvas => &[_]u8{ 255, 255, 255, 255 },
        .blur_material => unreachable,
        .sdf => unreachable,
        .text => unreachable,
    };
}

pub const FontId = enum {
    jetbrains_mono,
    jetbrains_mono_bold,
    jetbrains_mono_italic,
    jetbrains_mono_bold_italic,
};

pub fn getFontData(id: FontId) []const u8 {
    return switch (id) {
        .jetbrains_mono => @embedFile("assets/fonts/jetbrains_mono.ttf"),
        .jetbrains_mono_bold => @embedFile("assets/fonts/jetbrains_mono_bold.ttf"),
        .jetbrains_mono_italic => @embedFile("assets/fonts/jetbrains_mono_italic.ttf"),
        .jetbrains_mono_bold_italic => @embedFile("assets/fonts/jetbrains_mono_bold_italic.ttf"),
    };
}

/// Pass to `app.loadDefaultFontFamily("JetBrains Mono", ..., 32)`.
pub fn jetbrainsMonoSources() @import("renderer/font/font_system.zig").FamilySources {
    return .{
        .regular = .{ .memory = getFontData(.jetbrains_mono) },
        .bold = .{ .memory = getFontData(.jetbrains_mono_bold) },
        .italic = .{ .memory = getFontData(.jetbrains_mono_italic) },
        .bold_italic = .{ .memory = getFontData(.jetbrains_mono_bold_italic) },
    };
}

pub const StaticAssetPayload = union(enum) {
    image: []const u8,
    font: struct { bytes: []const u8, size: u32 },
    audio: []const u8,
    icon_svg: struct { bytes: []const u8, width: u32, height: u32, scale: f32 },
    icon_png: struct { bytes: []const u8, scale: f32 },
};

pub const StaticAsset = struct {
    name: [:0]const u8,
    payload: StaticAssetPayload,
};
