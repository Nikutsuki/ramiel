//! Multi-series line plot. All primitives go through PaintContext + quad batcher.

const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;
const PaintContext = @import("../paint_context.zig").PaintContext;
const deriveChildId = @import("id.zig").deriveChildId;
const destroyOwnedEventUserdata = @import("../node.zig").destroyOwnedEventUserdata;

pub const Projection = struct {
    bounds_x: f32,
    bounds_y: f32,
    bounds_h: f32,
    x_offset: f64,
    x_scale: f64,
    y_offset: f64,
    y_scale: f64,

    pub fn fromState(
        state: *const PlotState,
        bounds_x: f32,
        bounds_y: f32,
        bounds_w: f32,
        bounds_h: f32,
    ) Projection {
        const view_w = state.view_x_max - state.view_x_min;
        const view_h = state.view_y_max - state.view_y_min;
        return .{
            .bounds_x = bounds_x,
            .bounds_y = bounds_y,
            .bounds_h = bounds_h,
            .x_offset = -state.view_x_min,
            .x_scale = if (view_w > 0.0) @as(f64, @floatCast(bounds_w)) / view_w else 0.0,
            .y_offset = -state.view_y_min,
            .y_scale = if (view_h > 0.0) @as(f64, @floatCast(bounds_h)) / view_h else 0.0,
        };
    }

    pub inline fn x(self: Projection, data_x: f64) f32 {
        return self.bounds_x + @as(f32, @floatCast((data_x + self.x_offset) * self.x_scale));
    }

    pub inline fn y(self: Projection, data_y: f64) f32 {
        return self.bounds_y + self.bounds_h - @as(f32, @floatCast((data_y + self.y_offset) * self.y_scale));
    }
};

/// 4-wide @Vector with scalar tail. Caller owns out.
pub fn projectXs(out: []f32, xs: []const f64, p: Projection) void {
    std.debug.assert(out.len >= xs.len);
    const Vec = @Vector(4, f64);
    const sx: Vec = @splat(p.x_scale);
    const ox: Vec = @splat(p.x_offset);
    var i: usize = 0;
    while (i + 4 <= xs.len) : (i += 4) {
        const v: Vec = xs[i..][0..4].*;
        const px = (v + ox) * sx;
        out[i + 0] = p.bounds_x + @as(f32, @floatCast(px[0]));
        out[i + 1] = p.bounds_x + @as(f32, @floatCast(px[1]));
        out[i + 2] = p.bounds_x + @as(f32, @floatCast(px[2]));
        out[i + 3] = p.bounds_x + @as(f32, @floatCast(px[3]));
    }
    while (i < xs.len) : (i += 1) {
        out[i] = p.x(xs[i]);
    }
}

/// Y is screen-flipped (data y_max -> top of surface).
pub fn projectYs(out: []f32, ys: []const f64, p: Projection) void {
    std.debug.assert(out.len >= ys.len);
    const Vec = @Vector(4, f64);
    const sy: Vec = @splat(p.y_scale);
    const oy: Vec = @splat(p.y_offset);
    const top = p.bounds_y + p.bounds_h;
    var i: usize = 0;
    while (i + 4 <= ys.len) : (i += 4) {
        const v: Vec = ys[i..][0..4].*;
        const py = (v + oy) * sy;
        out[i + 0] = top - @as(f32, @floatCast(py[0]));
        out[i + 1] = top - @as(f32, @floatCast(py[1]));
        out[i + 2] = top - @as(f32, @floatCast(py[2]));
        out[i + 3] = top - @as(f32, @floatCast(py[3]));
    }
    while (i < ys.len) : (i += 1) {
        out[i] = p.y(ys[i]);
    }
}

pub const SeriesKind = enum {
    line,
    scatter,
    bar,
};

pub const PlotLod = struct {
    allocator: std.mem.Allocator,
    levels: []Level,
    cached_xs_ptr: usize = 0,
    cached_xs_len: usize = 0,
    cached_ys_ptr: usize = 0,
    cached_ys_len: usize = 0,

    pub const Level = struct {
        stride: usize,
        y_min: []f64,
        y_max: []f64,
    };

    pub const THRESHOLD: usize = 64 * 1024;
    const MIN_LEVEL_BUCKETS: usize = 32;

    pub fn matchesIdentity(self: *const PlotLod, xs: []const f64, ys: []const f64) bool {
        return self.cached_xs_ptr == @intFromPtr(xs.ptr) and
            self.cached_xs_len == xs.len and
            self.cached_ys_ptr == @intFromPtr(ys.ptr) and
            self.cached_ys_len == ys.len;
    }

    pub fn build(allocator: std.mem.Allocator, xs: []const f64, ys: []const f64) !PlotLod {
        const n = ys.len;
        if (n < THRESHOLD) return .{
            .allocator = allocator,
            .levels = &.{},
            .cached_xs_ptr = @intFromPtr(xs.ptr),
            .cached_xs_len = xs.len,
            .cached_ys_ptr = @intFromPtr(ys.ptr),
            .cached_ys_len = ys.len,
        };

        var levels = std.ArrayList(Level).empty;
        errdefer {
            for (levels.items) |*lvl| {
                allocator.free(lvl.y_min);
                allocator.free(lvl.y_max);
            }
            levels.deinit(allocator);
        }

        var stride: usize = 2;
        var prev_min: ?[]f64 = null;
        var prev_max: ?[]f64 = null;
        var prev_count: usize = 0;

        while (true) {
            const count = (n + stride - 1) / stride;
            if (count < MIN_LEVEL_BUCKETS) break;

            const y_min = try allocator.alloc(f64, count);
            errdefer allocator.free(y_min);
            const y_max = try allocator.alloc(f64, count);
            errdefer allocator.free(y_max);

            if (prev_min) |pm| {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const a = i * 2;
                    const b = @min(prev_count - 1, a + 1);
                    y_min[i] = @min(pm[a], pm[b]);
                    y_max[i] = @max(prev_max.?[a], prev_max.?[b]);
                }
            } else {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const start = i * stride;
                    const end = @min(n, start + stride);
                    var lo = ys[start];
                    var hi = ys[start];
                    var j = start + 1;
                    while (j < end) : (j += 1) {
                        if (ys[j] < lo) lo = ys[j];
                        if (ys[j] > hi) hi = ys[j];
                    }
                    y_min[i] = lo;
                    y_max[i] = hi;
                }
            }

            try levels.append(allocator, .{ .stride = stride, .y_min = y_min, .y_max = y_max });
            prev_min = y_min;
            prev_max = y_max;
            prev_count = count;
            if (stride > n / 2) break;
            stride *= 2;
        }

        return .{
            .allocator = allocator,
            .levels = try levels.toOwnedSlice(allocator),
            .cached_xs_ptr = @intFromPtr(xs.ptr),
            .cached_xs_len = xs.len,
            .cached_ys_ptr = @intFromPtr(ys.ptr),
            .cached_ys_len = ys.len,
        };
    }

    pub fn deinit(self: *PlotLod) void {
        for (self.levels) |*lvl| {
            self.allocator.free(lvl.y_min);
            self.allocator.free(lvl.y_max);
        }
        if (self.levels.len != 0) self.allocator.free(self.levels);
        self.levels = &.{};
        self.cached_xs_ptr = 0;
        self.cached_xs_len = 0;
        self.cached_ys_ptr = 0;
        self.cached_ys_len = 0;
    }

    pub fn pickLevel(self: *const PlotLod, samples_per_pixel: f64) ?*const Level {
        if (self.levels.len == 0) return null;
        if (samples_per_pixel < 4.0) return null;
        var best: ?*const Level = null;
        for (self.levels) |*lvl| {
            const sf: f64 = @floatFromInt(lvl.stride);
            if (sf <= samples_per_pixel) best = lvl;
        }
        return best;
    }
};

