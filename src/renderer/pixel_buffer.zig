const std = @import("std");
const stb = @import("../thirdparty/stb_image/stb_image.zig");

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    const start = haystack.len - suffix.len;
    for (suffix, 0..) |c, i| {
        if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

pub const PixelBuffer = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    channels: u32 = 4,

    pub fn loadFromFile(allocator: std.mem.Allocator, file_path: [:0]const u8) !PixelBuffer {
        var width: i32 = 0;
        var height: i32 = 0;
        var channels: i32 = 0;

        const raw_data = stb.c.stbi_load(file_path.ptr, &width, &height, &channels, 4);
        if (raw_data == null) return error.ImageDecodeFailed;
        defer stb.c.stbi_image_free(raw_data);

        if (width <= 0 or height <= 0) return error.InvalidImageDimensions;

        const pixel_count = try std.math.mul(usize, @intCast(width), @intCast(height));
        const byte_len = try std.math.mul(usize, pixel_count, 4);
        const pixels = try allocator.alloc(u8, byte_len);
        @memcpy(pixels, raw_data[0..byte_len]);

        return .{
            .allocator = allocator,
            .pixels = pixels,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    pub fn initBlank(allocator: std.mem.Allocator, width: u32, height: u32) !PixelBuffer {
        if (width == 0 or height == 0) return error.InvalidImageDimensions;

        const pixel_count = try std.math.mul(usize, width, height);
        const byte_len = try std.math.mul(usize, pixel_count, 4);
        const pixels = try allocator.alloc(u8, byte_len);
        @memset(pixels, 0);

        return .{
            .allocator = allocator,
            .pixels = pixels,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *PixelBuffer) void {
        self.allocator.free(self.pixels);
    }

    pub fn clone(self: *const PixelBuffer) !PixelBuffer {
        const pixels = try self.allocator.alloc(u8, self.pixels.len);
        @memcpy(pixels, self.pixels);

        return .{
            .allocator = self.allocator,
            .pixels = pixels,
            .width = self.width,
            .height = self.height,
            .channels = self.channels,
        };
    }

    pub fn exportToFile(self: *const PixelBuffer, path: []const u8) !void {
        if (path.len == 0) return error.InvalidPath;
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const w: c_int = @intCast(self.width);
        const h: c_int = @intCast(self.height);
        const channels: c_int = 4;
        const stride: c_int = @intCast(self.width * 4);

        const ok: c_int = if (endsWithIgnoreCase(path, ".png"))
            stb.c.stbi_write_png(path_z.ptr, w, h, channels, self.pixels.ptr, stride)
        else if (endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg"))
            stb.c.stbi_write_jpg(path_z.ptr, w, h, channels, self.pixels.ptr, 95)
        else if (endsWithIgnoreCase(path, ".bmp"))
            stb.c.stbi_write_bmp(path_z.ptr, w, h, channels, self.pixels.ptr)
        else if (endsWithIgnoreCase(path, ".tga"))
            stb.c.stbi_write_tga(path_z.ptr, w, h, channels, self.pixels.ptr)
        else
            return error.UnsupportedImageExtension;

        if (ok == 0) return error.ImageEncodeFailed;
    }
};
