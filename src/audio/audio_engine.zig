const c = @import("c.zig").c;
const std = @import("std");
const SoundRegistry = @import("registry.zig").SoundRegistry;
const Tap = @import("tap.zig").Tap;

pub const EQBand = struct {
    freq_hz: f32 = 1000.0,
    gain_db: f32 = 0.0,
    q: f32 = 0.707,
};

pub const EQConfig = struct {
    enabled: bool = false,
    low: EQBand = .{ .freq_hz = 80.0, .gain_db = 0.0, .q = 0.707 },
    mid: EQBand = .{ .freq_hz = 1000.0, .gain_db = 0.0, .q = 0.707 },
    high: EQBand = .{ .freq_hz = 8000.0, .gain_db = 0.0, .q = 0.707 },
};

const EQChain = struct {
    low: c.ma_peak_node,
    mid: c.ma_peak_node,
    high: c.ma_peak_node,
    initialized: bool = false,
    inserted: bool = false,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    config: EQConfig = .{},
};

pub const AudioEngine = struct {
    engine: *c.ma_engine,
    registry: SoundRegistry,
    tap: *Tap,
    allocator: std.mem.Allocator,
    io: std.Io,
    eq: *EQChain,
    eq_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AudioEngine {
        const engine_ptr = try allocator.create(c.ma_engine);
        errdefer allocator.destroy(engine_ptr);

        const eq_ptr = try allocator.create(EQChain);
        errdefer allocator.destroy(eq_ptr);
        eq_ptr.* = .{ .low = undefined, .mid = undefined, .high = undefined };

        var self: AudioEngine = .{
            .engine = engine_ptr,
            .registry = undefined,
            .tap = undefined,
            .allocator = allocator,
            .io = io,
            .eq = eq_ptr,
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
        self.uninitEQChainLocked();
        self.allocator.destroy(self.eq);
        self.registry.deinit();
        self.tap.deinit();
        self.allocator.destroy(self.tap);
        c.ma_engine_uninit(self.engine);
        self.allocator.destroy(self.engine);
    }

    pub fn getSampleRate(self: *const AudioEngine) u32 {
        return c.ma_engine_get_sample_rate(self.engine);
    }

    /// 3-band parametric EQ inserted between Tap and the engine endpoint.
    /// Disabled = chain detached, sound flows tap → endpoint.
    /// Enabled = sound flows tap → low → mid → high → endpoint.
    pub fn setEQ(self: *AudioEngine, cfg: EQConfig) !void {
        self.eq_mutex.lockUncancelable(std.Options.debug_io);
        defer self.eq_mutex.unlock(std.Options.debug_io);

        if (cfg.enabled) {
            if (!self.eq.initialized) try self.initEQChainLocked();
            self.applyEQParamsLocked(cfg);
            if (!self.eq.inserted) try self.insertEQLocked();
        } else {
            if (self.eq.inserted) try self.removeEQLocked();
        }
        self.eq.config = cfg;
    }

    pub fn getEQ(self: *AudioEngine) EQConfig {
        self.eq_mutex.lockUncancelable(std.Options.debug_io);
        defer self.eq_mutex.unlock(std.Options.debug_io);
        return self.eq.config;
    }

    fn initEQChainLocked(self: *AudioEngine) !void {
        const node_graph = c.ma_engine_get_node_graph(self.engine);
        const sr = c.ma_engine_get_sample_rate(self.engine);
        const ch = c.ma_engine_get_channels(self.engine);
        self.eq.sample_rate = sr;
        self.eq.channels = ch;

        var low_cfg = c.ma_peak_node_config_init(ch, sr, 0.0, 0.707, 80.0);
        if (c.ma_peak_node_init(node_graph, &low_cfg, null, &self.eq.low) != c.MA_SUCCESS) return error.EQInitFailed;
        errdefer c.ma_peak_node_uninit(&self.eq.low, null);

        var mid_cfg = c.ma_peak_node_config_init(ch, sr, 0.0, 0.707, 1000.0);
        if (c.ma_peak_node_init(node_graph, &mid_cfg, null, &self.eq.mid) != c.MA_SUCCESS) return error.EQInitFailed;
        errdefer c.ma_peak_node_uninit(&self.eq.mid, null);

        var high_cfg = c.ma_peak_node_config_init(ch, sr, 0.0, 0.707, 8000.0);
        if (c.ma_peak_node_init(node_graph, &high_cfg, null, &self.eq.high) != c.MA_SUCCESS) return error.EQInitFailed;

        self.eq.initialized = true;
    }

    fn uninitEQChainLocked(self: *AudioEngine) void {
        if (!self.eq.initialized) return;
        if (self.eq.inserted) self.removeEQLocked() catch {};
        c.ma_peak_node_uninit(&self.eq.high, null);
        c.ma_peak_node_uninit(&self.eq.mid, null);
        c.ma_peak_node_uninit(&self.eq.low, null);
        self.eq.initialized = false;
    }

    fn insertEQLocked(self: *AudioEngine) !void {
        const node_graph = c.ma_engine_get_node_graph(self.engine);
        const endpoint = c.ma_node_graph_get_endpoint(node_graph);

        // Re-route: tap → low → mid → high → endpoint
        if (c.ma_node_attach_output_bus(self.tap.asNodePtr(), 0, @ptrCast(&self.eq.low), 0) != c.MA_SUCCESS) return error.EQAttachFailed;
        if (c.ma_node_attach_output_bus(@ptrCast(&self.eq.low), 0, @ptrCast(&self.eq.mid), 0) != c.MA_SUCCESS) return error.EQAttachFailed;
        if (c.ma_node_attach_output_bus(@ptrCast(&self.eq.mid), 0, @ptrCast(&self.eq.high), 0) != c.MA_SUCCESS) return error.EQAttachFailed;
        if (c.ma_node_attach_output_bus(@ptrCast(&self.eq.high), 0, endpoint, 0) != c.MA_SUCCESS) return error.EQAttachFailed;

        self.eq.inserted = true;
    }

    fn removeEQLocked(self: *AudioEngine) !void {
        const node_graph = c.ma_engine_get_node_graph(self.engine);
        const endpoint = c.ma_node_graph_get_endpoint(node_graph);

        // Detach EQ nodes; reattach tap straight to endpoint.
        _ = c.ma_node_detach_output_bus(@ptrCast(&self.eq.high), 0);
        _ = c.ma_node_detach_output_bus(@ptrCast(&self.eq.mid), 0);
        _ = c.ma_node_detach_output_bus(@ptrCast(&self.eq.low), 0);
        if (c.ma_node_attach_output_bus(self.tap.asNodePtr(), 0, endpoint, 0) != c.MA_SUCCESS) return error.EQAttachFailed;

        self.eq.inserted = false;
    }

    fn applyEQParamsLocked(self: *AudioEngine, cfg: EQConfig) void {
        const sr = self.eq.sample_rate;
        const ch = self.eq.channels;
        var lc = c.ma_peak_node_config_init(ch, sr, cfg.low.gain_db, cfg.low.q, cfg.low.freq_hz);
        _ = c.ma_peak_node_reinit(&lc.peak, &self.eq.low);
        var mc = c.ma_peak_node_config_init(ch, sr, cfg.mid.gain_db, cfg.mid.q, cfg.mid.freq_hz);
        _ = c.ma_peak_node_reinit(&mc.peak, &self.eq.mid);
        var hc = c.ma_peak_node_config_init(ch, sr, cfg.high.gain_db, cfg.high.q, cfg.high.freq_hz);
        _ = c.ma_peak_node_reinit(&hc.peak, &self.eq.high);
    }
};