fn makeLod(allocator: std.mem.Allocator, s: PlotSeries, want_lod: bool) PlotLod {
    if (want_lod) {
        return PlotLod.build(allocator, s.xs, s.ys) catch PlotLod{
            .allocator = allocator,
            .levels = &.{},
            .cached_xs_ptr = @intFromPtr(s.xs.ptr),
            .cached_xs_len = s.xs.len,
            .cached_ys_ptr = @intFromPtr(s.ys.ptr),
            .cached_ys_len = s.ys.len,
        };
    }
    return PlotLod{
        .allocator = allocator,
        .levels = &.{},
        .cached_xs_ptr = @intFromPtr(s.xs.ptr),
        .cached_xs_len = s.xs.len,
        .cached_ys_ptr = @intFromPtr(s.ys.ptr),
        .cached_ys_len = s.ys.len,
    };
}

pub const PlotSeries = struct {
    xs: []const f64,
    ys: []const f64,
    color: [4]f32 = .{ 0.4, 0.7, 1.0, 1.0 },
    line_width: f32 = 1.5,
    point_size: f32 = 0.0,
    label: []const u8 = "",
    kind: SeriesKind = .line,
    bar_baseline: f64 = 0.0,
    bar_gap: f32 = 0.0,
    /// Sorted X enables binary-search clip to viewport; set false for scatter.
    is_monotonic_x: bool = true,
};

pub const AxisMode = union(enum) {
    auto,
    fixed,
    follow: f64,
};

pub const ZoomModifier = enum {
    none,
    ctrl,
    shift,
    alt,
};

pub const PlotMsg = union(enum) {
    pan: struct { dx: f32, dy: f32 },
    zoom: struct { delta: f32, focus_x: f32, focus_y: f32 },
    hover: ?struct { x: f64, y: f64 },
};

pub const TickFormatter = *const fn (buf: []u8, value: f64, step: f64) anyerror![]const u8;

pub const PlotDescriptor = struct {
    style: layout.Style = .{},
    background_color: [4]f32 = .{ 0.05, 0.06, 0.08, 1.0 },
    grid_color: [4]f32 = .{ 1.0, 1.0, 1.0, 0.08 },
    axis_color: [4]f32 = .{ 1.0, 1.0, 1.0, 0.4 },
    target_grid_lines_x: u8 = 8,
    target_grid_lines_y: u8 = 6,
    axis_label_style: layout.Style = .{},
    axis_font: ?*FontData = null,
    x_tick_formatter: ?TickFormatter = null,
    y_tick_formatter: ?TickFormatter = null,
    x_tooltip_label: []const u8 = "x",
    y_tooltip_label: []const u8 = "y",
    margin_left: f32 = 48.0,
    margin_bottom: f32 = 24.0,
    margin_top: f32 = 8.0,
    margin_right: f32 = 8.0,
    enable_pan: bool = true,
    enable_zoom: bool = true,
    zoom_modifier: ZoomModifier = .none,
    show_crosshair: bool = true,
    crosshair_color: [4]f32 = .{ 1.0, 1.0, 1.0, 0.35 },
    bare: bool = false,
};

pub fn PlotContext(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        state: *PlotState,
        on_change: ?*const fn (PlotMsg, ?*const anyopaque) MessageT = null,
        userdata: ?*const anyopaque = null,
    };
}

pub const PlotState = struct {
    allocator: std.mem.Allocator,

    view_x_min: f64 = 0.0,
    view_x_max: f64 = 1.0,
    view_y_min: f64 = 0.0,
    view_y_max: f64 = 1.0,

    x_mode: AxisMode = .auto,
    y_mode: AxisMode = .auto,

    follow_x_window: ?f64 = null,
    follow_y_window: ?f64 = null,
    auto_reattach_eps: f64 = 0.05,

    hover_x: ?f64 = null,
    hover_y: ?f64 = null,

    revision: u64 = 0,

    series: []const PlotSeries = &.{},

    live_descriptor: PlotDescriptor = .{},

    pixel_width: f32 = 0,
    pixel_height: f32 = 0,
    hover_pixel_x: ?f32 = null,
    hover_pixel_y: ?f32 = null,
    surface_id: types.NodeId = 0,
    x_axis_id: types.NodeId = 0,
    y_axis_id: types.NodeId = 0,

    lods: std.ArrayList(PlotLod) = .empty,

    cached_data_x_min: f64 = 0.0,
    cached_data_x_max: f64 = 1.0,
    cached_data_y_min: f64 = 0.0,
    cached_data_y_max: f64 = 1.0,
    has_data_extents: bool = false,

    pub fn init(allocator: std.mem.Allocator) PlotState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PlotState) void {
        for (self.lods.items) |*lod| lod.deinit();
        self.lods.deinit(self.allocator);
    }

    pub fn setSeries(self: *PlotState, series: []const PlotSeries) void {
        self.lods.ensureTotalCapacity(self.allocator, series.len) catch {};
        var i: usize = 0;
        while (i < series.len) : (i += 1) {
            const s = series[i];
            const n = @min(s.xs.len, s.ys.len);
            const want_lod = s.is_monotonic_x and n >= PlotLod.THRESHOLD;
            if (i < self.lods.items.len) {
                const existing = &self.lods.items[i];
                if (existing.matchesIdentity(s.xs, s.ys)) continue;
                existing.deinit();
                existing.* = makeLod(self.allocator, s, want_lod);
            } else {
                self.lods.append(self.allocator, makeLod(self.allocator, s, want_lod)) catch {};
            }
        }
        while (self.lods.items.len > series.len) {
            var dropped = self.lods.pop().?;
            dropped.deinit();
        }
        self.series = series;
        self.fitView();
        self.revision +%= 1;
    }

    pub fn setXRange(self: *PlotState, x_min: f64, x_max: f64) void {
        self.view_x_min = x_min;
        self.view_x_max = @max(x_max, x_min + 1e-9);
        self.x_mode = .fixed;
        self.follow_x_window = null;
        self.revision +%= 1;
    }

    pub fn setYRange(self: *PlotState, y_min: f64, y_max: f64) void {
        self.view_y_min = y_min;
        self.view_y_max = @max(y_max, y_min + 1e-9);
        self.y_mode = .fixed;
        self.follow_y_window = null;
        self.revision +%= 1;
    }

    pub fn setView(self: *PlotState, x_min: f64, x_max: f64, y_min: f64, y_max: f64) void {
        self.setXRange(x_min, x_max);
        self.setYRange(y_min, y_max);
    }

    pub fn setAxisModes(self: *PlotState, x_mode: ?AxisMode, y_mode: ?AxisMode) void {
        if (x_mode) |m| {
            self.x_mode = m;
            self.follow_x_window = null;
        }
        if (y_mode) |m| {
            self.y_mode = m;
            self.follow_y_window = null;
        }
        self.fitView();
    }

    pub fn fitView(self: *PlotState) void {
        self.computeDataExtents();
        self.applyAxisModes();
    }

    fn computeDataExtents(self: *PlotState) void {
        var any = false;
        var x_min: f64 = std.math.inf(f64);
        var x_max: f64 = -std.math.inf(f64);
        var y_min: f64 = std.math.inf(f64);
        var y_max: f64 = -std.math.inf(f64);

        for (self.series) |s| {
            const n = @min(s.xs.len, s.ys.len);
            if (n == 0) continue;
            any = true;
            for (s.xs[0..n]) |x| {
                if (x < x_min) x_min = x;
                if (x > x_max) x_max = x;
            }
            for (s.ys[0..n]) |y| {
                if (y < y_min) y_min = y;
                if (y > y_max) y_max = y;
            }
        }

        if (!any) {
            x_min = 0.0;
            x_max = 1.0;
            y_min = 0.0;
            y_max = 1.0;
        }
        if (x_max - x_min < 1e-9) {
            x_min -= 0.5;
            x_max += 0.5;
        }
        if (y_max - y_min < 1e-9) {
            y_min -= 0.5;
            y_max += 0.5;
        }

        self.cached_data_x_min = x_min;
        self.cached_data_x_max = x_max;
        self.cached_data_y_min = y_min;
        self.cached_data_y_max = y_max;
        self.has_data_extents = true;
    }

    fn applyAxisModes(self: *PlotState) void {
        if (!self.has_data_extents) return;
        const x_min = self.cached_data_x_min;
        const x_max = self.cached_data_x_max;
        const y_min = self.cached_data_y_min;
        const y_max = self.cached_data_y_max;

        if (self.x_mode == .fixed) {
            if (self.follow_x_window) |w| {
                const view_w = self.view_x_max - self.view_x_min;
                const eps = @max(view_w, 1e-9) * self.auto_reattach_eps;
                if (@abs(self.view_x_max - x_max) < eps) {
                    self.x_mode = .{ .follow = w };
                    self.follow_x_window = null;
                }
            }
        }
        if (self.y_mode == .fixed) {
            if (self.follow_y_window) |w| {
                const view_h = self.view_y_max - self.view_y_min;
                const eps = @max(view_h, 1e-9) * self.auto_reattach_eps;
                if (@abs(self.view_y_max - y_max) < eps) {
                    self.y_mode = .{ .follow = w };
                    self.follow_y_window = null;
                }
            }
        }

        switch (self.x_mode) {
            .auto => {
                self.view_x_min = x_min;
                self.view_x_max = x_max;
            },
            .fixed => {},
            .follow => |window| {
                self.view_x_min = x_max - window;
                self.view_x_max = x_max;
            },
        }

        switch (self.y_mode) {
            .auto => {
                const pad = (y_max - y_min) * 0.05;
                self.view_y_min = y_min - pad;
                self.view_y_max = y_max + pad;
            },
            .fixed => {},
            .follow => |window| {
                self.view_y_min = y_max - window;
                self.view_y_max = y_max;
            },
        }
        self.revision +%= 1;
    }
};

