const std = @import("std");
const c = @import("../vulkan/vk_common.zig").c;
const AnimatedState = @import("../image_animation.zig").AnimatedState;
const FrameMetadata = @import("../image_animation.zig").FrameMetadata;

pub const DecodedGif = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    animation: AnimatedState,

    pub fn deinit(self: *DecodedGif, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.animation.deinit(allocator);
    }
};

pub fn isGifPayload(bytes: []const u8) bool {
    return bytes.len >= 6 and std.mem.eql(u8, bytes[0..3], "GIF");
}

pub fn decodeToAtlas(allocator: std.mem.Allocator, bytes: []const u8) !DecodedGif {
    var delays_ptr: [*c]c_int = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var z: c_int = 0;
    var ch: c_int = 0;

    const pixels_c = c.stbi_load_gif_from_memory(
        bytes.ptr,
        @intCast(bytes.len),
        &delays_ptr,
        &w,
        &h,
        &z,
        &ch,
        4,
    );
    if (pixels_c == null) return error.GifDecodeFailed;
    defer c.stbi_image_free(pixels_c);
    defer if (delays_ptr != null) c.stbi_image_free(delays_ptr);

    const frame_count: u32 = @intCast(@max(1, z));
    const src_w: u32 = @intCast(w);
    const src_h: u32 = @intCast(h);
    if (src_w == 0 or src_h == 0) return error.GifDecodeFailed;

    const sqrt_count: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(frame_count)))));
    const cols: u32 = @max(1, sqrt_count);
    const rows: u32 = (frame_count + cols - 1) / cols;

    const MAX_ATLAS_DIM: u32 = 8192;
    var frame_w: u32 = src_w;
    var frame_h: u32 = src_h;
    const needed_w: u32 = cols * src_w;
    const needed_h: u32 = rows * src_h;
    if (needed_w > MAX_ATLAS_DIM or needed_h > MAX_ATLAS_DIM) {
        const scale_w: f64 = @as(f64, @floatFromInt(MAX_ATLAS_DIM)) / @as(f64, @floatFromInt(needed_w));
        const scale_h: f64 = @as(f64, @floatFromInt(MAX_ATLAS_DIM)) / @as(f64, @floatFromInt(needed_h));
        const scale = @min(scale_w, scale_h);
        frame_w = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(src_w)) * scale))));
        frame_h = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(src_h)) * scale))));
    }

    const atlas_w: u32 = cols * frame_w;
    const atlas_h: u32 = rows * frame_h;

    const atlas_bytes: usize = @as(usize, atlas_w) * @as(usize, atlas_h) * 4;
    const atlas_pixels = try allocator.alloc(u8, atlas_bytes);
    errdefer allocator.free(atlas_pixels);
    @memset(atlas_pixels, 0);

    const src_frame_stride: usize = @as(usize, src_w) * @as(usize, src_h) * 4;
    const src_row_stride: usize = @as(usize, src_w) * 4;
    const frame_row_stride: usize = @as(usize, frame_w) * 4;
    const dst_row_stride: usize = @as(usize, atlas_w) * 4;

    const needs_resize = frame_w != src_w or frame_h != src_h;
    const frame_scratch: ?[]u8 = if (needs_resize)
        try allocator.alloc(u8, @as(usize, frame_w) * @as(usize, frame_h) * 4)
    else
        null;
    defer if (frame_scratch) |scratch| allocator.free(scratch);

    const frames = try allocator.alloc(FrameMetadata, frame_count);
    errdefer allocator.free(frames);

    const atlas_w_f: f32 = @floatFromInt(atlas_w);
    const atlas_h_f: f32 = @floatFromInt(atlas_h);
    const frame_w_f: f32 = @floatFromInt(frame_w);
    const frame_h_f: f32 = @floatFromInt(frame_h);

    var total_duration_ms: u32 = 0;
    var i: u32 = 0;
    while (i < frame_count) : (i += 1) {
        const col = i % cols;
        const row = i / cols;
        const dst_x_px: usize = @as(usize, col) * @as(usize, frame_w);
        const dst_y_px: usize = @as(usize, row) * @as(usize, frame_h);

        const src_frame_base: usize = @as(usize, i) * src_frame_stride;
        const frame_src: [*c]const u8 = pixels_c + src_frame_base;

        if (needs_resize) {
            const scratch = frame_scratch.?;
            const resize_result = c.stbir_resize_uint8_linear(
                frame_src,
                @intCast(src_w),
                @intCast(src_h),
                0,
                scratch.ptr,
                @intCast(frame_w),
                @intCast(frame_h),
                0,
                c.STBIR_RGBA,
            );
            if (resize_result == null) return error.GifFrameResizeFailed;

            var y_row: usize = 0;
            while (y_row < frame_h) : (y_row += 1) {
                const src_off = y_row * frame_row_stride;
                const dst_off = (dst_y_px + y_row) * dst_row_stride + dst_x_px * 4;
                @memcpy(atlas_pixels[dst_off .. dst_off + frame_row_stride], scratch[src_off .. src_off + frame_row_stride]);
            }
        } else {
            var y_row: usize = 0;
            while (y_row < frame_h) : (y_row += 1) {
                const src_off = y_row * src_row_stride;
                const dst_off = (dst_y_px + y_row) * dst_row_stride + dst_x_px * 4;
                @memcpy(atlas_pixels[dst_off .. dst_off + frame_row_stride], frame_src[src_off .. src_off + frame_row_stride]);
            }
        }

        const raw_delay: u32 = if (delays_ptr != null) @intCast(@max(0, delays_ptr[i])) else 100;
        const delay_ms: u32 = @max(20, raw_delay);
        total_duration_ms += delay_ms;

        const u_min: f32 = @as(f32, @floatFromInt(dst_x_px)) / atlas_w_f;
        const v_min: f32 = @as(f32, @floatFromInt(dst_y_px)) / atlas_h_f;
        const u_max: f32 = (@as(f32, @floatFromInt(dst_x_px)) + frame_w_f) / atlas_w_f;
        const v_max: f32 = (@as(f32, @floatFromInt(dst_y_px)) + frame_h_f) / atlas_h_f;

        frames[i] = .{
            .uv_min = .{ u_min, v_min },
            .uv_max = .{ u_max, v_max },
            .delay_ms = delay_ms,
        };
    }

    if (total_duration_ms == 0) total_duration_ms = frame_count * 100;

    return .{
        .pixels = atlas_pixels,
        .width = atlas_w,
        .height = atlas_h,
        .animation = .{
            .frames = frames,
            .total_duration_ms = total_duration_ms,
        },
    };
}
