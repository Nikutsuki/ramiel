const c = @import("c.zig").c;
const std = @import("std");
const SoundRegistry = @import("registry.zig").SoundRegistry;
const Tap = @import("tap.zig").Tap;

pub const AudioEngine = struct {
    engine: *c.ma_engine,
    registry: SoundRegistry,
    tap: *Tap,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AudioEngine {
        const engine_ptr = try allocator.create(c.ma_engine);
        errdefer allocator.destroy(engine_ptr);

        var self: AudioEngine = .{
            .engine = engine_ptr,
            .registry = undefined,
            .tap = undefined,
            .allocator = allocator,
        };

        var config = c.ma_engine_config_init();

        if (c.ma_engine_init(&config, self.engine) != c.MA_SUCCESS) {
            return error.EngineInitFailed;
        }
        errdefer c.ma_engine_uninit(self.engine);

        const tap_ptr = try allocator.create(Tap);
        errdefer allocator.destroy(tap_ptr);
        tap_ptr.* = .{};
        try tap_ptr.init(self.engine);
        errdefer tap_ptr.deinit();
        self.tap = tap_ptr;

        self.registry = try SoundRegistry.init(allocator, io, self.engine, tap_ptr.asNodePtr());

        return self;
    }

    pub fn deinit(self: *AudioEngine) void {
        self.registry.deinit();
        self.tap.deinit();
        self.allocator.destroy(self.tap);
        c.ma_engine_uninit(self.engine);
        self.allocator.destroy(self.engine);
    }

    pub fn getSampleRate(self: *const AudioEngine) u32 {
        return c.ma_engine_get_sample_rate(self.engine);
    }
};
