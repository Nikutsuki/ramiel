//! miniaudio passthrough node between sounds and endpoint. Copies frames through and
//! records mono mix into a ring buffer. UI reads via readSnapshot.

const std = @import("std");
const c = @import("c.zig").c;

pub const RING_FRAMES: usize = 4096;
const RING_MASK: usize = RING_FRAMES - 1;

comptime {
    if ((RING_FRAMES & RING_MASK) != 0) @compileError("RING_FRAMES must be a power of two");
}

pub const Tap = struct {
    base: c.ma_node_base = undefined,
    ring: [RING_FRAMES]f32 = .{0} ** RING_FRAMES,
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    channels: u32 = 0,
    initialized: bool = false,
    // Fired from audio thread after each ring write; wire glfw.postEmptyEvent for UI redraw.
    wake_cb: ?*const fn () callconv(.c) void = null,
    wake_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    var vtable: c.ma_node_vtable = .{
        .onProcess = process,
        .onGetRequiredInputFrameCount = null,
        .inputBusCount = 1,
        .outputBusCount = 1,
        .flags = 0,
    };

    fn process(
        node: ?*anyopaque,
        pp_in: [*c][*c]const f32,
        p_in_count: [*c]c_uint,
        pp_out: [*c][*c]f32,
        p_out_count: [*c]c_uint,
    ) callconv(.c) void {
        const base_ptr: *c.ma_node_base = @ptrCast(@alignCast(node.?));
        const self: *Tap = @fieldParentPtr("base", base_ptr);

        const frames: u32 = @intCast(p_out_count[0]);
        const channels = self.channels;
        if (channels == 0 or frames == 0) {
            p_in_count[0] = frames;
            return;
        }
        const total_samples: usize = @as(usize, frames) * channels;

        const in_raw: [*c]const f32 = pp_in[0];
        const out_raw: [*c]f32 = pp_out[0];
        const in_opt: ?[*]const f32 = if (in_raw == null) null else @ptrCast(in_raw);
        const out_opt: ?[*]f32 = if (out_raw == null) null else @ptrCast(out_raw);

        if (in_opt) |in_ptr| {
            if (out_opt) |out_ptr| {
                @memcpy(out_ptr[0..total_samples], in_ptr[0..total_samples]);
            }
        } else if (out_opt) |out_ptr| {
            @memset(out_ptr[0..total_samples], 0);
        }

        const src_opt: ?[*]const f32 = if (in_opt) |p| p else if (out_opt) |p| p else null;
        if (src_opt) |src| {
            const inv_ch: f32 = 1.0 / @as(f32, @floatFromInt(channels));
            var pos = self.write_pos.load(.acquire);
            var i: u32 = 0;
            while (i < frames) : (i += 1) {
                var sum: f32 = 0;
                var ch: u32 = 0;
                while (ch < channels) : (ch += 1) {
                    sum += src[i * channels + ch];
                }
                self.ring[pos & RING_MASK] = sum * inv_ch;
                pos +%= 1;
            }
            self.write_pos.store(pos, .release);
            if (self.wake_enabled.load(.monotonic)) {
                if (self.wake_cb) |cb| cb();
            }
        }

        p_in_count[0] = frames;
    }

    pub fn setWakeCallback(self: *Tap, cb: ?*const fn () callconv(.c) void) void {
        self.wake_cb = cb;
    }

    pub fn setWakeEnabled(self: *Tap, enabled: bool) void {
        self.wake_enabled.store(enabled, .release);
    }

    pub fn init(self: *Tap, engine: *c.ma_engine) !void {
        if (self.initialized) return;

        const channels = c.ma_engine_get_channels(engine);
        if (channels == 0) return error.InvalidChannelCount;
        self.channels = channels;
        @memset(&self.ring, 0);
        self.write_pos.store(0, .release);

        var in_ch = [_]u32{channels};
        var out_ch = [_]u32{channels};

        var config = c.ma_node_config_init();
        config.vtable = &vtable;
        config.pInputChannels = &in_ch;
        config.pOutputChannels = &out_ch;

        const node_graph = c.ma_engine_get_node_graph(engine);
        if (c.ma_node_init(node_graph, &config, null, &self.base) != c.MA_SUCCESS) {
            return error.TapInitFailed;
        }
        errdefer c.ma_node_uninit(&self.base, null);

        const endpoint = c.ma_node_graph_get_endpoint(node_graph);
        if (c.ma_node_attach_output_bus(&self.base, 0, endpoint, 0) != c.MA_SUCCESS) {
            return error.TapAttachFailed;
        }

        self.initialized = true;
    }

    pub fn deinit(self: *Tap) void {
        if (!self.initialized) return;
        c.ma_node_uninit(&self.base, null);
        self.initialized = false;
    }

    pub fn asNodePtr(self: *Tap) *c.ma_node {
        return @ptrCast(&self.base);
    }

    pub fn readSnapshot(self: *Tap, out: []f32) void {
        const len = @min(out.len, RING_FRAMES);
        if (len == 0) return;
        const head = self.write_pos.load(.acquire);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const ring_idx = (head +% (RING_FRAMES - len + i)) & RING_MASK;
            out[i] = self.ring[ring_idx];
        }
        if (out.len > len) @memset(out[len..], 0);
    }
};