pub fn applyPlotMsg(state: *PlotState, msg: PlotMsg) void {
    const px_w = state.pixel_width;
    const px_h = state.pixel_height;
    switch (msg) {
        .pan => |p| {
            const sx = if (px_w > 0.0)
                (state.view_x_max - state.view_x_min) / @as(f64, @floatCast(px_w))
            else
                0.0;
            const sy = if (px_h > 0.0)
                (state.view_y_max - state.view_y_min) / @as(f64, @floatCast(px_h))
            else
                0.0;
            const dx_data = -@as(f64, @floatCast(p.dx)) * sx;
            const dy_data = @as(f64, @floatCast(p.dy)) * sy;
            state.view_x_min += dx_data;
            state.view_x_max += dx_data;
            state.view_y_min += dy_data;
            state.view_y_max += dy_data;
            switch (state.x_mode) {
                .follow => |w| state.follow_x_window = w,
                else => {},
            }
            switch (state.y_mode) {
                .follow => |w| state.follow_y_window = w,
                else => {},
            }
            state.x_mode = .fixed;
            state.y_mode = .fixed;
            state.revision +%= 1;
        },
        .zoom => |z| {
            const factor: f64 = @floatCast(std.math.pow(f32, 1.1, -z.delta));
            const fx_norm: f64 = if (px_w > 0.0)
                @as(f64, @floatCast(z.focus_x)) / @as(f64, @floatCast(px_w))
            else
                0.5;
            const fy_norm: f64 = if (px_h > 0.0)
                1.0 - @as(f64, @floatCast(z.focus_y)) / @as(f64, @floatCast(px_h))
            else
                0.5;
            const x_anchor = state.view_x_min + (state.view_x_max - state.view_x_min) * fx_norm;
            const y_anchor = state.view_y_min + (state.view_y_max - state.view_y_min) * fy_norm;
            state.view_x_min = x_anchor + (state.view_x_min - x_anchor) * factor;
            state.view_x_max = x_anchor + (state.view_x_max - x_anchor) * factor;
            state.view_y_min = y_anchor + (state.view_y_min - y_anchor) * factor;
            state.view_y_max = y_anchor + (state.view_y_max - y_anchor) * factor;
            switch (state.x_mode) {
                .follow => |w| state.follow_x_window = w,
                else => {},
            }
            switch (state.y_mode) {
                .follow => |w| state.follow_y_window = w,
                else => {},
            }
            state.x_mode = .fixed;
            state.y_mode = .fixed;
            state.revision +%= 1;
        },
        .hover => |h| {
            if (h) |pt| {
                state.hover_x = pt.x;
                state.hover_y = pt.y;
            } else {
                state.hover_x = null;
                state.hover_y = null;
            }
            state.revision +%= 1;
        },
    }
}

fn niceStep(range: f64, target: u8) f64 {
    if (range <= 0.0 or target == 0) return 1.0;
    const raw = range / @as(f64, @floatFromInt(target));
    const exponent = @floor(std.math.log10(raw));
    const base = std.math.pow(f64, 10.0, exponent);
    const norm = raw / base;
    const nice: f64 = if (norm < 1.5) 1.0 else if (norm < 3.5) 2.0 else if (norm < 7.5) 5.0 else 10.0;
    return nice * base;
}

fn formatTick(buf: []u8, value: f64, step: f64) ![]const u8 {
    const log_step = std.math.log10(@max(@abs(step), 1e-300));
    const decimals_f: f64 = @max(0.0, -@floor(log_step));
    const decimals: u4 = @intFromFloat(@min(6.0, decimals_f));
    return std.fmt.bufPrint(buf, "{d:.[1]}", .{ value, decimals });
}

fn formatTickWith(formatter: ?TickFormatter, buf: []u8, value: f64, step: f64) ![]const u8 {
    if (formatter) |f| return f(buf, value, step);
    return formatTick(buf, value, step);
}

fn visibleRange(s: PlotSeries, x_min: f64, x_max: f64) struct { start: usize, end: usize } {
    const n = @min(s.xs.len, s.ys.len);
    if (n == 0) return .{ .start = 0, .end = 0 };

    if (s.is_monotonic_x) {
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.xs[mid] < x_min) lo = mid + 1 else hi = mid;
        }
        const first_in = lo;

        lo = first_in;
        hi = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.xs[mid] <= x_max) lo = mid + 1 else hi = mid;
        }
        const after_last = lo;

        const start = if (first_in > 0) first_in - 1 else 0;
        const end = @min(n, after_last + 1);
        return .{ .start = start, .end = end };
    }

    var first: ?usize = null;
    var last: ?usize = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = s.xs[i];
        if (x >= x_min and x <= x_max) {
            if (first == null) first = i;
            last = i;
        }
    }
    if (first == null) return .{ .start = 0, .end = 0 };
    const start = if (first.? > 0) first.? - 1 else 0;
    const end = @min(n, (last orelse 0) + 2);
    return .{ .start = start, .end = end };
}

