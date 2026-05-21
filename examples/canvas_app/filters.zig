const std = @import("std");
const lib = @import("ramiel");

pub const FilterKind = enum {
    invert,
    dilation,
    erosion,
    displacement,
    subtract,
    kuwahara,
    dither_bayer,
    pixel_sort_h,
    chromatic_aberration,
    mask_luma,
    mask_r,
    mask_g,
    mask_b,
    mask_contrast,
    mask_edge,
    restore,
    gpu_grayscale,
    gpu_invert,
    gpu_edge,
    gpu_emboss,
};

pub fn isGpuFilter(kind: FilterKind) bool {
    return switch (kind) {
        .gpu_grayscale, .gpu_invert, .gpu_edge, .gpu_emboss => true,
        else => false,
    };
}

pub fn gpuShaderSource(kind: FilterKind) []const u8 {
    return switch (kind) {
        .gpu_grayscale => @embedFile("shaders/grayscale.comp"),
        .gpu_invert => @embedFile("shaders/invert.comp"),
        .gpu_edge => @embedFile("shaders/edge.comp"),
        .gpu_emboss => @embedFile("shaders/emboss.comp"),
        else => "",
    };
}

pub const FilterContext = struct {
    width: u32,
    height: u32,
    input: []const u8,
    mask: ?[]const u8,
    aux: ?[]const u8,
    output: []u8,
    parameters: []const f32,
};

pub const FilterFn = *const fn (ctx: FilterContext) void;

pub fn getFilter(kind: FilterKind) FilterFn {
    return switch (kind) {
        .invert => applyInvert,
        .dilation => applyDilation,
        .erosion => applyErosion,
        .displacement => applyDisplacement,
        .subtract => applySubtract,
        .kuwahara => applyKuwahara,
        .dither_bayer => applyDitherBayer,
        .pixel_sort_h => applyPixelSort,
        .chromatic_aberration => applyChromaticAberration,
        .mask_luma => applyLumaMask,
        .mask_r => applyMaskR,
        .mask_g => applyMaskG,
        .mask_b => applyMaskB,
        .mask_contrast => applyMaskContrast,
        .mask_edge => applyMaskEdge,
        .restore => applyRestore,
        .gpu_grayscale, .gpu_invert, .gpu_edge, .gpu_emboss => applyGpuPassthrough,
    };
}

fn applyGpuPassthrough(ctx: FilterContext) void {
    @memcpy(ctx.output, ctx.input);
}

pub const ParamType = enum { slider, radio, palette_editor };

pub const ParamDef = struct {
    name: []const u8,
    kind: ParamType,
    min: f32 = 0.0,
    max: f32 = 1.0,
    options: ?[]const []const u8 = null,
};

pub const SerializeFn = *const fn (state: *const anyopaque, buffer: []f32) usize;

pub const FilterMeta = struct {
    name: []const u8,
    params: []const ParamDef,
    serializeFn: ?SerializeFn = null,
};

fn serializeDither(state_opaque: *const anyopaque, buffer: []f32) usize {
    const EditorState = @import("editor_state.zig").EditorState;
    const state: *const EditorState = @ptrCast(@alignCast(state_opaque));
    if (buffer.len < 2) return 0;

    buffer[0] = state.filter_params[0];
    const max_colors = (buffer.len - 2) / 3;
    const color_count = @min(state.dither_palette_hsv.items.len, max_colors);
    buffer[1] = @floatFromInt(color_count);

    var i: usize = 0;
    while (i < color_count) : (i += 1) {
        const hsv = state.dither_palette_hsv.items[i];
        const rgb = lib.Color.hsvToRgb(hsv[0], hsv[1], hsv[2]);
        buffer[2 + i * 3] = rgb[0] * 255.0;
        buffer[2 + i * 3 + 1] = rgb[1] * 255.0;
        buffer[2 + i * 3 + 2] = rgb[2] * 255.0;
    }
    return 2 + (color_count * 3);
}

fn serializeMaskThresholdFromParam1(state_opaque: *const anyopaque, buffer: []f32) usize {
    const EditorState = @import("editor_state.zig").EditorState;
    const state: *const EditorState = @ptrCast(@alignCast(state_opaque));
    if (buffer.len == 0) return 0;
    buffer[0] = state.filter_params[1];
    return 1;
}

