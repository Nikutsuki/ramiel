//! Curated QuadBatcher subset handed to .custom_paint; hides z/layer/video state.

const std = @import("std");
const QuadBatcher = @import("../renderer/vulkan/batcher.zig").QuadBatcher;
const RoundedRectStyle = @import("../renderer/vulkan/batcher.zig").RoundedRectStyle;

pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const PaintContext = struct {
    batcher: *QuadBatcher,
    bounds: Bounds,
    opacity: f32,

    fn applyOpacity(self: *const PaintContext, color: [4]f32) [4]f32 {
        return .{ color[0], color[1], color[2], std.math.clamp(color[3] * self.opacity, 0.0, 1.0) };
    }

    pub fn drawLine(
        self: *PaintContext,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        thickness: f32,
        color: [4]f32,
    ) !void {
        try self.batcher.addLine(x0, y0, x1, y1, thickness, self.applyOpacity(color));
    }

    pub fn drawPoint(
        self: *PaintContext,
        x: f32,
        y: f32,
        size: f32,
        color: [4]f32,
    ) !void {
        try self.batcher.addPoint(x, y, size, self.applyOpacity(color));
    }

    pub fn drawPolyline(
        self: *PaintContext,
        points: []const [2]f32,
        thickness: f32,
        color: [4]f32,
    ) !void {
        try self.batcher.addPolyline(points, thickness, self.applyOpacity(color));
    }

    pub fn drawRect(
        self: *PaintContext,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: [4]f32,
    ) !void {
        try self.batcher.addRect(
            x,
            y,
            width,
            height,
            self.applyOpacity(color),
            0,
            0,
            .{ 0, 0, 0, 0 },
        );
    }

    pub fn drawRoundedRect(
        self: *PaintContext,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: [4]f32,
        style: RoundedRectStyle,
    ) !void {
        try self.batcher.addRoundedRect(
            x,
            y,
            width,
            height,
            self.applyOpacity(color),
            style,
            0.0,
        );
    }

    pub fn pushScissor(
        self: *PaintContext,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        round_radii: [4]f32,
    ) !void {
        try self.batcher.pushScissor(x, y, width, height, round_radii);
    }

    pub fn popScissor(self: *PaintContext) !void {
        try self.batcher.popScissor();
    }
};

pub const PaintFn = *const fn (pctx: *PaintContext, userdata: ?*const anyopaque) anyerror!void;
