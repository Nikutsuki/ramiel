const vk = @import("../../vk.zig");
const std = @import("std");

pub const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
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

    pub fn getBindingDescription() vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };
    }

    pub fn getAttributeDescriptions() [13]vk.VertexInputAttributeDescription {
        return [_]vk.VertexInputAttributeDescription{
            .{ .binding = 0, .location = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "pos") },
            .{ .binding = 0, .location = 1, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
            .{ .binding = 0, .location = 2, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "color") },
            .{ .binding = 0, .location = 3, .format = .r32_uint, .offset = @offsetOf(Vertex, "tex_id") },
            .{ .binding = 0, .location = 4, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "corner_radii") },
            .{ .binding = 0, .location = 5, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "clip_rect") },
            .{ .binding = 0, .location = 6, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "clip_round_rect") },
            .{ .binding = 0, .location = 7, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "clip_round_radii") },
            .{ .binding = 0, .location = 8, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "border_widths") },
            .{ .binding = 0, .location = 9, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "outline_widths") },
            .{ .binding = 0, .location = 10, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "sdf_params") },
            .{ .binding = 0, .location = 11, .format = .r32g32b32a32_uint, .offset = @offsetOf(Vertex, "border_colors") },
            .{ .binding = 0, .location = 12, .format = .r32g32b32a32_uint, .offset = @offsetOf(Vertex, "outline_colors") },
        };
    }
};