pub fn getFilterMeta(kind: FilterKind) FilterMeta {
    return switch (kind) {
        .invert => .{ .name = "Invert", .params = &.{} },
        .dilation => .{ .name = "Dilation", .params = &.{} },
        .erosion => .{ .name = "Erosion", .params = &.{} },
        .displacement => .{
            .name = "Displacement",
            .params = &.{
                .{ .name = "Glitch Strength", .kind = .slider, .min = 0.0, .max = 300.0 },
                .{ .name = "Edge Threshold", .kind = .slider, .min = 0.0, .max = 255.0 },
            },
        },
        .subtract => .{
            .name = "Subtract Intensity",
            .params = &.{
                .{ .name = "Amount", .kind = .slider, .min = 0.0, .max = 255.0 },
            },
        },
        .kuwahara => .{
            .name = "Kuwahara",
            .params = &.{
                .{ .name = "Radius", .kind = .slider, .min = 1.0, .max = 15.0 },
            },
        },
        .dither_bayer => .{
            .name = "Bayer Dithering",
            .params = &.{
                .{ .name = "Spread", .kind = .slider, .min = 0.0, .max = 128.0 },
                .{ .name = "Palette", .kind = .palette_editor },
            },
            .serializeFn = serializeDither,
        },
        .pixel_sort_h => .{
            .name = "Pixel Sort",
            .params = &.{
                .{ .name = "Luma Threshold", .kind = .slider, .min = 0.0, .max = 255.0 },
                .{ .name = "Direction", .kind = .radio, .options = &.{ "Horizontal", "Vertical" } },
            },
        },
        .chromatic_aberration => .{
            .name = "Chromatic Aberration",
            .params = &.{
                .{ .name = "Shift X", .kind = .slider, .min = 0.0, .max = 20.0 },
                .{ .name = "Shift Y", .kind = .slider, .min = 0.0, .max = 20.0 },
            },
        },
        .mask_luma => .{
            .name = "Mask",
            .params = &.{
                .{ .name = "Mask Type", .kind = .radio, .options = &.{ "Luma", "Red", "Green", "Blue", "Edge", "Contrast" } },
                .{ .name = "Threshold", .kind = .slider, .min = 0.0, .max = 255.0 },
            },
            .serializeFn = serializeMaskThresholdFromParam1,
        },
        .mask_contrast => .{
            .name = "Mask",
            .params = &.{
                .{ .name = "Mask Type", .kind = .radio, .options = &.{ "Luma", "Red", "Green", "Blue", "Edge", "Contrast" } },
                .{ .name = "Contrast", .kind = .slider, .min = -255.0, .max = 255.0 },
            },
            .serializeFn = serializeMaskThresholdFromParam1,
        },
        .mask_r, .mask_g, .mask_b, .mask_edge => .{
            .name = "Mask",
            .params = &.{
                .{ .name = "Mask Type", .kind = .radio, .options = &.{ "Luma", "Red", "Green", "Blue", "Edge", "Contrast" } },
            },
        },
        .restore => .{
            .name = "Restore",
            .params = &.{
                .{ .name = "Mode", .kind = .radio, .options = &.{ "Use Mask", "Replace Black" } },
                .{ .name = "History Layer", .kind = .slider, .min = 0.0, .max = 1.0 },
            },
        },
        .gpu_grayscale => .{ .name = "GPU Grayscale", .params = &.{} },
        .gpu_invert => .{ .name = "GPU Invert", .params = &.{} },
        .gpu_edge => .{ .name = "GPU Edge", .params = &.{} },
        .gpu_emboss => .{ .name = "GPU Emboss", .params = &.{} },
    };
}

pub fn applyRestore(ctx: FilterContext) void {
    const aux = ctx.aux orelse {
        @memcpy(ctx.output, ctx.input);
        return;
    };
    const mode = if (ctx.parameters.len > 0) ctx.parameters[0] else 0.0;
    const pixel_count: usize = @as(usize, ctx.width) * @as(usize, ctx.height);

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        const idx = i * 4;
        if (mode > 0.5) {
            if (ctx.input[idx] == 0 and ctx.input[idx + 1] == 0 and ctx.input[idx + 2] == 0) {
                ctx.output[idx] = aux[idx];
                ctx.output[idx + 1] = aux[idx + 1];
                ctx.output[idx + 2] = aux[idx + 2];
                ctx.output[idx + 3] = aux[idx + 3];
            } else {
                ctx.output[idx] = ctx.input[idx];
                ctx.output[idx + 1] = ctx.input[idx + 1];
                ctx.output[idx + 2] = ctx.input[idx + 2];
                ctx.output[idx + 3] = ctx.input[idx + 3];
            }
        } else {
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[i])) / 255.0 else 1.0;
            const orig_r = @as(f32, @floatFromInt(ctx.input[idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[idx + 2]));
            const aux_r = @as(f32, @floatFromInt(aux[idx]));
            const aux_g = @as(f32, @floatFromInt(aux[idx + 1]));
            const aux_b = @as(f32, @floatFromInt(aux[idx + 2]));
            ctx.output[idx] = @intFromFloat(std.math.clamp(orig_r + (aux_r - orig_r) * mask_val, 0.0, 255.0));
            ctx.output[idx + 1] = @intFromFloat(std.math.clamp(orig_g + (aux_g - orig_g) * mask_val, 0.0, 255.0));
            ctx.output[idx + 2] = @intFromFloat(std.math.clamp(orig_b + (aux_b - orig_b) * mask_val, 0.0, 255.0));
            ctx.output[idx + 3] = ctx.input[idx + 3];
        }
    }
}

