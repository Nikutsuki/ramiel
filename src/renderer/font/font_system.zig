const std = @import("std");
const Core = @import("../vulkan/core.zig").Core;
const TextureRegistry = @import("../vulkan/texture_registry.zig").TextureRegistry;

const font_registry = @import("font_registry.zig");
const FontRegistry = font_registry.FontRegistry;
const FontSource = font_registry.FontSource;
const FontData = font_registry.FontData;
const FontVariant = font_registry.FontVariant;
const FontFamily = font_registry.FontFamily;
const c = font_registry.c;
const TextLayouter = @import("text_layouter.zig").TextLayouter;
const layout = @import("../../ui/layout.zig");

/// Heavy is `>= .semibold`; italic and oblique both go to the italic slot.
pub fn weightAndStyleToVariant(weight: layout.FontWeight, font_style: layout.FontStyle) FontVariant {
    const heavy = @intFromEnum(weight) >= @intFromEnum(layout.FontWeight.semibold);
    const italic_axis = font_style == .italic or font_style == .oblique;
    return switch (italic_axis) {
        false => if (heavy) .bold else .regular,
        true => if (heavy) .bold_italic else .italic,
    };
}

pub const FamilySources = struct {
    regular: ?FontSource = null,
    bold: ?FontSource = null,
    italic: ?FontSource = null,
    bold_italic: ?FontSource = null,

    pub fn get(self: FamilySources, variant: FontVariant) ?FontSource {
        return switch (variant) {
            .regular => self.regular,
            .bold => self.bold,
            .italic => self.italic,
            .bold_italic => self.bold_italic,
        };
    }
};

pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    font_registry: FontRegistry,
    text_layouter: TextLayouter,

    default_fallback_chain: std.ArrayList([]const u8),
    fallback_cache: std.AutoHashMap(u21, []const u8),

    pub fn init(allocator: std.mem.Allocator) !FontSystem {
        return FontSystem{
            .allocator = allocator,
            .font_registry = try FontRegistry.init(allocator),
            .text_layouter = try TextLayouter.init(allocator),
            .default_fallback_chain = std.ArrayList([]const u8).empty,
            .fallback_cache = std.AutoHashMap(u21, []const u8).init(allocator),
        };
    }

    pub fn setDefaultFallbackChain(self: *FontSystem, names: []const []const u8) !void {
        self.default_fallback_chain.clearRetainingCapacity();
        for (names) |name| {
            try self.default_fallback_chain.append(self.allocator, name);
        }
        self.fallback_cache.clearRetainingCapacity();
    }

    pub fn resolveFontForCodepoint(self: *FontSystem, requested_font_name: ?[]const u8, codepoint: u21) []const u8 {
        if (requested_font_name) |req_name| {
            if (self.font_registry.fonts.get(req_name)) |font_data| {
                if (c.FT_Get_Char_Index(font_data.ft_face, codepoint) != 0) {
                    return req_name;
                }
            }
        }

        if (self.fallback_cache.get(codepoint)) |cached_name| {
            return cached_name;
        }

        for (self.default_fallback_chain.items) |fallback_name| {
            if (requested_font_name != null and std.mem.eql(u8, fallback_name, requested_font_name.?)) continue;

            if (self.font_registry.fonts.get(fallback_name)) |font_data| {
                if (c.FT_Get_Char_Index(font_data.ft_face, codepoint) != 0) {
                    self.fallback_cache.put(codepoint, fallback_name) catch {};
                    return fallback_name;
                }
            }
        }

        return requested_font_name orelse if (self.default_fallback_chain.items.len > 0) self.default_fallback_chain.items[0] else "";
    }

    pub fn loadFont(self: *FontSystem, core: *const Core, texture_registry: *TextureRegistry, name: []const u8, source: FontSource, base_resolution: u32) !*FontData {
        self.text_layouter.core = core;
        self.text_layouter.font_registry = &self.font_registry;
        self.text_layouter.font_system = self;

        try self.font_registry.loadFont(core, texture_registry, name, source, base_resolution);
        return self.font_registry.fonts.getPtr(name) orelse return error.FontLookupFailed;
    }

    pub fn loadFontVariant(
        self: *FontSystem,
        core: *const Core,
        texture_registry: *TextureRegistry,
        family_name: []const u8,
        variant: FontVariant,
        physical_name: []const u8,
        source: FontSource,
        base_resolution: u32,
    ) !*FontData {
        const font = try self.loadFont(core, texture_registry, physical_name, source, base_resolution);
        try self.font_registry.registerFamilyVariant(family_name, variant, physical_name);
        return font;
    }

    /// Loads every non-null variant under `family_name`; physical names are
    /// `family_name`, `family_name ++ "_bold"`, etc. Returns the first loaded.
    pub fn loadFontFamily(
        self: *FontSystem,
        core: *const Core,
        texture_registry: *TextureRegistry,
        family_name: []const u8,
        sources: FamilySources,
        base_resolution: u32,
    ) !*FontData {
        var primary: ?*FontData = null;
        const variants = [_]FontVariant{ .regular, .bold, .italic, .bold_italic };
        inline for (variants) |variant| {
            if (sources.get(variant)) |src| {
                const suffix: []const u8 = switch (variant) {
                    .regular => "",
                    .bold => "_bold",
                    .italic => "_italic",
                    .bold_italic => "_bold_italic",
                };
                const physical_name = try std.fmt.allocPrint(self.font_registry.allocator, "{s}{s}", .{ family_name, suffix });
                try self.font_registry.takeName(physical_name);
                const font = try self.loadFontVariant(core, texture_registry, family_name, variant, physical_name, src, base_resolution);
                if (primary == null) primary = font;
            }
        }
        return primary orelse error.FontLookupFailed;
    }

    /// CSS-ish ladder: exact > opposite-italic > opposite-weight > anything.
    pub fn closestVariant(self: *FontSystem, family_name: []const u8, want: FontVariant) ?[]const u8 {
        const family = self.font_registry.getFamily(family_name) orelse return null;
        if (family.get(want)) |n| return n;
        const ladder: []const FontVariant = switch (want) {
            .regular => &.{ .bold, .italic, .bold_italic },
            .bold => &.{ .regular, .bold_italic, .italic },
            .italic => &.{ .regular, .bold_italic, .bold },
            .bold_italic => &.{ .italic, .bold, .regular },
        };
        for (ladder) |v| if (family.get(v)) |n| return n;
        return null;
    }

    pub fn getFont(self: *FontSystem, name: []const u8) ?*FontData {
        return self.font_registry.fonts.getPtr(name);
    }

    pub fn deinit(self: *FontSystem, core: *const Core) void {
        self.default_fallback_chain.deinit(self.allocator);
        self.fallback_cache.deinit();
        self.text_layouter.deinit();
        self.font_registry.deinit(core);
    }
};
