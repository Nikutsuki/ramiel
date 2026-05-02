const std = @import("std");
const c = @import("c.zig");

pub const AudioContext = struct {
    engine: *c.ma_engine,
    allocator: std.mem.Allocator,
    is_initialized: bool,

    pub fn init(allocator: std.mem.Allocator) !AudioContext {
        const engine_ptr = try allocator.create(c.ma_engine);
        errdefer allocator.destroy(engine_ptr);

        const result = c.ma_engine_init(null, engine_ptr);
        if (result != c.MA_SUCCESS) {
            return error.AudioEngineInitFailed;
        }

        return .{
            .engine = engine_ptr,
            .allocator = allocator,
            .is_initialized = true,
        };
    }

    pub fn deinit(self: *AudioContext) void {
        if (self.is_initialized) {
            c.ma_engine_uninit(self.engine);
            self.allocator.destroy(self.engine);
            self.is_initialized = false;
        }
    }

    pub fn playSound(self: *AudioContext, file_path: [:0]const u8) void {
        if (!self.is_initialized) return;
        _ = c.ma_engine_play_sound(self.engine, file_path.ptr, null);
    }
};