fn surfacePaint(pctx: *PaintContext, userdata: ?*const anyopaque) anyerror!void {
    const state: *const PlotState = @ptrCast(@alignCast(userdata orelse return));
    const desc = state.live_descriptor;

    const b = pctx.bounds;
    if (b.width <= 0.0 or b.height <= 0.0) return;

    const view_w = state.view_x_max - state.view_x_min;
    const view_h = state.view_y_max - state.view_y_min;
    if (view_w <= 0.0 or view_h <= 0.0) return;

    const proj = Projection.fromState(state, b.x, b.y, b.width, b.height);

    try pctx.drawRect(b.x, b.y, b.width, b.height, desc.background_color);

    const step_x = niceStep(view_w, desc.target_grid_lines_x);
    const step_y = niceStep(view_h, desc.target_grid_lines_y);
    if (!desc.bare) {
        {
            const first_gx = @ceil(state.view_x_min / step_x) * step_x;
            var gx = first_gx;
            var safety: u32 = 0;
            while (gx <= state.view_x_max and safety < 256) : (safety += 1) {
                const px = proj.x(gx);
                try pctx.drawLine(px, b.y, px, b.y + b.height, 1.0, desc.grid_color);
                gx += step_x;
            }
        }
        {
            const first_gy = @ceil(state.view_y_min / step_y) * step_y;
            var gy = first_gy;
            var safety: u32 = 0;
            while (gy <= state.view_y_max and safety < 256) : (safety += 1) {
                const py = proj.y(gy);
                try pctx.drawLine(b.x, py, b.x + b.width, py, 1.0, desc.grid_color);
                gy += step_y;
            }
        }
    }

    const px_w = @as(usize, @intFromFloat(@max(1.0, b.width)));
    const decimate_threshold = px_w * 4;

    for (state.series, 0..) |s, series_idx| {
        const total = @min(s.xs.len, s.ys.len);
        if (total == 0) continue;

        if (total < 2) {
            const x = s.xs[0];
            const y = s.ys[0];
            const in_view = x >= state.view_x_min and x <= state.view_x_max and
                y >= state.view_y_min and y <= state.view_y_max;
            if (!in_view) continue;
            const px = proj.x(x);
            const py = proj.y(y);
            switch (s.kind) {
                .line, .scatter => if (s.point_size > 0.0)
                    try pctx.drawPoint(px, py, s.point_size, s.color),
                .bar => {
                    const baseline_py = proj.y(s.bar_baseline);
                    const top = @min(py, baseline_py);
                    const h = @abs(py - baseline_py);
                    try pctx.drawRect(px - 2.0, top, 4.0, h, s.color);
                },
            }
            continue;
        }

        const range = visibleRange(s, state.view_x_min, state.view_x_max);
        if (range.end <= range.start + 1) continue;
        const visible = range.end - range.start;

        try pctx.pushScissor(b.x, b.y, b.width, b.height, .{ 0, 0, 0, 0 });
        defer pctx.popScissor() catch {};

        switch (s.kind) {
            .line => {
                const samples_per_pixel = @as(f64, @floatFromInt(visible)) / @as(f64, @floatCast(b.width));
                const maybe_lod: ?*const PlotLod = if (series_idx < state.lods.items.len)
                    &state.lods.items[series_idx]
                else
                    null;
                const lod_level = if (maybe_lod) |lod| lod.pickLevel(samples_per_pixel) else null;

                if (lod_level) |lvl| {
                    try paintLod(pctx, s, lvl, proj, range.start, range.end);
                } else if (visible > decimate_threshold) {
                    try paintDecimated(pctx, s, proj, range.start, range.end);
                } else {
                    try paintRaw(pctx, s, proj, range.start, range.end);
                }
            },
            .scatter => try paintScatter(pctx, s, proj, range.start, range.end, px_w),
            .bar => try paintBar(pctx, s, proj, state, range.start, range.end, px_w),
        }
    }

    if (desc.show_crosshair and !desc.bare) {
        if (state.hover_pixel_x) |hx_local| {
            try pctx.pushScissor(b.x, b.y, b.width, b.height, .{ 0, 0, 0, 0 });
            defer pctx.popScissor() catch {};

            const hx = b.x + hx_local;
            try pctx.drawLine(hx, b.y, hx, b.y + b.height, 1.0, desc.crosshair_color);

            const x_data = state.view_x_min + (state.view_x_max - state.view_x_min) *
                @as(f64, @floatCast(hx_local / b.width));
            for (state.series) |s| {
                if (!s.is_monotonic_x) continue;
                const n = @min(s.xs.len, s.ys.len);
                if (n == 0) continue;
                if (x_data < s.xs[0] or x_data > s.xs[n - 1]) continue;
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (s.xs[mid] < x_data) lo = mid + 1 else hi = mid;
                }
                const j: usize = if (lo == 0) 0 else if (lo >= n)
                    n - 1
                else if (@abs(s.xs[lo] - x_data) < @abs(x_data - s.xs[lo - 1]))
                    lo
                else
                    lo - 1;
                if (s.xs[j] < state.view_x_min or s.xs[j] > state.view_x_max) break;
                if (s.ys[j] < state.view_y_min or s.ys[j] > state.view_y_max) break;
                const px = proj.x(s.xs[j]);
                const py = proj.y(s.ys[j]);
                const size = @max(6.0, s.point_size + 4.0);
                try pctx.drawPoint(px, py, size, .{ s.color[0], s.color[1], s.color[2], 0.85 });
                break;
            }
        }
    }
}

fn paintLod(
    pctx: *PaintContext,
    s: PlotSeries,
    lvl: *const PlotLod.Level,
    proj: Projection,
    sample_start: usize,
    sample_end: usize,
) !void {
    if (sample_end <= sample_start) return;
    const stride = lvl.stride;
    const n_buckets = lvl.y_min.len;
    if (n_buckets == 0) return;

    const start_b = @min(n_buckets, sample_start / stride);
    const end_b = @min(n_buckets, (sample_end + stride - 1) / stride);
    if (end_b <= start_b) return;

    var col_min: f64 = std.math.inf(f64);
    var col_max: f64 = -std.math.inf(f64);
    var col_first_bucket_x: f64 = 0.0;
    var prev_col_idx: i32 = std.math.minInt(i32);
    var prev_x_px: f32 = 0.0;
    var prev_min_py: f32 = 0.0;
    var prev_max_py: f32 = 0.0;
    var have_prev = false;

    var i: usize = start_b;
    while (i < end_b) : (i += 1) {
        const sample_idx = @min(s.xs.len - 1, i * stride + stride / 2);
        const x = s.xs[sample_idx];
        const ymin = lvl.y_min[i];
        const ymax = lvl.y_max[i];
        const col_idx: i32 = @intFromFloat(@floor((x + proj.x_offset) * proj.x_scale));

        if (col_idx != prev_col_idx) {
            if (prev_col_idx != std.math.minInt(i32)) {
                const xpx = proj.x(col_first_bucket_x);
                const min_py = proj.y(col_min);
                const max_py = proj.y(col_max);
                try pctx.drawLine(xpx, min_py, xpx, max_py, s.line_width, s.color);
                if (have_prev) {
                    try pctx.drawLine(prev_x_px, prev_max_py, xpx, max_py, s.line_width, s.color);
                    try pctx.drawLine(prev_x_px, prev_min_py, xpx, min_py, s.line_width, s.color);
                }
                prev_x_px = xpx;
                prev_min_py = min_py;
                prev_max_py = max_py;
                have_prev = true;
            }
            col_min = ymin;
            col_max = ymax;
            col_first_bucket_x = x;
            prev_col_idx = col_idx;
        } else {
            if (ymin < col_min) col_min = ymin;
            if (ymax > col_max) col_max = ymax;
        }
    }
    if (prev_col_idx != std.math.minInt(i32)) {
        const xpx = proj.x(col_first_bucket_x);
        const min_py = proj.y(col_min);
        const max_py = proj.y(col_max);
        try pctx.drawLine(xpx, min_py, xpx, max_py, s.line_width, s.color);
        if (have_prev) {
            try pctx.drawLine(prev_x_px, prev_max_py, xpx, max_py, s.line_width, s.color);
            try pctx.drawLine(prev_x_px, prev_min_py, xpx, min_py, s.line_width, s.color);
        }
    }
}

