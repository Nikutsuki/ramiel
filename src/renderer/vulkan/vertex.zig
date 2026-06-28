const vk = @import("../../vk.zig");
const std = @import("std");

pub const Instance = struct {
    corner01: [4]f32, // x0,y0, x1,y1  (TL, TR)
    corner23: [4]f32, // x2,y2, x3,y3  (BR, BL)
    uv_rect: [4]f32, // umin,vmin, umax,vmax
    color: [4]f32,
    tex_id: u32,

    corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_round_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_round_radii: [4]f32 = .{ 0, 0, 0, 0 },
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    outline_widths: [4]f32 = .{ 0, 0, 0, 0 },
    sdf_params: [4]f32 = .{ 0, 0, 0, 0 },
    border_colors: [4]u32 = .{ 0, 0, 0, 0 },
    outline_colors: [4]u32 = .{ 0, 0, 0, 0 },
    noise: f32 = 0,

    pub fn getBindingDescription() vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Instance),
            .input_rate = .instance,
        };
    }

    pub fn getAttributeDescriptions() [15]vk.VertexInputAttributeDescription {
        return [_]vk.VertexInputAttributeDescription{
            .{ .binding = 0, .location = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "corner01") },
            .{ .binding = 0, .location = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "corner23") },
            .{ .binding = 0, .location = 2, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "uv_rect") },
            .{ .binding = 0, .location = 3, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "color") },
            .{ .binding = 0, .location = 4, .format = .r32_uint, .offset = @offsetOf(Instance, "tex_id") },
            .{ .binding = 0, .location = 5, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "corner_radii") },
            .{ .binding = 0, .location = 6, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "clip_rect") },
            .{ .binding = 0, .location = 7, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "clip_round_rect") },
            .{ .binding = 0, .location = 8, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "clip_round_radii") },
            .{ .binding = 0, .location = 9, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "border_widths") },
            .{ .binding = 0, .location = 10, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "outline_widths") },
            .{ .binding = 0, .location = 11, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Instance, "sdf_params") },
            .{ .binding = 0, .location = 12, .format = .r32g32b32a32_uint, .offset = @offsetOf(Instance, "border_colors") },
            .{ .binding = 0, .location = 13, .format = .r32g32b32a32_uint, .offset = @offsetOf(Instance, "outline_colors") },
            .{ .binding = 0, .location = 14, .format = .r32_sfloat, .offset = @offsetOf(Instance, "noise") },
        };
    }
};