pub fn applySubtract(ctx: FilterContext) void {
    const sub_val = if (ctx.parameters.len > 0) ctx.parameters[0] else 50.0;
    var i: usize = 0;
    const pixel_count: usize = @as(usize, ctx.width) * @as(usize, ctx.height);
    while (i < pixel_count) : (i += 1) {
        const idx = i * 4;
        const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[i])) / 255.0 else 1.0;

        const orig_r = @as(f32, @floatFromInt(ctx.input[idx]));
        const orig_g = @as(f32, @floatFromInt(ctx.input[idx + 1]));
        const orig_b = @as(f32, @floatFromInt(ctx.input[idx + 2]));

        const target_r = std.math.clamp(orig_r - sub_val, 0.0, 255.0);
        const target_g = std.math.clamp(orig_g - sub_val, 0.0, 255.0);
        const target_b = std.math.clamp(orig_b - sub_val, 0.0, 255.0);

        ctx.output[idx] = @intFromFloat(orig_r + (target_r - orig_r) * mask_val);
        ctx.output[idx + 1] = @intFromFloat(orig_g + (target_g - orig_g) * mask_val);
        ctx.output[idx + 2] = @intFromFloat(orig_b + (target_b - orig_b) * mask_val);
        ctx.output[idx + 3] = ctx.input[idx + 3];
    }
}

pub fn applyInvert(ctx: FilterContext) void {
    var i: usize = 0;
    const pixel_count: usize = @as(usize, ctx.width) * @as(usize, ctx.height);
    while (i < pixel_count) : (i += 1) {
        const idx = i * 4;
        const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[i])) / 255.0 else 1.0;

        const orig_r = @as(f32, @floatFromInt(ctx.input[idx]));
        const orig_g = @as(f32, @floatFromInt(ctx.input[idx + 1]));
        const orig_b = @as(f32, @floatFromInt(ctx.input[idx + 2]));

        const inv_r = 255.0 - orig_r;
        const inv_g = 255.0 - orig_g;
        const inv_b = 255.0 - orig_b;

        ctx.output[idx] = @intFromFloat(std.math.clamp(orig_r + (inv_r - orig_r) * mask_val, 0.0, 255.0));
        ctx.output[idx + 1] = @intFromFloat(std.math.clamp(orig_g + (inv_g - orig_g) * mask_val, 0.0, 255.0));
        ctx.output[idx + 2] = @intFromFloat(std.math.clamp(orig_b + (inv_b - orig_b) * mask_val, 0.0, 255.0));
        ctx.output[idx + 3] = ctx.input[idx + 3];
    }
}