fn paintRaw(
    pctx: *PaintContext,
    s: PlotSeries,
    proj: Projection,
    start: usize,
    end: usize,
) !void {
    if (end <= start + 1) return;
    var i: usize = start + 1;
    var prev_px: f32 = proj.x(s.xs[start]);
    var prev_py: f32 = proj.y(s.ys[start]);
    while (i < end) : (i += 1) {
        const cx = proj.x(s.xs[i]);
        const cy = proj.y(s.ys[i]);
        try pctx.drawLine(prev_px, prev_py, cx, cy, s.line_width, s.color);
        prev_px = cx;
        prev_py = cy;
    }
    if (s.point_size > 0.0) {
        var j: usize = start;
        while (j < end) : (j += 1) {
            try pctx.drawPoint(proj.x(s.xs[j]), proj.y(s.ys[j]), s.point_size, s.color);
        }
    }
}

fn paintDecimated(
    pctx: *PaintContext,
    s: PlotSeries,
    proj: Projection,
    start: usize,
    end: usize,
) !void {
    if (end <= start + 1) return;

    var col_min: f64 = std.math.inf(f64);
    var col_max: f64 = -std.math.inf(f64);
    var col_start_x: f64 = s.xs[start];
    var prev_col_idx: i32 = std.math.minInt(i32);
    var prev_segment_min_y: f32 = 0.0;
    var prev_segment_max_y: f32 = 0.0;
    var prev_x_px: f32 = 0.0;
    var have_prev = false;

    var i: usize = start;
    while (i < end) : (i += 1) {
        const x = s.xs[i];
        const y = s.ys[i];
        const col_idx: i32 = @intFromFloat(@floor((x + proj.x_offset) * proj.x_scale));

        if (col_idx != prev_col_idx) {
            if (prev_col_idx != std.math.minInt(i32)) {
                const xpx = proj.x(col_start_x);
                const min_py = proj.y(col_min);
                const max_py = proj.y(col_max);
                try pctx.drawLine(xpx, min_py, xpx, max_py, s.line_width, s.color);
                if (have_prev) {
                    try pctx.drawLine(prev_x_px, prev_segment_max_y, xpx, max_py, s.line_width, s.color);
                    try pctx.drawLine(prev_x_px, prev_segment_min_y, xpx, min_py, s.line_width, s.color);
                }
                prev_x_px = xpx;
                prev_segment_min_y = min_py;
                prev_segment_max_y = max_py;
                have_prev = true;
            }
            col_min = y;
            col_max = y;
            col_start_x = x;
            prev_col_idx = col_idx;
        } else {
            if (y < col_min) col_min = y;
            if (y > col_max) col_max = y;
        }
    }
    if (prev_col_idx != std.math.minInt(i32)) {
        const xpx = proj.x(col_start_x);
        const min_py = proj.y(col_min);
        const max_py = proj.y(col_max);
        try pctx.drawLine(xpx, min_py, xpx, max_py, s.line_width, s.color);
        if (have_prev) {
            try pctx.drawLine(prev_x_px, prev_segment_max_y, xpx, max_py, s.line_width, s.color);
            try pctx.drawLine(prev_x_px, prev_segment_min_y, xpx, min_py, s.line_width, s.color);
        }
    }
}

fn paintScatter(
    pctx: *PaintContext,
    s: PlotSeries,
    proj: Projection,
    start: usize,
    end: usize,
    px_w: usize,
) !void {
    if (end <= start) return;
    if (s.point_size <= 0.0) return;

    const visible = end - start;
    const cap = px_w * 4;
    const step: usize = if (visible > cap) (visible + cap - 1) / cap else 1;

    var i: usize = start;
    while (i < end) : (i += step) {
        try pctx.drawPoint(proj.x(s.xs[i]), proj.y(s.ys[i]), s.point_size, s.color);
    }
}

fn paintBar(
    pctx: *PaintContext,
    s: PlotSeries,
    proj: Projection,
    state: *const PlotState,
    start: usize,
    end: usize,
    px_w: usize,
) !void {
    _ = state;
    if (end <= start) return;

    const baseline_py = proj.y(s.bar_baseline);
    const visible = end - start;
    const bounds_x: f32 = pctx.bounds.x;
    const bounds_w: f32 = pctx.bounds.width;

    if (visible >= px_w) {
        var col_min: f64 = std.math.inf(f64);
        var col_max: f64 = -std.math.inf(f64);
        var prev_col: i32 = std.math.minInt(i32);

        var i: usize = start;
        while (i < end) : (i += 1) {
            const x = s.xs[i];
            const y = s.ys[i];
            const col_f = (proj.x(x) - bounds_x);
            var col: i32 = @intFromFloat(@floor(col_f));
            if (col < 0) col = 0;
            if (col >= @as(i32, @intCast(px_w))) col = @intCast(px_w - 1);

            if (col != prev_col) {
                if (prev_col != std.math.minInt(i32)) {
                    try emitColumnBar(pctx, s, prev_col, bounds_x, bounds_w, col_min, col_max, baseline_py, proj);
                }
                col_min = y;
                col_max = y;
                prev_col = col;
            } else {
                if (y < col_min) col_min = y;
                if (y > col_max) col_max = y;
            }
        }
        if (prev_col != std.math.minInt(i32)) {
            try emitColumnBar(pctx, s, prev_col, bounds_x, bounds_w, col_min, col_max, baseline_py, proj);
        }
        return;
    }

    var i: usize = start;
    while (i < end) : (i += 1) {
        const x = s.xs[i];
        const half_left: f64 = if (i > start)
            (x - s.xs[i - 1]) * 0.5
        else if (i + 1 < end)
            (s.xs[i + 1] - x) * 0.5
        else
            0.5;
        const half_right: f64 = if (i + 1 < end)
            (s.xs[i + 1] - x) * 0.5
        else if (i > start)
            (x - s.xs[i - 1]) * 0.5
        else
            0.5;
        const x_lo_full: f32 = @floor(proj.x(x - half_left));
        const x_hi_full: f32 = @floor(proj.x(x + half_right));
        const full_w = x_hi_full - x_lo_full;
        if (full_w <= 0.0) continue;
        const max_inset = @max(0.0, (full_w - 1.0) * 0.5);
        const inset = std.math.clamp(s.bar_gap * 0.5, 0.0, max_inset);
        const x_lo = x_lo_full + inset;
        const w = full_w - inset * 2.0;

        const ypx = proj.y(s.ys[i]);
        const top = @min(ypx, baseline_py);
        const bottom = @max(ypx, baseline_py);
        const h = bottom - top;
        if (h <= 0.0) continue;
        try pctx.drawRect(x_lo, top, w, h, s.color);
    }
}

inline fn emitColumnBar(
    pctx: *PaintContext,
    s: PlotSeries,
    col: i32,
    bounds_x: f32,
    bounds_w: f32,
    col_min: f64,
    col_max: f64,
    baseline_py: f32,
    proj: Projection,
) !void {
    const min_py = proj.y(col_min);
    const max_py = proj.y(col_max);
    const top = @min(max_py, baseline_py);
    const bottom = @max(min_py, baseline_py);
    const h = bottom - top;
    if (h <= 0.0) return;
    const x: f32 = bounds_x + @as(f32, @floatFromInt(col));
    if (x < bounds_x or x > bounds_x + bounds_w) return;
    try pctx.drawRect(x, top, 1.0, h, s.color);
}

