const std = @import("std");
const c = @cImport({
    @cInclude("nanosvg.h");
    @cInclude("nanosvgrast.h");
});

pub const PixelBuffer = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *PixelBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub fn decodeFromMemory(
    allocator: std.mem.Allocator,
    svg_data: []const u8,
    target_width: u32,
    target_height: u32,
) !PixelBuffer {
    if (target_width == 0 or target_height == 0) return error.InvalidTargetSize;

    const data_copy = try allocator.dupeZ(u8, svg_data);
    defer allocator.free(data_copy);

    const image = c.nsvgParse(data_copy.ptr, "px", 96.0);
    if (image == null) return error.ParseFailed;
    defer c.nsvgDelete(image);

    const rasterizer = c.nsvgCreateRasterizer();
    if (rasterizer == null) return error.RasterizerInitFailed;
    defer c.nsvgDeleteRasterizer(rasterizer);

    const iw = if (image.*.width <= 0.0) 1.0 else image.*.width;
    const ih = if (image.*.height <= 0.0) 1.0 else image.*.height;

    const scale_x = @as(f32, @floatFromInt(target_width)) / iw;
    const scale_y = @as(f32, @floatFromInt(target_height)) / ih;
    const scale = @min(scale_x, scale_y);

    const buffer_size = @as(usize, target_width) * @as(usize, target_height) * 4;
    const pixels = try allocator.alloc(u8, buffer_size);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    c.nsvgRasterize(
        rasterizer,
        image,
        0,
        0,
        scale,
        @ptrCast(pixels.ptr),
        @intCast(target_width),
        @intCast(target_height),
        @intCast(target_width * 4),
    );

    return .{
        .pixels = pixels,
        .width = target_width,
        .height = target_height,
    };
}
