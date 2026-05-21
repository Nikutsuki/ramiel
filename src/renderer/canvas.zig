const std = @import("std");
const Core = @import("vulkan/core.zig").Core;
const TextureRegistry = @import("vulkan/texture_registry.zig").TextureRegistry;
const DynamicTexture = @import("vulkan/dynamic_texture.zig").DynamicTexture;
const PixelBuffer = @import("pixel_buffer.zig").PixelBuffer;
const compute_canvas = @import("vulkan/compute_canvas.zig");
const ComputeBacking = compute_canvas.ComputeBacking;
const FragmentBacking = @import("vulkan/fragment_canvas.zig").FragmentBacking;
pub const ComputeInputImage = compute_canvas.InputImage;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    buffer: ?PixelBuffer = null,
    gpu_texture: ?*DynamicTexture = null,
    compute: ?*ComputeBacking = null,
    fragment: ?*FragmentBacking = null,
    is_dirty: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        frame_slots: usize,
    ) !*Canvas {
        const buffer = try PixelBuffer.initBlank(allocator, width, height);
        errdefer {
            var owned = buffer;
            owned.deinit();
        }
        return initFromBuffer(allocator, core, texture_registry, buffer, frame_slots);
    }

    pub fn initFromBuffer(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        buffer: PixelBuffer,
        frame_slots: usize,
    ) !*Canvas {
        if (buffer.width == 0 or buffer.height == 0) return error.InvalidCanvasSize;
        if (buffer.channels != 4) return error.InvalidCanvasChannels;

        const self = try allocator.create(Canvas);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .width = buffer.width,
            .height = buffer.height,
            .buffer = buffer,
            .is_dirty = true,
        };

        self.gpu_texture = try DynamicTexture.create(allocator, core, texture_registry, self.width, self.height, frame_slots);
        return self;
    }

    pub fn initCompute(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        spirv: []const u32,
        input_image: ?ComputeInputImage,
    ) !*Canvas {
        const self = try allocator.create(Canvas);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .is_dirty = true,
        };

        self.compute = try ComputeBacking.create(allocator, core, texture_registry, width, height, spirv, input_image);
        return self;
    }

    pub fn initFragment(
        allocator: std.mem.Allocator,
        core: *const Core,
        texture_registry: *TextureRegistry,
        width: u32,
        height: u32,
        vert_spirv: []const u32,
        frag_spirv: []const u32,
        input_image: ?ComputeInputImage,
    ) !*Canvas {
        const self = try allocator.create(Canvas);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .is_dirty = true,
        };

        self.fragment = try FragmentBacking.create(allocator, core, texture_registry, width, height, vert_spirv, frag_spirv, input_image);
        return self;
    }

    pub fn deinit(self: *Canvas, core: *const Core, texture_registry: *TextureRegistry) void {
        if (self.fragment) |backing| backing.destroy(self.allocator, core, texture_registry);
        if (self.compute) |backing| backing.destroy(self.allocator, core, texture_registry);
        if (self.gpu_texture) |tex| tex.destroy(self.allocator, core, texture_registry);
        if (self.buffer) |*buf| buf.deinit();
        self.allocator.destroy(self);
    }

    pub fn texId(self: *const Canvas) u32 {
        if (self.fragment) |backing| return backing.tex_id;
        if (self.compute) |backing| return backing.tex_id;
        return self.gpu_texture.?.tex_id;
    }

    pub fn getRawPixels(self: *Canvas) []u8 {
        return self.buffer.?.pixels;
    }

    pub fn setParam(self: *Canvas, index: usize, value: [4]f32) void {
        if (self.compute) |backing| backing.setParam(index, value);
        if (self.fragment) |backing| backing.setParam(index, value);
    }

    pub fn markDirty(self: *Canvas) void {
        self.is_dirty = true;
    }
};