fn HandlerPayload(comptime MessageT: type) type {
    return struct {
        state: *PlotState,
        cb: *const fn (PlotMsg, ?*const anyopaque) MessageT,
        userdata: ?*const anyopaque,
        zoom_modifier: ZoomModifier = .none,
    };
}

// GLFW mod bitmask, inlined to avoid the glfw import.
const MOD_SHIFT: i32 = 0x0001;
const MOD_CONTROL: i32 = 0x0002;
const MOD_ALT: i32 = 0x0004;

inline fn zoomModifierMask(m: ZoomModifier) i32 {
    return switch (m) {
        .none => 0,
        .ctrl => MOD_CONTROL,
        .shift => MOD_SHIFT,
        .alt => MOD_ALT,
    };
}

fn dragHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn h(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const p: *const HandlerPayload(MessageT) = @ptrCast(@alignCast(userdata orelse return null));
            return switch (data) {
                .drag => |d| p.cb(.{ .pan = .{ .dx = d.dx, .dy = d.dy } }, p.userdata),
                else => null,
            };
        }
    }.h;
}

fn scrollHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn h(userdata: ?*const anyopaque, layout_snap: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const p: *const HandlerPayload(MessageT) = @ptrCast(@alignCast(userdata orelse return null));
            return switch (data) {
                .scroll => |s| {
                    const required = zoomModifierMask(p.zoom_modifier);
                    if (required != 0 and (s.mods & required) == 0) return null;

                    const fx = p.state.hover_pixel_x orelse (layout_snap.width * 0.5);
                    const fy = p.state.hover_pixel_y orelse (layout_snap.height * 0.5);
                    return p.cb(.{ .zoom = .{
                        .delta = s.dy,
                        .focus_x = fx,
                        .focus_y = fy,
                    } }, p.userdata);
                },
                else => null,
            };
        }
    }.h;
}

fn hoverHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn h(userdata: ?*const anyopaque, layout_snap: types.EventLayoutSnapshot, data: types.EventData) ?MessageT {
            const p: *const HandlerPayload(MessageT) = @ptrCast(@alignCast(userdata orelse return null));
            return switch (data) {
                .mouse => |m| {
                    const w = layout_snap.width;
                    const hh = layout_snap.height;
                    if (w <= 0.0 or hh <= 0.0) return null;
                    const local_x = m.x - layout_snap.x;
                    const local_y = m.y - layout_snap.y;
                    p.state.hover_pixel_x = local_x;
                    p.state.hover_pixel_y = local_y;
                    const fx = local_x / w;
                    const fy = 1.0 - local_y / hh;
                    const x_data = p.state.view_x_min + (p.state.view_x_max - p.state.view_x_min) * @as(f64, @floatCast(fx));
                    const y_data = p.state.view_y_min + (p.state.view_y_max - p.state.view_y_min) * @as(f64, @floatCast(fy));
                    return p.cb(.{ .hover = .{ .x = x_data, .y = y_data } }, p.userdata);
                },
                else => null,
            };
        }
    }.h;
}

fn hoverExitHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn h(userdata: ?*const anyopaque, _: types.EventLayoutSnapshot, _: types.EventData) ?MessageT {
            const p: *const HandlerPayload(MessageT) = @ptrCast(@alignCast(userdata orelse return null));
            p.state.hover_pixel_x = null;
            p.state.hover_pixel_y = null;
            return p.cb(.{ .hover = null }, p.userdata);
        }
    }.h;
}

