const std = @import("std");
const Core = @import("../vulkan/core.zig").Core;
const TextureRegistry = @import("../vulkan/texture_registry.zig").TextureRegistry;

const font_registry = @import("font_registry.zig");
const FontRegistry = font_registry.FontRegistry;
const FontSource = font_registry.FontSource;
const FontData = font_registry.FontData;
const c = font_registry.c;
const TextLayouter = @import("text_layouter.zig").TextLayouter;

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
