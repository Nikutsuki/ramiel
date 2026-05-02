const std = @import("std");
const Core = @import("../vulkan/core.zig").Core;
const TextureRegistry = @import("../vulkan/texture_registry.zig").TextureRegistry;
const stb_image = @import("../../thirdparty/stb_image/stb_image.zig").c;
const svg_decoder = @import("svg_decoder.zig");
const icon_id = @import("id.zig");

pub const IconId = icon_id.IconId;
pub const TextureHandle = u32;

const ScaleBucket = u16;
const MAX_ICON_BYTES: usize = 10 * 1024 * 1024;
const MAX_SCALE_VARIANTS_PER_ICON: usize = 8;

const ScaleVariant = struct {
    bucket: ScaleBucket,
    handle: TextureHandle,
};

const VariantArray = struct {
    items: [MAX_SCALE_VARIANTS_PER_ICON]ScaleVariant = undefined,
    len: u8 = 0,

    fn slice(self: *VariantArray) []ScaleVariant {
        return self.items[0..self.len];
    }

    fn constSlice(self: *const VariantArray) []const ScaleVariant {
        return self.items[0..self.len];
    }

    fn append(self: *VariantArray, value: ScaleVariant) !void {
        if (self.len >= MAX_SCALE_VARIANTS_PER_ICON) return error.TooManyScaleVariants;
        self.items[self.len] = value;
        self.len += 1;
    }
};