fn postLayoutHook(comptime MessageT: type) *const fn (ctx: *UIContext(MessageT), userdata: *anyopaque) bool {
    return struct {
        fn h(ctx: *UIContext(MessageT), userdata: *anyopaque) bool {
            const state: *PlotState = @ptrCast(@alignCast(userdata));
            if (state.surface_id == 0) return false;
            const surface = ctx.getById(state.surface_id) orelse return false;
            const w = surface.layout_result.width;
            const hh = surface.layout_result.height;
            const w_changed = @abs(state.pixel_width - w) > 0.5;
            const h_changed = @abs(state.pixel_height - hh) > 0.5;
            if (w_changed or h_changed) {
                state.pixel_width = w;
                state.pixel_height = hh;
                state.revision +%= 1;
                ctx.interaction_registry.rebuild_requested = true;
                return false;
            }

            const desc = state.live_descriptor;
            const view_w = state.view_x_max - state.view_x_min;
            const view_h = state.view_y_max - state.view_y_min;
            var any_repositioned = false;

            if (view_w > 0.0 and w > 0.0) {
                if (ctx.getById(state.x_axis_id)) |axis| {
                    const step_x = niceStep(view_w, desc.target_grid_lines_x);
                    const first_gx = @ceil(state.view_x_min / step_x) * step_x;
                    var i: usize = 0;
                    var gx = first_gx;
                    var safety: u32 = 0;
                    while (i < axis.children.items.len and safety < 64) : (safety += 1) {
                        const child = axis.children.items[i];
                        const norm: f32 = @floatCast((gx - state.view_x_min) / view_w);
                        const target_x = norm * w;
                        const tw = child.layout_result.width;
                        const new_left = target_x - tw * 0.5;
                        const cur_left = child.style.left orelse 0.0;
                        if (@abs(cur_left - new_left) > 0.5) {
                            child.style.left = new_left;
                            child.markPositionDirty();
                            any_repositioned = true;
                        }
                        i += 1;
                        gx += step_x;
                    }
                }
            }

            if (view_h > 0.0 and hh > 0.0) {
                if (ctx.getById(state.y_axis_id)) |axis| {
                    const step_y = niceStep(view_h, desc.target_grid_lines_y);
                    const first_gy = @ceil(state.view_y_min / step_y) * step_y;
                    var i: usize = 0;
                    var gy = first_gy;
                    var safety: u32 = 0;
                    while (i < axis.children.items.len and safety < 64) : (safety += 1) {
                        const child = axis.children.items[i];
                        const norm: f32 = @floatCast((gy - state.view_y_min) / view_h);
                        const target_y = (1.0 - norm) * hh;
                        const th = child.layout_result.height;
                        const new_top = target_y - th * 0.5;
                        const cur_top = child.style.top orelse 0.0;
                        if (@abs(cur_top - new_top) > 0.5) {
                            child.style.top = new_top;
                            child.markPositionDirty();
                            any_repositioned = true;
                        }
                        i += 1;
                        gy += step_y;
                    }
                }
            }

            return any_repositioned;
        }
    }.h;
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: PlotContext(MessageT),
    descriptor: PlotDescriptor,
) !*Node(MessageT) {
    const arena = ctx.build_arena.allocator();

    const margin_left: f32 = if (descriptor.bare) 0.0 else descriptor.margin_left;
    const margin_right: f32 = if (descriptor.bare) 0.0 else descriptor.margin_right;
    const margin_top: f32 = if (descriptor.bare) 0.0 else descriptor.margin_top;
    const margin_bottom: f32 = if (descriptor.bare) 0.0 else descriptor.margin_bottom;

    logic.state.live_descriptor = descriptor;
    logic.state.surface_id = deriveChildId(logic.base_id, "surface");
    logic.state.x_axis_id = if (descriptor.bare) 0 else deriveChildId(logic.base_id, "axis_x");
    logic.state.y_axis_id = if (descriptor.bare) 0 else deriveChildId(logic.base_id, "axis_y");

    ctx.registerPostLayoutHook(.{
        .userdata = @ptrCast(logic.state),
        .callback = postLayoutHook(MessageT),
    }) catch {};

    var surface_style = layout.Style{
        .position = .absolute,
        .top = margin_top,
        .left = margin_left,
        .right = margin_right,
        .bottom = margin_bottom,
    };
    _ = &surface_style; // silence unused warning if any field changes later

    var surface_events = std.ArrayList(types.EventBinding(MessageT)).empty;
    defer surface_events.deinit(arena);

    if (logic.on_change) |cb| {
        if (descriptor.show_crosshair and !descriptor.bare) {
            const Payload = HandlerPayload(MessageT);
            const destroy = destroyOwnedEventUserdata(Payload);
            const move_payload = try ctx.gpa.create(Payload);
            move_payload.* = .{ .state = logic.state, .cb = cb, .userdata = logic.userdata };
            try surface_events.append(arena, .{
                .event = .pointer_move,
                .userdata = move_payload,
                .destroy_userdata = destroy,
                .handler = hoverHandler(MessageT),
            });
            const exit_payload = try ctx.gpa.create(Payload);
            exit_payload.* = .{ .state = logic.state, .cb = cb, .userdata = logic.userdata };
            try surface_events.append(arena, .{
                .event = .hover_exit,
                .userdata = exit_payload,
                .destroy_userdata = destroy,
                .handler = hoverExitHandler(MessageT),
            });
        }
    }

    const surface_node = try ctx.customPaint(.{
        .id = deriveChildId(logic.base_id, "surface"),
        .style = surface_style,
        .paint_fn = surfacePaint,
        .userdata = @ptrCast(logic.state),
        .revision = logic.state.revision,
        .events = try surface_events.toOwnedSlice(arena),
    });

    var x_axis_children = std.ArrayList(?*Node(MessageT)).empty;
    defer x_axis_children.deinit(arena);
    var y_axis_children = std.ArrayList(?*Node(MessageT)).empty;
    defer y_axis_children.deinit(arena);

    if (!descriptor.bare) {
        if (descriptor.axis_font) |font| {
            const view_w = logic.state.view_x_max - logic.state.view_x_min;
            const view_h = logic.state.view_y_max - logic.state.view_y_min;
            const px_w = logic.state.pixel_width;
            const px_h = logic.state.pixel_height;
            if (view_w > 0.0 and view_h > 0.0 and px_w > 0.0 and px_h > 0.0) {
                const step_x = niceStep(view_w, descriptor.target_grid_lines_x);
                const step_y = niceStep(view_h, descriptor.target_grid_lines_y);

                const first_gx = @ceil(logic.state.view_x_min / step_x) * step_x;
                var gx = first_gx;
                var safety_x: u32 = 0;
                while (gx <= logic.state.view_x_max and safety_x < 64) : (safety_x += 1) {
                    const buf = try arena.alloc(u8, 32);
                    const text_slice = formatTickWith(descriptor.x_tick_formatter, buf, gx, step_x) catch "";
                    const norm: f32 = @floatCast((gx - logic.state.view_x_min) / view_w);
                    var ts = descriptor.axis_label_style;
                    ts.position = .absolute;
                    ts.left = norm * px_w - 16.0; // approximate centre offset
                    ts.top = 4.0;
                    if (ts.text_color.a == 0) ts.text_color = layout.Color.from(descriptor.axis_color);
                    const label = try ctx.text(.{
                        .style = ts,
                        .content = text_slice,
                        .font = font,
                    });
                    try x_axis_children.append(arena, label);
                    gx += step_x;
                }

                const first_gy = @ceil(logic.state.view_y_min / step_y) * step_y;
                var gy = first_gy;
                var safety_y: u32 = 0;
                while (gy <= logic.state.view_y_max and safety_y < 64) : (safety_y += 1) {
                    const buf = try arena.alloc(u8, 32);
                    const text_slice = formatTickWith(descriptor.y_tick_formatter, buf, gy, step_y) catch "";
                    const norm: f32 = @floatCast((gy - logic.state.view_y_min) / view_h);
                    var ts = descriptor.axis_label_style;
                    ts.position = .absolute;
                    ts.right = 4.0;
                    ts.top = (1.0 - norm) * px_h - 6.0;
                    if (ts.text_color.a == 0) ts.text_color = layout.Color.from(descriptor.axis_color);
                    const label = try ctx.text(.{
                        .style = ts,
                        .content = text_slice,
                        .font = font,
                    });
                    try y_axis_children.append(arena, label);
                    gy += step_y;
                }
            }
        }
    }

    const x_axis_node: ?*Node(MessageT) = if (descriptor.bare) null else try ctx.div(.{
        .id = deriveChildId(logic.base_id, "axis_x"),
        .style = .{
            .position = .absolute,
            .left = descriptor.margin_left,
            .right = descriptor.margin_right,
            .bottom = 0.0,
            .height = .{ .exact = descriptor.margin_bottom },
        },
        .children = try x_axis_children.toOwnedSlice(arena),
    });

    const y_axis_node: ?*Node(MessageT) = if (descriptor.bare) null else try ctx.div(.{
        .id = deriveChildId(logic.base_id, "axis_y"),
        .style = .{
            .position = .absolute,
            .left = 0.0,
            .top = descriptor.margin_top,
            .bottom = descriptor.margin_bottom,
            .width = .{ .exact = descriptor.margin_left },
        },
        .children = try y_axis_children.toOwnedSlice(arena),
    });

    const tooltip_node: ?*Node(MessageT) = blk: {
        if (descriptor.bare or !descriptor.show_crosshair) break :blk null;
        const font = descriptor.axis_font orelse break :blk null;
        const hx_local = logic.state.hover_pixel_x orelse break :blk null;
        const hy_local = logic.state.hover_pixel_y orelse break :blk null;
        const px_w = logic.state.pixel_width;
        const px_h = logic.state.pixel_height;
        if (px_w <= 0.0 or px_h <= 0.0) break :blk null;

        const x_data = logic.state.view_x_min + (logic.state.view_x_max - logic.state.view_x_min) *
            @as(f64, @floatCast(hx_local / px_w));

        var snap_x: ?f64 = null;
        var snap_y: ?f64 = null;
        for (logic.state.series) |s| {
            if (!s.is_monotonic_x) continue;
            const n = @min(s.xs.len, s.ys.len);
            if (n == 0) continue;
            if (x_data < s.xs[0] or x_data > s.xs[n - 1]) continue;
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (s.xs[mid] < x_data) lo = mid + 1 else hi = mid;
            }
            const j: usize = if (lo == 0) 0 else if (lo >= n)
                n - 1
            else if (@abs(s.xs[lo] - x_data) < @abs(x_data - s.xs[lo - 1]))
                lo
            else
                lo - 1;
            if (s.xs[j] < logic.state.view_x_min or s.xs[j] > logic.state.view_x_max) break;
            if (s.ys[j] < logic.state.view_y_min or s.ys[j] > logic.state.view_y_max) break;
            snap_x = s.xs[j];
            snap_y = s.ys[j];
            break;
        }
        if (snap_x == null) break :blk null;

        const buf = try arena.alloc(u8, 64);
        var x_buf: [64]u8 = undefined;
        var y_buf: [64]u8 = undefined;
        const x_text = formatTickWith(descriptor.x_tick_formatter, &x_buf, snap_x.?, 0.001) catch break :blk null;
        const y_text = formatTickWith(descriptor.y_tick_formatter, &y_buf, snap_y.?, 0.001) catch break :blk null;
        const text_slice = std.fmt.bufPrint(buf, "{s}: {s}\n{s}: {s}", .{
            descriptor.x_tooltip_label,
            x_text,
            descriptor.y_tooltip_label,
            y_text,
        }) catch break :blk null;

        const text_node = try ctx.text(.{
            .style = .{
                .text_color = layout.Color.from(.{ 1.0, 1.0, 1.0, 1.0 }),
                .font_size = 11,
                .pointer_events = .none,
            },
            .content = text_slice,
            .font = font,
        });

        const offset_x: f32 = 12.0;
        const flip_threshold: f32 = px_w * 0.6;
        const tooltip_left: f32 = if (hx_local > flip_threshold)
            margin_left + hx_local - 100.0
        else
            margin_left + hx_local + offset_x;
        const tooltip_top: f32 = @max(0.0, margin_top + hy_local - 36.0);

        break :blk try ctx.div(.{
            .id = deriveChildId(logic.base_id, "tooltip"),
            .style = .{
                .position = .absolute,
                .left = tooltip_left,
                .top = tooltip_top,
                .padding = .{ .top = 4, .bottom = 4, .left = 8, .right = 8 },
                .background_color = layout.Color.from(.{ 0.0, 0.0, 0.0, 0.75 }),
                .corner_radius = layout.CornerRadius.all(4),
                .pointer_events = .none,
                .z_index = 10,
            },
            .children = &.{text_node},
        });
    };

    var root_events = std.ArrayList(types.EventBinding(MessageT)).empty;
    defer root_events.deinit(arena);

    if (logic.on_change) |cb| {
        const Payload = HandlerPayload(MessageT);
        const destroy = destroyOwnedEventUserdata(Payload);
        if (descriptor.enable_pan) {
            const payload = try ctx.gpa.create(Payload);
            payload.* = .{ .state = logic.state, .cb = cb, .userdata = logic.userdata };
            try root_events.append(arena, .{
                .event = .drag,
                .userdata = payload,
                .destroy_userdata = destroy,
                .handler = dragHandler(MessageT),
            });
        }
        if (descriptor.enable_zoom) {
            const payload = try ctx.gpa.create(Payload);
            payload.* = .{
                .state = logic.state,
                .cb = cb,
                .userdata = logic.userdata,
                .zoom_modifier = descriptor.zoom_modifier,
            };
            try root_events.append(arena, .{
                .event = .scroll,
                .userdata = payload,
                .destroy_userdata = destroy,
                .handler = scrollHandler(MessageT),
            });
        }
    }

    var root_style = descriptor.style;
    root_style.position = if (root_style.position == .absolute) .absolute else root_style.position;
    if (root_style.width == .Auto) root_style.width = .Full;
    if (root_style.height == .Auto) root_style.height = .Full;

    const root_children = try arena.dupe(?*Node(MessageT), &.{
        surface_node,
        x_axis_node,
        y_axis_node,
        tooltip_node,
    });

    return ctx.div(.{
        .id = logic.base_id,
        .style = root_style,
        .events = try root_events.toOwnedSlice(arena),
        .children = root_children,
    });
}

