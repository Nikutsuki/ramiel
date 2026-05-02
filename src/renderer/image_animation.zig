const std = @import("std");

pub const FrameMetadata = struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    delay_ms: u32,
};

pub const AnimatedState = struct {
    frames: []FrameMetadata,
    total_duration_ms: u32,

    pub fn deinit(self: *AnimatedState, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
    }
};