pub const IconRegistry = struct {
    allocator: std.mem.Allocator,
    core: *const Core,
    texture_registry: *TextureRegistry,
    handles: std.AutoHashMap(IconId, VariantArray),
    dynamic_sequence: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
    ) IconRegistry {
        return .{
            .allocator = allocator,
            .core = core,
            .texture_registry = texture_registry,
            .handles = std.AutoHashMap(IconId, VariantArray).init(allocator),
            .dynamic_sequence = 0,
        };
    }

    pub fn deinit(self: *IconRegistry) void {
        var it = self.handles.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.constSlice()) |variant| {
                self.texture_registry.freeManagedTexture(self.core, variant.handle);
            }
        }
        self.handles.deinit();
    }

    pub fn loadStaticSvg(
        self: *IconRegistry,
        icon_id_value: IconId,
        path: []const u8,
        target_width: u32,
        target_height: u32,
        scale: f32,
    ) !void {
        std.debug.assert(!icon_id.isDynamic(icon_id_value));
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buffer = try file.readToEndAlloc(self.allocator, MAX_ICON_BYTES);
        defer self.allocator.free(buffer);

        try self.loadStaticSvgFromMemory(
            icon_id_value,
            buffer,
            target_width,
            target_height,
            scale,
        );
    }

    pub fn loadStaticSvgFromMemory(
        self: *IconRegistry,
        icon_id_value: IconId,
        svg_data: []const u8,
        target_width: u32,
        target_height: u32,
        scale: f32,
    ) !void {
        std.debug.assert(!icon_id.isDynamic(icon_id_value));
        var pixel_buf = try svg_decoder.decodeFromMemory(
            self.allocator,
            svg_data,
            target_width,
            target_height,
        );
        defer pixel_buf.deinit(self.allocator);

        const handle = try self.texture_registry.uploadManagedRgba(
            self.core,
            pixel_buf.pixels,
            pixel_buf.width,
            pixel_buf.height,
        );

        errdefer self.texture_registry.freeManagedTexture(self.core, handle);
        try self.insertVariant(icon_id_value, scale, handle);
    }

    pub fn loadStaticPng(
        self: *IconRegistry,
        icon_id_value: IconId,
        path: []const u8,
        scale: f32,
    ) !void {
        std.debug.assert(!icon_id.isDynamic(icon_id_value));
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buffer = try file.readToEndAlloc(self.allocator, MAX_ICON_BYTES);
        defer self.allocator.free(buffer);

        try self.loadStaticPngFromMemory(icon_id_value, buffer, scale);
    }

    pub fn loadStaticPngFromMemory(
        self: *IconRegistry,
        icon_id_value: IconId,
        png_data: []const u8,
        scale: f32,
    ) !void {
        std.debug.assert(!icon_id.isDynamic(icon_id_value));
        try self.loadPngFromMemoryUnchecked(icon_id_value, png_data, scale);
    }

    pub fn loadRuntimePng(
        self: *IconRegistry,
        path: []const u8,
        scale: f32,
    ) !IconId {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buffer = try file.readToEndAlloc(self.allocator, MAX_ICON_BYTES);
        defer self.allocator.free(buffer);

        const allocated_id = try self.allocateDynamicId();
        try self.loadPngFromMemoryUnchecked(allocated_id, buffer, scale);
        return allocated_id;
    }

    pub fn free(self: *IconRegistry, icon_id_value: IconId) void {
        if (!icon_id.isDynamic(icon_id_value)) return;
        if (self.handles.fetchRemove(icon_id_value)) |entry| {
            for (entry.value.constSlice()) |variant| {
                self.texture_registry.freeManagedTexture(self.core, variant.handle);
            }
        }
    }

    pub fn get(self: *const IconRegistry, icon_id_value: IconId, scale: f32) ?TextureHandle {
        const variants = self.handles.get(icon_id_value) orelse return null;
        const requested_bucket = quantizeScale(scale);
        var best_bucket: ?ScaleBucket = null;
        var best_tex: ?TextureHandle = null;
        var best_delta: u32 = std.math.maxInt(u32);

        for (variants.constSlice()) |variant| {
            if (variant.bucket == requested_bucket) return variant.handle;
            const bucket = variant.bucket;
            const delta: u32 = if (bucket >= requested_bucket)
                @as(u32, bucket - requested_bucket)
            else
                @as(u32, requested_bucket - bucket);

            if (delta < best_delta or
                (delta == best_delta and best_bucket != null and bucket > best_bucket.?))
            {
                best_delta = delta;
                best_bucket = bucket;
                best_tex = variant.handle;
            }
        }

        return best_tex;
    }

    fn allocateDynamicId(self: *IconRegistry) !IconId {
        if (self.dynamic_sequence > icon_id.STATIC_MASK) {
            return error.DynamicIconIdExhausted;
        }
        const allocated_id = icon_id.makeDynamicId(self.dynamic_sequence);
        self.dynamic_sequence += 1;
        return allocated_id;
    }

    fn loadPngFromMemoryUnchecked(
        self: *IconRegistry,
        icon_id_value: IconId,
        png_data: []const u8,
        scale: f32,
    ) !void {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;

        const pixels = stb_image.stbi_load_from_memory(
            png_data.ptr,
            @intCast(png_data.len),
            &width,
            &height,
            &channels,
            4,
        );
        if (pixels == null) return error.ImageLoadFailed;
        defer stb_image.stbi_image_free(pixels);

        const data_len: usize = @intCast(width * height * 4);
        const data_slice = pixels[0..data_len];

        const handle = try self.texture_registry.uploadManagedRgba(
            self.core,
            data_slice,
            @intCast(width),
            @intCast(height),
        );

        errdefer self.texture_registry.freeManagedTexture(self.core, handle);
        try self.insertVariant(icon_id_value, scale, handle);
    }

    fn insertVariant(self: *IconRegistry, icon_id_value: IconId, scale: f32, handle: TextureHandle) !void {
        const bucket = quantizeScale(scale);
        const gop = try self.handles.getOrPut(icon_id_value);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        for (gop.value_ptr.slice()) |*variant| {
            if (variant.bucket == bucket) {
                self.texture_registry.freeManagedTexture(self.core, variant.handle);
                variant.handle = handle;
                return;
            }
        }

        try gop.value_ptr.append(.{
            .bucket = bucket,
            .handle = handle,
        });
    }

    fn quantizeScale(scale: f32) ScaleBucket {
        const clamped = std.math.clamp(scale, 0.25, 8.0);
        return @intFromFloat(@round(clamped * 100.0));
    }
};