test "niceStep produces 1/2/5 multiples" {
    try std.testing.expectApproxEqRel(@as(f64, 0.1), niceStep(1.0, 10), 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), niceStep(8.0, 8), 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 2.0), niceStep(15.0, 8), 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 5.0), niceStep(40.0, 8), 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 1000.0), niceStep(8000.0, 8), 1e-9);
}

test "fitView covers all series with padding" {
    var state = PlotState.init(std.testing.allocator);
    defer state.deinit();
    const xs = [_]f64{ 0.0, 1.0, 2.0 };
    const ys = [_]f64{ -1.0, 0.0, 3.0 };
    const series = [_]PlotSeries{.{ .xs = &xs, .ys = &ys }};
    state.setSeries(&series);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), state.view_x_min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), state.view_x_max, 1e-9);
    try std.testing.expect(state.view_y_min < -1.0);
    try std.testing.expect(state.view_y_max > 3.0);
}

test "applyPlotMsg pan shifts view by pixel-equivalent data delta" {
    var state = PlotState.init(std.testing.allocator);
    defer state.deinit();
    state.setView(0.0, 100.0, 0.0, 100.0);
    state.pixel_width = 100.0;
    state.pixel_height = 100.0;
    applyPlotMsg(&state, .{ .pan = .{ .dx = 10.0, .dy = 0.0 } });
    try std.testing.expectApproxEqAbs(@as(f64, -10.0), state.view_x_min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), state.view_x_max, 1e-9);
}

test "applyPlotMsg zoom keeps focus point fixed" {
    var state = PlotState.init(std.testing.allocator);
    defer state.deinit();
    state.setView(0.0, 100.0, 0.0, 100.0);
    state.pixel_width = 100.0;
    state.pixel_height = 100.0;
    applyPlotMsg(&state, .{ .zoom = .{ .delta = 1.0, .focus_x = 50.0, .focus_y = 50.0 } });
    const new_w = state.view_x_max - state.view_x_min;
    try std.testing.expect(new_w < 100.0);
    const new_centre = (state.view_x_min + state.view_x_max) * 0.5;
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), new_centre, 1e-6);
}

test "Plot-8: pan-from-follow captures window then auto-reattaches at edge" {
    var state = PlotState.init(std.testing.allocator);
    defer state.deinit();
    state.x_mode = .{ .follow = 10.0 };
    state.y_mode = .fixed;
    state.view_y_min = -1.0;
    state.view_y_max = 1.0;
    state.pixel_width = 100.0;
    state.pixel_height = 100.0;

    var xs: [11]f64 = undefined;
    var ys: [11]f64 = undefined;
    for (&xs, &ys, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i);
        y.* = 0.0;
    }
    const series = [_]PlotSeries{.{ .xs = &xs, .ys = &ys }};
    state.setSeries(&series);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), state.view_x_min, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), state.view_x_max, 1e-9);

    applyPlotMsg(&state, .{ .pan = .{ .dx = 30.0, .dy = 0.0 } });
    try std.testing.expectEqual(AxisMode.fixed, state.x_mode);
    try std.testing.expect(state.follow_x_window != null);
    try std.testing.expectEqual(@as(f64, 10.0), state.follow_x_window.?);

    state.setSeries(&series);
    try std.testing.expectEqual(AxisMode.fixed, state.x_mode);

    state.view_x_min = 0.0;
    state.view_x_max = 10.0;
    state.setSeries(&series);
    switch (state.x_mode) {
        .follow => |w| try std.testing.expectEqual(@as(f64, 10.0), w),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(state.follow_x_window == null);
}

test "Plot-10: setSeries with identical slice identity skips LOD rebuild" {
    var state = PlotState.init(std.testing.allocator);
    defer state.deinit();

    const n = PlotLod.THRESHOLD + 64;
    const xs = try std.testing.allocator.alloc(f64, n);
    defer std.testing.allocator.free(xs);
    const ys = try std.testing.allocator.alloc(f64, n);
    defer std.testing.allocator.free(ys);
    for (xs, 0..) |*x, i| x.* = @floatFromInt(i);
    @memset(ys, 0.0);

    const series = [_]PlotSeries{.{ .xs = xs, .ys = ys }};
    state.setSeries(&series);
    try std.testing.expect(state.lods.items.len == 1);
    const first_levels_ptr = state.lods.items[0].levels.ptr;
    try std.testing.expect(state.lods.items[0].levels.len > 0);

    state.setSeries(&series);
    try std.testing.expectEqual(first_levels_ptr, state.lods.items[0].levels.ptr);
}
