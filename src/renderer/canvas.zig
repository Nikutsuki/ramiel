const std = @import("std");
const Core = @import("vulkan/core.zig").Core;
const TextureRegistry = @import("vulkan/texture_registry.zig").TextureRegistry;
const DynamicTexture = @import("vulkan/dynamic_texture.zig").DynamicTexture;
const PixelBuffer = @import("pixel_buffer.zig").PixelBuffer;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    buffer: PixelBuffer,

    gpu_texture: *DynamicTexture,
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

        self.width = buffer.width;
        self.height = buffer.height;
        self.buffer = buffer;
        self.allocator = allocator;
        self.is_dirty = true;

        self.gpu_texture = try DynamicTexture.create(allocator, core, texture_registry, self.width, self.height, frame_slots);
        return self;
    }

    pub fn deinit(self: *Canvas, core: *const Core, texture_registry: *TextureRegistry) void {
        self.gpu_texture.destroy(self.allocator, core, texture_registry);
        self.buffer.deinit();
        self.allocator.destroy(self);
    }

    pub fn getRawPixels(self: *Canvas) []u8 {
        return self.buffer.pixels;
    }

    pub fn markDirty(self: *Canvas) void {
        self.is_dirty = true;
    }
};