pub fn applyDilation(ctx: FilterContext) void {
    const w = @as(i32, @intCast(ctx.width));
    const h = @as(i32, @intCast(ctx.height));
    const radius: i32 = 2;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const pixel_idx = @as(usize, @intCast(y * w + x));
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            const out_idx = pixel_idx * 4;

            if (mask_val == 0.0) {
                @memcpy(ctx.output[out_idx..][0..4], ctx.input[out_idx..][0..4]);
                continue;
            }

            var target_r: u8 = 0;
            var target_g: u8 = 0;
            var target_b: u8 = 0;

            var ky: i32 = -radius;
            while (ky <= radius) : (ky += 1) {
                var kx: i32 = -radius;
                while (kx <= radius) : (kx += 1) {
                    const sx = std.math.clamp(x + kx, 0, w - 1);
                    const sy = std.math.clamp(y + ky, 0, h - 1);
                    const idx = @as(usize, @intCast((sy * w + sx) * 4));
                    target_r = @max(target_r, ctx.input[idx]);
                    target_g = @max(target_g, ctx.input[idx + 1]);
                    target_b = @max(target_b, ctx.input[idx + 2]);
                }
            }

            const orig_r = @as(f32, @floatFromInt(ctx.input[out_idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[out_idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[out_idx + 2]));

            ctx.output[out_idx] = @intFromFloat(std.math.clamp(orig_r + (@as(f32, @floatFromInt(target_r)) - orig_r) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 1] = @intFromFloat(std.math.clamp(orig_g + (@as(f32, @floatFromInt(target_g)) - orig_g) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 2] = @intFromFloat(std.math.clamp(orig_b + (@as(f32, @floatFromInt(target_b)) - orig_b) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 3] = ctx.input[out_idx + 3];
        }
    }
}

pub fn applyErosion(ctx: FilterContext) void {
    const w = @as(i32, @intCast(ctx.width));
    const h = @as(i32, @intCast(ctx.height));
    const radius: i32 = 2;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const pixel_idx = @as(usize, @intCast(y * w + x));
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            const out_idx = pixel_idx * 4;

            if (mask_val == 0.0) {
                @memcpy(ctx.output[out_idx..][0..4], ctx.input[out_idx..][0..4]);
                continue;
            }

            var target_r: u8 = 255;
            var target_g: u8 = 255;
            var target_b: u8 = 255;

            var ky: i32 = -radius;
            while (ky <= radius) : (ky += 1) {
                var kx: i32 = -radius;
                while (kx <= radius) : (kx += 1) {
                    const sx = std.math.clamp(x + kx, 0, w - 1);
                    const sy = std.math.clamp(y + ky, 0, h - 1);
                    const idx = @as(usize, @intCast((sy * w + sx) * 4));
                    target_r = @min(target_r, ctx.input[idx]);
                    target_g = @min(target_g, ctx.input[idx + 1]);
                    target_b = @min(target_b, ctx.input[idx + 2]);
                }
            }

            const orig_r = @as(f32, @floatFromInt(ctx.input[out_idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[out_idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[out_idx + 2]));

            ctx.output[out_idx] = @intFromFloat(std.math.clamp(orig_r + (@as(f32, @floatFromInt(target_r)) - orig_r) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 1] = @intFromFloat(std.math.clamp(orig_g + (@as(f32, @floatFromInt(target_g)) - orig_g) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 2] = @intFromFloat(std.math.clamp(orig_b + (@as(f32, @floatFromInt(target_b)) - orig_b) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 3] = ctx.input[out_idx + 3];
        }
    }
}

pub fn applyDisplacement(ctx: FilterContext) void {
    const w = @as(i32, @intCast(ctx.width));
    const h = @as(i32, @intCast(ctx.height));
    const offset: i32 = 1;
    const sobel_x = [3][3]f32{ .{ -1, 0, 1 }, .{ -2, 0, 2 }, .{ -1, 0, 1 } };

    const strength = if (ctx.parameters.len > 0) ctx.parameters[0] else 100.0;
    const threshold = if (ctx.parameters.len > 1) ctx.parameters[1] else 200.0;
    const max_smear_length = @as(i32, @intFromFloat(strength));

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var is_smearing = false;
        var smear_length_remaining: i32 = 0;
        var smear_r: u8 = 0;
        var smear_g: u8 = 0;
        var smear_b: u8 = 0;

        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const pixel_idx = @as(usize, @intCast(y * w + x));
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            const out_idx = pixel_idx * 4;
            var gx: f32 = 0;

            var ky: i32 = -offset;
            while (ky <= offset) : (ky += 1) {
                var kx: i32 = -offset;
                while (kx <= offset) : (kx += 1) {
                    const sx = std.math.clamp(x + kx, 0, w - 1);
                    const sy = std.math.clamp(y + ky, 0, h - 1);
                    const n_idx = @as(usize, @intCast((sy * w + sx) * 4));
                    const r = @as(f32, @floatFromInt(ctx.input[n_idx]));
                    const g = @as(f32, @floatFromInt(ctx.input[n_idx + 1]));
                    const b = @as(f32, @floatFromInt(ctx.input[n_idx + 2]));
                    const luma = 0.299 * r + 0.587 * g + 0.114 * b;
                    const weight_x = sobel_x[@as(usize, @intCast(ky + 1))][@as(usize, @intCast(kx + 1))];
                    gx += luma * weight_x;
                }
            }

            if (@abs(gx) > threshold) {
                is_smearing = true;
                smear_length_remaining = max_smear_length;
                smear_r = ctx.input[out_idx];
                smear_g = ctx.input[out_idx + 1];
                smear_b = ctx.input[out_idx + 2];
            }

            const orig_r = @as(f32, @floatFromInt(ctx.input[out_idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[out_idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[out_idx + 2]));

            if (is_smearing and smear_length_remaining > 0) {
                ctx.output[out_idx] = @intFromFloat(std.math.clamp(orig_r + (@as(f32, @floatFromInt(smear_r)) - orig_r) * mask_val, 0.0, 255.0));
                ctx.output[out_idx + 1] = @intFromFloat(std.math.clamp(orig_g + (@as(f32, @floatFromInt(smear_g)) - orig_g) * mask_val, 0.0, 255.0));
                ctx.output[out_idx + 2] = @intFromFloat(std.math.clamp(orig_b + (@as(f32, @floatFromInt(smear_b)) - orig_b) * mask_val, 0.0, 255.0));
                ctx.output[out_idx + 3] = ctx.input[out_idx + 3];
                smear_length_remaining -= 1;
            } else {
                is_smearing = false;
                @memcpy(ctx.output[out_idx..][0..4], ctx.input[out_idx..][0..4]);
            }
        }
    }
}

pub fn applyKuwahara(ctx: FilterContext) void {
    const w = @as(i32, @intCast(ctx.width));
    const h = @as(i32, @intCast(ctx.height));
    const raw_radius = if (ctx.parameters.len > 0) @as(i32, @intFromFloat(ctx.parameters[0])) else 3;
    const radius = @max(raw_radius, 1);

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const pixel_idx = @as(usize, @intCast(y * w + x));
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            const out_idx = pixel_idx * 4;

            if (mask_val == 0.0) {
                @memcpy(ctx.output[out_idx..][0..4], ctx.input[out_idx..][0..4]);
                continue;
            }

            const regions = [4][4]i32{
                .{ x - radius, y - radius, x, y },
                .{ x, y - radius, x + radius, y },
                .{ x - radius, y, x, y + radius },
                .{ x, y, x + radius, y + radius },
            };

            var min_var: f32 = std.math.floatMax(f32);
            var target_r: u8 = ctx.input[out_idx];
            var target_g: u8 = ctx.input[out_idx + 1];
            var target_b: u8 = ctx.input[out_idx + 2];

            for (regions) |region| {
                var sum_r: u32 = 0;
                var sum_g: u32 = 0;
                var sum_b: u32 = 0;
                var sum_luma: f32 = 0.0;
                var sum_luma2: f32 = 0.0;
                var count: u32 = 0;

                var ry = region[1];
                while (ry <= region[3]) : (ry += 1) {
                    var rx = region[0];
                    while (rx <= region[2]) : (rx += 1) {
                        const sx = std.math.clamp(rx, 0, w - 1);
                        const sy = std.math.clamp(ry, 0, h - 1);
                        const idx = @as(usize, @intCast((sy * w + sx) * 4));
                        const r = ctx.input[idx];
                        const g = ctx.input[idx + 1];
                        const b = ctx.input[idx + 2];
                        const luma = 0.299 * @as(f32, @floatFromInt(r)) +
                            0.587 * @as(f32, @floatFromInt(g)) +
                            0.114 * @as(f32, @floatFromInt(b));
                        sum_r += r;
                        sum_g += g;
                        sum_b += b;
                        sum_luma += luma;
                        sum_luma2 += luma * luma;
                        count += 1;
                    }
                }

                if (count == 0) continue;
                const n = @as(f32, @floatFromInt(count));
                const mean_luma = sum_luma / n;
                const variance = (sum_luma2 / n) - (mean_luma * mean_luma);
                if (variance < min_var) {
                    min_var = variance;
                    target_r = @intCast(sum_r / count);
                    target_g = @intCast(sum_g / count);
                    target_b = @intCast(sum_b / count);
                }
            }

            const orig_r = @as(f32, @floatFromInt(ctx.input[out_idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[out_idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[out_idx + 2]));
            ctx.output[out_idx] = @intFromFloat(std.math.clamp(orig_r + (@as(f32, @floatFromInt(target_r)) - orig_r) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 1] = @intFromFloat(std.math.clamp(orig_g + (@as(f32, @floatFromInt(target_g)) - orig_g) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 2] = @intFromFloat(std.math.clamp(orig_b + (@as(f32, @floatFromInt(target_b)) - orig_b) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 3] = ctx.input[out_idx + 3];
        }
    }
}

pub fn applyDitherBayer(ctx: FilterContext) void {
    const bayer_matrix = [4][4]f32{
        .{ 0.0, 8.0, 2.0, 10.0 },
        .{ 12.0, 4.0, 14.0, 6.0 },
        .{ 3.0, 11.0, 1.0, 9.0 },
        .{ 15.0, 7.0, 13.0, 5.0 },
    };
    const spread = if (ctx.parameters.len > 0) ctx.parameters[0] else 32.0;
    const raw_num_colors = if (ctx.parameters.len > 1) @as(usize, @intFromFloat(@max(0.0, ctx.parameters[1]))) else 0;
    const available_triplets = if (ctx.parameters.len > 2) (ctx.parameters.len - 2) / 3 else 0;
    const num_colors = @min(raw_num_colors, available_triplets);

    if (num_colors == 0) {
        @memcpy(ctx.output, ctx.input);
        return;
    }

    const palette = ctx.parameters[2 .. 2 + num_colors * 3];

    var y: u32 = 0;
    while (y < ctx.height) : (y += 1) {
        var x: u32 = 0;
        while (x < ctx.width) : (x += 1) {
            const pixel_idx = @as(usize, y * ctx.width + x);
            const out_idx = pixel_idx * 4;
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            if (mask_val == 0.0) {
                @memcpy(ctx.output[out_idx..][0..4], ctx.input[out_idx..][0..4]);
                continue;
            }

            const threshold = (bayer_matrix[y % 4][x % 4] / 16.0) - 0.5;
            const offset = threshold * spread;

            const orig_r = @as(f32, @floatFromInt(ctx.input[out_idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[out_idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[out_idx + 2]));

            const biased_r = orig_r + offset;
            const biased_g = orig_g + offset;
            const biased_b = orig_b + offset;

            var best_dist: f32 = std.math.floatMax(f32);
            var best_r: u8 = 0;
            var best_g: u8 = 0;
            var best_b: u8 = 0;

            var i: usize = 0;
            while (i < num_colors) : (i += 1) {
                const pr = palette[i * 3];
                const pg = palette[i * 3 + 1];
                const pb = palette[i * 3 + 2];
                const dr = biased_r - pr;
                const dg = biased_g - pg;
                const db = biased_b - pb;
                const dist = dr * dr + dg * dg + db * db;
                if (dist < best_dist) {
                    best_dist = dist;
                    best_r = @intFromFloat(std.math.clamp(pr, 0.0, 255.0));
                    best_g = @intFromFloat(std.math.clamp(pg, 0.0, 255.0));
                    best_b = @intFromFloat(std.math.clamp(pb, 0.0, 255.0));
                }
            }

            ctx.output[out_idx] = @intFromFloat(std.math.clamp(orig_r + (@as(f32, @floatFromInt(best_r)) - orig_r) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 1] = @intFromFloat(std.math.clamp(orig_g + (@as(f32, @floatFromInt(best_g)) - orig_g) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 2] = @intFromFloat(std.math.clamp(orig_b + (@as(f32, @floatFromInt(best_b)) - orig_b) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 3] = ctx.input[out_idx + 3];
        }
    }
}

const PixelStruct = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    luma: f32,

    fn lessThan(_: void, lhs: PixelStruct, rhs: PixelStruct) bool {
        return lhs.luma < rhs.luma;
    }
};

fn sortPixelSpan(span: []PixelStruct) void {
    if (span.len < 2) return;
    var i: usize = 1;
    while (i < span.len) : (i += 1) {
        const key = span[i];
        var j = i;
        while (j > 0 and span[j - 1].luma > key.luma) : (j -= 1) {
            span[j] = span[j - 1];
        }
        span[j] = key;
    }
}

pub fn applyPixelSort(ctx: FilterContext) void {
    @memcpy(ctx.output, ctx.input);
    const threshold = if (ctx.parameters.len > 0) ctx.parameters[0] else 128.0;
    const is_vertical = ctx.parameters.len > 1 and ctx.parameters[1] > 0.5;
    var span_buffer = std.ArrayList(PixelStruct).empty;
    defer span_buffer.deinit(std.heap.page_allocator);

    const primary_limit = if (is_vertical) ctx.width else ctx.height;
    const secondary_limit = if (is_vertical) ctx.height else ctx.width;

    var p: u32 = 0;
    while (p < primary_limit) : (p += 1) {
        var s: u32 = 0;
        while (s < secondary_limit) {
            const x = if (is_vertical) p else s;
            const y = if (is_vertical) s else p;
            const pixel_idx = @as(usize, y * ctx.width + x);
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            const base_idx = pixel_idx * 4;
            const r = ctx.input[base_idx];
            const g = ctx.input[base_idx + 1];
            const b = ctx.input[base_idx + 2];
            const luma = 0.299 * @as(f32, @floatFromInt(r)) + 0.587 * @as(f32, @floatFromInt(g)) + 0.114 * @as(f32, @floatFromInt(b));

            if (mask_val > 0.5 and luma > threshold) {
                const span_start = s;
                span_buffer.clearRetainingCapacity();
                while (s < secondary_limit) : (s += 1) {
                    const sx_inner = if (is_vertical) p else s;
                    const sy_inner = if (is_vertical) s else p;
                    const s_idx = @as(usize, sy_inner * ctx.width + sx_inner);
                    const sm = if (ctx.mask) |m| @as(f32, @floatFromInt(m[s_idx])) / 255.0 else 1.0;
                    const p_idx = s_idx * 4;
                    const sr = ctx.input[p_idx];
                    const sg = ctx.input[p_idx + 1];
                    const sb = ctx.input[p_idx + 2];
                    const sluma = 0.299 * @as(f32, @floatFromInt(sr)) + 0.587 * @as(f32, @floatFromInt(sg)) + 0.114 * @as(f32, @floatFromInt(sb));
                    if (sm <= 0.5 or sluma <= threshold) break;
                    span_buffer.append(std.heap.page_allocator, .{
                        .r = sr,
                        .g = sg,
                        .b = sb,
                        .a = ctx.input[p_idx + 3],
                        .luma = sluma,
                    }) catch break;
                }
                std.mem.sort(PixelStruct, span_buffer.items, {}, PixelStruct.lessThan);
                for (span_buffer.items, 0..) |px, i| {
                    const out_x = if (is_vertical) p else span_start + @as(u32, @intCast(i));
                    const out_y = if (is_vertical) span_start + @as(u32, @intCast(i)) else p;
                    const out_idx = @as(usize, (out_y * ctx.width + out_x) * 4);
                    ctx.output[out_idx] = px.r;
                    ctx.output[out_idx + 1] = px.g;
                    ctx.output[out_idx + 2] = px.b;
                    ctx.output[out_idx + 3] = px.a;
                }
            } else {
                s += 1;
            }
        }
    }
}

pub fn applyChromaticAberration(ctx: FilterContext) void {
    const w = @as(i32, @intCast(ctx.width));
    const h = @as(i32, @intCast(ctx.height));
    const shift_x = if (ctx.parameters.len > 0) @as(i32, @intFromFloat(ctx.parameters[0])) else 2;
    const shift_y = if (ctx.parameters.len > 1) @as(i32, @intFromFloat(ctx.parameters[1])) else 0;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const pixel_idx = @as(usize, @intCast(y * w + x));
            const out_idx = pixel_idx * 4;
            const mask_val: f32 = if (ctx.mask) |m| @as(f32, @floatFromInt(m[pixel_idx])) / 255.0 else 1.0;
            if (mask_val == 0.0) {
                @memcpy(ctx.output[out_idx..][0..4], ctx.input[out_idx..][0..4]);
                continue;
            }

            const r_x = std.math.clamp(x + shift_x, 0, w - 1);
            const r_y = std.math.clamp(y + shift_y, 0, h - 1);
            const b_x = std.math.clamp(x - shift_x, 0, w - 1);
            const b_y = std.math.clamp(y - shift_y, 0, h - 1);
            const r_idx = @as(usize, @intCast((r_y * w + r_x) * 4));
            const g_idx = out_idx;
            const b_idx = @as(usize, @intCast((b_y * w + b_x) * 4));

            const orig_r = @as(f32, @floatFromInt(ctx.input[out_idx]));
            const orig_g = @as(f32, @floatFromInt(ctx.input[out_idx + 1]));
            const orig_b = @as(f32, @floatFromInt(ctx.input[out_idx + 2]));
            const target_r = @as(f32, @floatFromInt(ctx.input[r_idx]));
            const target_g = @as(f32, @floatFromInt(ctx.input[g_idx + 1]));
            const target_b = @as(f32, @floatFromInt(ctx.input[b_idx + 2]));

            ctx.output[out_idx] = @intFromFloat(std.math.clamp(orig_r + (target_r - orig_r) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 1] = @intFromFloat(std.math.clamp(orig_g + (target_g - orig_g) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 2] = @intFromFloat(std.math.clamp(orig_b + (target_b - orig_b) * mask_val, 0.0, 255.0));
            ctx.output[out_idx + 3] = ctx.input[out_idx + 3];
        }
    }
}

pub fn applyLumaMask(ctx: FilterContext) void {
    const threshold = if (ctx.parameters.len > 0) ctx.parameters[0] else 128.0;
    var i: usize = 0;
    const pixel_count: usize = @as(usize, ctx.width) * @as(usize, ctx.height);

    while (i < pixel_count) : (i += 1) {
        const idx = i * 4;
        const r = @as(f32, @floatFromInt(ctx.input[idx]));
        const g = @as(f32, @floatFromInt(ctx.input[idx + 1]));
        const b = @as(f32, @floatFromInt(ctx.input[idx + 2]));
        const luma = 0.299 * r + 0.587 * g + 0.114 * b;
        const mask_val: u8 = if (luma > threshold) 255 else 0;

        ctx.output[idx] = mask_val;
        ctx.output[idx + 1] = mask_val;
        ctx.output[idx + 2] = mask_val;
        ctx.output[idx + 3] = 255;
    }
}

pub fn applyMaskR(ctx: FilterContext) void {
    applyChannelMask(ctx, 0);
}
pub fn applyMaskG(ctx: FilterContext) void {
    applyChannelMask(ctx, 1);
}
pub fn applyMaskB(ctx: FilterContext) void {
    applyChannelMask(ctx, 2);
}

fn applyChannelMask(ctx: FilterContext, channel: usize) void {
    var i: usize = 0;
    const pixel_count: usize = @as(usize, ctx.width) * @as(usize, ctx.height);
    while (i < pixel_count) : (i += 1) {
        const idx = i * 4;
        const val = ctx.input[idx + channel];
        ctx.output[idx] = val;
        ctx.output[idx + 1] = val;
        ctx.output[idx + 2] = val;
        ctx.output[idx + 3] = 255;
    }
}

pub fn applyMaskContrast(ctx: FilterContext) void {
    const contrast = if (ctx.parameters.len > 0) ctx.parameters[0] else 0.0;
    const factor = (259.0 * (contrast + 255.0)) / (255.0 * (259.0 - contrast));

    var i: usize = 0;
    const pixel_count: usize = @as(usize, ctx.width) * @as(usize, ctx.height);
    while (i < pixel_count) : (i += 1) {
        const idx = i * 4;
        const r = @as(f32, @floatFromInt(ctx.input[idx]));
        const g = @as(f32, @floatFromInt(ctx.input[idx + 1]));
        const b = @as(f32, @floatFromInt(ctx.input[idx + 2]));
        const luma = 0.299 * r + 0.587 * g + 0.114 * b;

        const new_luma = factor * (luma - 128.0) + 128.0;
        const mask_val: u8 = @intFromFloat(std.math.clamp(new_luma, 0.0, 255.0));

        ctx.output[idx] = mask_val;
        ctx.output[idx + 1] = mask_val;
        ctx.output[idx + 2] = mask_val;
        ctx.output[idx + 3] = 255;
    }
}

pub fn applyMaskEdge(ctx: FilterContext) void {
    const w = @as(i32, @intCast(ctx.width));
    const h = @as(i32, @intCast(ctx.height));
    const sobel_x = [3][3]f32{ .{ -1, 0, 1 }, .{ -2, 0, 2 }, .{ -1, 0, 1 } };
    const sobel_y = [3][3]f32{ .{ -1, -2, -1 }, .{ 0, 0, 0 }, .{ 1, 2, 1 } };

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            var gx: f32 = 0;
            var gy: f32 = 0;

            var ky: i32 = -1;
            while (ky <= 1) : (ky += 1) {
                var kx: i32 = -1;
                while (kx <= 1) : (kx += 1) {
                    const sx = std.math.clamp(x + kx, 0, w - 1);
                    const sy = std.math.clamp(y + ky, 0, h - 1);
                    const n_idx = @as(usize, @intCast((sy * w + sx) * 4));
                    const luma = 0.299 * @as(f32, @floatFromInt(ctx.input[n_idx])) +
                        0.587 * @as(f32, @floatFromInt(ctx.input[n_idx + 1])) +
                        0.114 * @as(f32, @floatFromInt(ctx.input[n_idx + 2]));

                    gx += luma * sobel_x[@as(usize, @intCast(ky + 1))][@as(usize, @intCast(kx + 1))];
                    gy += luma * sobel_y[@as(usize, @intCast(ky + 1))][@as(usize, @intCast(kx + 1))];
                }
            }

            const mag = @sqrt(gx * gx + gy * gy);
            const mask_val: u8 = @intFromFloat(std.math.clamp(mag, 0.0, 255.0));
            const out_idx = @as(usize, @intCast((y * w + x) * 4));
            ctx.output[out_idx] = mask_val;
            ctx.output[out_idx + 1] = mask_val;
            ctx.output[out_idx + 2] = mask_val;
            ctx.output[out_idx + 3] = 255;
        }
    }
}
