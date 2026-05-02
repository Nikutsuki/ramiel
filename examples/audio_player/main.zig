//! Audio player: library tree, oscilloscope, seek + transport.

const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const layout = lib.layout;
const Style = layout.Style;
const Spacing = layout.Spacing;
const comp = lib.components;
const PlotState = comp.PlotState;
const PlotSeries = comp.PlotSeries;
const PlotMsg = comp.PlotMsg;
const TreeMessage = comp.TreeMessage;

const WAVE_SAMPLES: usize = 4096;
const SPECTRUM_BANDS_DEFAULT: usize = 64;
const SPECTRUM_BANDS_MIN: usize = 16;
const SPECTRUM_BANDS_MAX: usize = 256;

const MirrorMode = enum {
    none,
    x_axis, // top + bottom (mirrored across the horizontal axis)
    y_axis, // left + right (mirrored across the vertical axis)
};

const MIRROR_OPTIONS: [3][]const u8 = .{ "no mirror", "x axis (top + bottom)", "y axis (left + right)" };

const AppMessage = union(enum) {
    tree_msg: TreeMessage([]const u8),
    seek: f32,
    toggle_play,
    stop,
    waveform_msg: PlotMsg,
    mirror_dropdown_toggle: bool,
    mirror_select: usize,
    smoothing_change: f32,
    bands_change: f32,
    sensitivity_change: f32,
    bar_gap_change: f32,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const App = lib.Application(AppState, AppMessage);

const NodeIds = lib.declareIds(.{
    "library_tree",
    "seek_slider",
    "play_btn",
    "stop_btn",
    "waveform_plot",
    "spectrum_plot",
    "mirror_dropdown",
    "smoothing_slider",
    "bands_slider",
    "sensitivity_slider",
    "bar_gap_slider",
}){};

const TreeItem = struct {
    id: []const u8,
    label: []const u8,
    is_group: bool = false,
    abs_path: ?[:0]const u8 = null,
    children: std.ArrayList(TreeItem) = .empty,

    fn deinit(self: *TreeItem, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.label);
        if (self.abs_path) |p| allocator.free(p);
    }
};

fn isAudioExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp3", ".wav", ".flac", ".ogg", ".m4a" };
    for (exts) |ext| {
        if (name.len < ext.len) continue;
        const tail = name[name.len - ext.len ..];
        if (std.ascii.eqlIgnoreCase(tail, ext)) return true;
    }
    return false;
}

fn scanDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    abs_dir: []const u8,
    depth_remaining: u32,
    out: *std.ArrayList(TreeItem),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, abs_dir, .{ .iterate = true }) catch |err| {
        std.log.warn("audio_player: cannot open {s}: {s}", .{ abs_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ abs_dir, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                if (!isAudioExt(entry.name)) continue;
                const id = try allocator.dupe(u8, full_path);
                const label = try allocator.dupe(u8, entry.name);
                const abs_path_z = try allocator.dupeZ(u8, full_path);
                try out.append(allocator, .{
                    .id = id,
                    .label = label,
                    .abs_path = abs_path_z,
                });
            },
            .directory => {
                if (depth_remaining == 0) continue;
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                var group: TreeItem = .{
                    .id = try allocator.dupe(u8, full_path),
                    .label = try allocator.dupe(u8, entry.name),
                    .is_group = true,
                };
                try scanDir(allocator, io, full_path, depth_remaining - 1, &group.children);
                if (group.children.items.len == 0) {
                    var g = group;
                    g.deinit(allocator);
                    continue;
                }
                try out.append(allocator, group);
            },
            else => {},
        }
    }
}

fn findItemById(items: []const TreeItem, id: []const u8) ?*const TreeItem {
    for (items) |*item| {
        if (std.mem.eql(u8, item.id, id)) return item;
        if (item.is_group) {
            if (findItemById(item.children.items, id)) |it| return it;
        }
    }
    return null;
}

const SeekWorker = struct {
    app: *App,
    target_us: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),
    should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seeking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn submit(self: *SeekWorker, seconds: f32) void {
        const us: i64 = @intFromFloat(@as(f64, seconds) * 1_000_000.0);
        self.target_us.store(us, .release);
    }

    fn isSeeking(self: *const SeekWorker) bool {
        return self.seeking.load(.acquire);
    }

    fn isActive(self: *const SeekWorker) bool {
        return self.seeking.load(.acquire) or self.target_us.load(.acquire) >= 0;
    }

    fn run(self: *SeekWorker) void {
        const io = self.app.io;
        const settle_ms: i64 = 120;
        const idle_poll_ms: i64 = 15;

        while (!self.should_exit.load(.acquire)) {
            const target = self.target_us.load(.acquire);
            if (target < 0) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(idle_poll_ms), .awake) catch {};
                continue;
            }

            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(settle_ms), .awake) catch {};
            if (self.should_exit.load(.acquire)) break;

            const after = self.target_us.load(.acquire);
            if (after < 0) continue; // someone else claimed (shouldn't happen with one worker)
            if (after != target) continue; // target moved — keep settling

            const claimed = self.target_us.swap(-1, .acq_rel);
            if (claimed < 0) continue;
            const seconds: f32 = @floatCast(@as(f64, @floatFromInt(claimed)) / 1_000_000.0);

            const state = &self.app.state;
            if (state.playback_id) |pid| {
                self.seeking.store(true, .release);
                self.app.seekStream(pid, seconds);
                self.seeking.store(false, .release);
            }
        }
    }

    fn shutdown(self: *SeekWorker) void {
        self.should_exit.store(true, .release);
    }
};

const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    font_data: *lib.FontData = undefined,

    library: std.ArrayList(TreeItem) = .empty,
    tree_state: comp.tree.TreeState([]const u8),

    current_path: ?[:0]const u8 = null,
    current_label: ?[]const u8 = null,
    playback_id: ?u64 = null,

    wave_samples: []f32 = &.{},
    wave_xs: []f64 = &.{},
    wave_ys: []f64 = &.{},
    wave_series: [1]PlotSeries = undefined,
    wave_state: PlotState = undefined,

    spectrum: lib.audio_spectrum.Analyzer = undefined,
    spectrum_xs: []f64 = &.{},
    spectrum_ys_pos: []f64 = &.{},
    spectrum_ys_neg: []f64 = &.{},
    spectrum_series_buf: [2]PlotSeries = undefined,
    spectrum_state: PlotState = undefined,
    spectrum_sample_rate: f32 = 44100.0,

    mirror_mode: MirrorMode = .y_axis,
    mirror_dropdown_open: bool = false,
    smoothing: f32 = 0.85,
    n_bands: usize = SPECTRUM_BANDS_DEFAULT,
    sensitivity: f32 = 1.0,
    bar_gap: f32 = 0.0,

    cursor_seconds: f32 = 0,
    duration_seconds: f32 = 0,
    last_known_playing: bool = false,

    app: ?*App = null,

    seek_worker: SeekWorker = undefined,
    seek_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AppState {
        var st: AppState = .{
            .allocator = allocator,
            .io = io,
            .tree_state = comp.tree.TreeState([]const u8).init(allocator),
        };
        st.wave_state = PlotState.init(allocator);
        st.spectrum_state = PlotState.init(allocator);
        return st;
    }

    pub fn deinit(self: *AppState) void {
        if (self.seek_thread) |t| {
            self.seek_worker.shutdown();
            t.join();
            self.seek_thread = null;
        }
        for (self.library.items) |*item| item.deinit(self.allocator);
        self.library.deinit(self.allocator);
        self.tree_state.deinit();
        if (self.current_path) |p| self.allocator.free(p);
        if (self.current_label) |l| self.allocator.free(l);
        self.allocator.free(self.wave_samples);
        self.allocator.free(self.wave_xs);
        self.allocator.free(self.wave_ys);
        self.wave_state.deinit();

        self.spectrum.deinit();
        self.allocator.free(self.spectrum_xs);
        self.allocator.free(self.spectrum_ys_pos);
        self.allocator.free(self.spectrum_ys_neg);
        self.spectrum_state.deinit();
    }

    fn initWaveBuffers(self: *AppState) !void {
        self.wave_samples = try self.allocator.alloc(f32, WAVE_SAMPLES);
        self.wave_xs = try self.allocator.alloc(f64, WAVE_SAMPLES);
        self.wave_ys = try self.allocator.alloc(f64, WAVE_SAMPLES);
        @memset(self.wave_samples, 0);
        @memset(self.wave_ys, 0);
        for (self.wave_xs, 0..) |*x, i| x.* = @floatFromInt(i);

        self.wave_series[0] = .{
            .xs = self.wave_xs,
            .ys = self.wave_ys,
            .color = .{ 0.4, 0.85, 0.6, 1.0 },
            .line_width = 1.5,
            .kind = .line,
        };
        self.wave_state.setSeries(&self.wave_series);
        self.wave_state.setXRange(0.0, @floatFromInt(WAVE_SAMPLES - 1));
        self.wave_state.setYRange(-1.05, 1.05);
    }

    fn initSpectrumBuffers(self: *AppState, sample_rate: f32) !void {
        self.spectrum_sample_rate = sample_rate;
        try self.allocSpectrumStorage(self.n_bands);
        self.spectrum.decay = self.smoothing;
        self.refreshSpectrumLayout();
    }

    fn allocSpectrumStorage(self: *AppState, n_bands: usize) !void {
        if (self.spectrum_xs.len != 0) {
            self.spectrum.deinit();
            self.allocator.free(self.spectrum_xs);
            self.allocator.free(self.spectrum_ys_pos);
            self.allocator.free(self.spectrum_ys_neg);
        }

        self.spectrum = try lib.audio_spectrum.Analyzer.init(
            self.allocator,
            WAVE_SAMPLES,
            n_bands,
            self.spectrum_sample_rate,
        );
        const display_n = n_bands * 2; // worst-case for y-axis mirror
        self.spectrum_xs = try self.allocator.alloc(f64, display_n);
        self.spectrum_ys_pos = try self.allocator.alloc(f64, display_n);
        self.spectrum_ys_neg = try self.allocator.alloc(f64, display_n);
        @memset(self.spectrum_ys_pos, 0);
        @memset(self.spectrum_ys_neg, 0);
        for (self.spectrum_xs, 0..) |*x, i| x.* = @floatFromInt(i);
        self.n_bands = n_bands;
    }

    fn refreshSpectrumLayout(self: *AppState) void {
        const n = self.n_bands;
        const color: [4]f32 = .{ 0.55, 0.75, 1.0, 1.0 };

        const display_width: f64 = switch (self.mirror_mode) {
            .none, .x_axis => @floatFromInt(n - 1),
            .y_axis => @floatFromInt(2 * n - 1),
        };
        self.spectrum_state.setXRange(0.0, display_width);
        switch (self.mirror_mode) {
            .none => self.spectrum_state.setYRange(0.0, 1.05),
            .x_axis => self.spectrum_state.setYRange(-1.05, 1.05),
            .y_axis => self.spectrum_state.setYRange(0.0, 1.05),
        }

        const visible_n: usize = switch (self.mirror_mode) {
            .none, .x_axis => n,
            .y_axis => 2 * n,
        };

        self.spectrum_series_buf[0] = .{
            .xs = self.spectrum_xs[0..visible_n],
            .ys = self.spectrum_ys_pos[0..visible_n],
            .color = color,
            .kind = .bar,
            .bar_baseline = 0.0,
            .bar_gap = self.bar_gap,
        };
        if (self.mirror_mode == .x_axis) {
            self.spectrum_series_buf[1] = .{
                .xs = self.spectrum_xs[0..visible_n],
                .ys = self.spectrum_ys_neg[0..visible_n],
                .color = color,
                .kind = .bar,
                .bar_baseline = 0.0,
                .bar_gap = self.bar_gap,
            };
            self.spectrum_state.setSeries(self.spectrum_series_buf[0..2]);
        } else {
            self.spectrum_state.setSeries(self.spectrum_series_buf[0..1]);
        }
    }

    fn setBandCount(self: *AppState, n_bands: usize) void {
        const clamped = std.math.clamp(n_bands, SPECTRUM_BANDS_MIN, SPECTRUM_BANDS_MAX);
        if (clamped == self.n_bands) return;
        self.allocSpectrumStorage(clamped) catch |err| {
            std.log.err("audio_player: spectrum rebuild failed: {s}", .{@errorName(err)});
            return;
        };
        self.spectrum.decay = self.smoothing;
        self.refreshSpectrumLayout();
    }

    fn setMirrorMode(self: *AppState, mode: MirrorMode) void {
        if (self.mirror_mode == mode) return;
        self.mirror_mode = mode;
        self.refreshSpectrumLayout();
    }

    fn setBarGap(self: *AppState, gap: f32) void {
        const clamped = std.math.clamp(gap, 0.0, 16.0);
        if (clamped == self.bar_gap) return;
        self.bar_gap = clamped;
        self.refreshSpectrumLayout();
    }

    fn loadTrack(self: *AppState, path: [:0]const u8, label: []const u8) !void {
        if (self.playback_id) |pid| {
            self.app.?.stopSound(pid);
            self.playback_id = null;
        }
        if (self.current_path) |p| self.allocator.free(p);
        if (self.current_label) |l| self.allocator.free(l);

        self.current_path = try self.allocator.dupeZ(u8, path);
        self.current_label = try self.allocator.dupe(u8, label);
        self.cursor_seconds = 0;
        self.duration_seconds = 0;

        self.playback_id = self.app.?.playAudioStream(self.current_path.?);
    }
};

fn update(app: *App, msg: T.InteractionMessage) lib.UpdateAction {
    const state = &app.state;
    switch (msg.id) {
        .tree_msg => |tm| {
            switch (tm) {
                .click => |c| {
                    if (findItemById(state.library.items, c.id)) |item| {
                        if (!item.is_group) {
                            if (item.abs_path) |p| {
                                state.loadTrack(p, item.label) catch |err| {
                                    std.log.err("audio_player: loadTrack failed: {s}", .{@errorName(err)});
                                };
                            }
                        }
                    }
                },
                else => {},
            }
            comp.tree.update([]const u8, TreeItem, &state.tree_state, state.library.items, tm) catch {};
            return .rebuild;
        },
        .seek => |seconds| {
            state.cursor_seconds = seconds;
            if (state.playback_id != null) {
                state.seek_worker.submit(seconds);
            }
            return .rebuild;
        },
        .toggle_play => {
            if (state.playback_id) |pid| {
                if (app.isStreamPlaying(pid)) {
                    app.pauseStream(pid);
                } else {
                    app.resumeStream(pid);
                }
            }
            return .rebuild;
        },
        .stop => {
            if (state.playback_id) |pid| app.stopSound(pid);
            state.playback_id = null;
            state.cursor_seconds = 0;
            return .rebuild;
        },
        .waveform_msg => return .none,
        .mirror_dropdown_toggle => |open| {
            state.mirror_dropdown_open = open;
            return .rebuild;
        },
        .mirror_select => |idx| {
            const new_mode: MirrorMode = switch (idx) {
                0 => .none,
                1 => .x_axis,
                2 => .y_axis,
                else => state.mirror_mode,
            };
            state.setMirrorMode(new_mode);
            state.mirror_dropdown_open = false;
            return .rebuild;
        },
        .smoothing_change => |v| {
            const decay = 0.5 + std.math.clamp(v, 0.0, 1.0) * 0.49;
            state.smoothing = decay;
            state.spectrum.decay = decay;
            return .rebuild;
        },
        .bands_change => |v| {
            const f: f32 = std.math.clamp(v, 0.0, 1.0);
            const range_f: f32 = @floatFromInt(SPECTRUM_BANDS_MAX - SPECTRUM_BANDS_MIN);
            const n: usize = SPECTRUM_BANDS_MIN + @as(usize, @intFromFloat(@round(f * range_f)));
            state.setBandCount(n);
            return .rebuild;
        },
        .sensitivity_change => |v| {
            const f: f32 = std.math.clamp(v, 0.0, 1.0);
            state.sensitivity = 0.5 + f * 4.5;
            return .rebuild;
        },
        .bar_gap_change => |v| {
            const f: f32 = std.math.clamp(v, 0.0, 1.0);
            state.setBarGap(f * 16.0);
            return .rebuild;
        },
    }
}

fn tick(app: *App) lib.UpdateAction {
    const state = &app.state;
    const pid_opt = state.playback_id;

    const seeking = state.seek_worker.isSeeking();
    const seek_active = state.seek_worker.isActive();

    const playing = if (pid_opt) |pid|
        if (seeking) state.last_known_playing else app.isStreamPlaying(pid)
    else
        false;
    if (!seeking) state.last_known_playing = playing;

    app.audio_engine.tap.setWakeEnabled(playing);
    app.tick_interval_s = null;

    if (pid_opt) |pid| {
        if (playing) {
            app.audio_engine.tap.readSnapshot(state.wave_samples);
            for (state.wave_samples, 0..) |sample, i| {
                state.wave_ys[i] = @floatCast(sample);
            }
            state.wave_state.setSeries(&state.wave_series);

            state.spectrum.compute(state.wave_samples);
            const sensitivity: f32 = state.sensitivity;
            const n = state.n_bands;
            switch (state.mirror_mode) {
                .none => {
                    for (state.spectrum.bands, 0..) |b, i| {
                        state.spectrum_ys_pos[i] = @floatCast(@min(b * sensitivity, 1.0));
                    }
                },
                .x_axis => {
                    for (state.spectrum.bands, 0..) |b, i| {
                        const v: f64 = @floatCast(@min(b * sensitivity, 1.0));
                        state.spectrum_ys_pos[i] = v;
                        state.spectrum_ys_neg[i] = -v;
                    }
                },
                .y_axis => {
                    for (state.spectrum.bands, 0..) |b, i| {
                        const v: f64 = @floatCast(@min(b * sensitivity, 1.0));
                        state.spectrum_ys_pos[n - 1 - i] = v;
                        state.spectrum_ys_pos[n + i] = v;
                    }
                },
            }
            state.spectrum_state.setSeries(state.spectrum_series_buf[0..if (state.mirror_mode == .x_axis) @as(usize, 2) else @as(usize, 1)]);

            if (!seek_active) {
                state.cursor_seconds = app.getStreamCursorSeconds(pid);
                if (state.duration_seconds == 0.0) {
                    state.duration_seconds = app.getStreamDurationSeconds(pid);
                }
            } else if (!seeking and state.duration_seconds == 0.0) {
                state.duration_seconds = app.getStreamDurationSeconds(pid);
            }
            return .rebuild;
        }
    }
    return .none;
}

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const arena = ui.build_arena.allocator();
    const builder = comp.Builder(AppMessage){ .ui = ui };
    const font = state.font_data;

    const sidebar_header = try ui.text(.{
        .content = "Library",
        .font = font,
        .style = .{
            .text_color = .{ 0.8, 0.85, 0.95, 1.0 },
            .font_size = 14,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 8 },
        },
    });

    const tree_node = if (state.library.items.len == 0)
        try ui.text(.{
            .content = "Drop audio files in ./audio",
            .font = font,
            .style = .{
                .text_color = .{ 0.6, 0.65, 0.75, 1.0 },
                .font_size = 11,
                .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            },
        })
    else
        try builder.treeFromSource(TreeItem, &state.tree_state, state.library.items, .{
            .base_id = NodeIds.library_tree,
            .build_row_content = buildRowContent,
            .wrap_message = struct {
                fn wrap(m: TreeMessage([]const u8)) AppMessage {
                    return .{ .tree_msg = m };
                }
            }.wrap,
            .userdata = @as(?*const anyopaque, @ptrCast(@constCast(state))),
        }, .{
            .style = .{ .width = .Full, .height = .Full, .padding = .all(8.0) },
            .row_style = .{
                .padding = .{ .left = 6, .right = 8, .top = 4, .bottom = 4 },
                .corner_radius = .all(4.0),
            },
            .active_row_color = .{ 0.4, 0.85, 0.6, 0.22 },
            .hover_row_color = .{ 0.3, 0.4, 0.55, 0.14 },
        });

    const sidebar = try ui.div(.{
        .style = .{
            .width = .{ .exact = 260.0 },
            .height = .Full,
            .direction = .Column,
            .background_color = .{ 0.10, 0.11, 0.14, 1.0 },
            .border = .{ .right = .{ .width = 1, .color = .{ 0.18, 0.20, 0.26, 1.0 } } },
            .overflow_y = .scroll,
            .scrollbar_width = 8,
            .scrollbar_color = .{ 0.4, 0.45, 0.55, 0.6 },
            .scrollbar_radius = 4,
        },
        .children = &.{ sidebar_header, tree_node },
    });

    const title_text = try ui.text(.{
        .content = state.current_label orelse "Select a track",
        .font = font,
        .style = .{
            .font_size = 18,
            .text_color = .{ 0.95, 0.97, 1.0, 1.0 },
        },
    });

    const wave_plot = try builder.plot(.{
        .base_id = NodeIds.waveform_plot,
        .state = @constCast(&state.wave_state),
        .on_change = lib.bindTag(AppMessage, PlotMsg, .waveform_msg),
    }, .{
        .style = .{
            .width = .Full,
            .height = .{ .exact = 180.0 },
            .background_color = .{ 0.06, 0.07, 0.10, 1.0 },
            .corner_radius = layout.CornerRadius.all(6.0),
        },
        .background_color = .{ 0.06, 0.07, 0.10, 1.0 },
        .bare = true,
        .enable_pan = false,
        .enable_zoom = false,
    });

    const spectrum_plot = try builder.plot(.{
        .base_id = NodeIds.spectrum_plot,
        .state = @constCast(&state.spectrum_state),
        .on_change = lib.bindTag(AppMessage, PlotMsg, .waveform_msg),
    }, .{
        .style = .{
            .width = .Full,
            .height = .{ .exact = 140.0 },
            .background_color = .{ 0.06, 0.07, 0.10, 1.0 },
            .corner_radius = layout.CornerRadius.all(6.0),
        },
        .background_color = .{ 0.06, 0.07, 0.10, 1.0 },
        .bare = true,
        .enable_pan = false,
        .enable_zoom = false,
    });

    const duration_or_one: f32 = if (state.duration_seconds > 0.0)
        state.duration_seconds
    else
        1.0;
    const seek_norm: f32 = if (duration_or_one > 0.0)
        std.math.clamp(state.cursor_seconds / duration_or_one, 0.0, 1.0)
    else
        0.0;

    const seek_slider = try builder.slider(.{
        .base_id = NodeIds.seek_slider,
        .value = seek_norm,
        .on_change = struct {
            fn cb(v: f32, ud: ?*const anyopaque) AppMessage {
                const s: *const AppState = @ptrCast(@alignCast(ud.?));
                return .{ .seek = v * s.duration_seconds };
            }
        }.cb,
        .userdata = @as(?*const anyopaque, @ptrCast(state)),
        .track = .{ .style = .{ .width = .Full, .height = .{ .exact = 8.0 } } },
        .fill = .{ .style = .{ .background_color = .{ 0.4, 0.85, 0.6, 1.0 } } },
        .handle = .{ .style = .{
            .width = .{ .exact = 16.0 },
            .height = .{ .exact = 16.0 },
            .background_color = .{ 0.95, 0.97, 1.0, 1.0 },
        } },
    });

    const time_buf = try arena.alloc(u8, 64);
    const time_str = try std.fmt.bufPrint(time_buf, "{s} / {s}", .{
        try formatTime(arena, state.cursor_seconds),
        try formatTime(arena, state.duration_seconds),
    });
    const time_text = try ui.text(.{
        .content = time_str,
        .font = font,
        .style = .{
            .font_size = 12,
            .text_color = .{ 0.7, 0.75, 0.85, 1.0 },
        },
    });

    const playing = if (state.playback_id) |pid|
        if (state.seek_worker.isSeeking())
            state.last_known_playing
        else
            state.app.?.isStreamPlaying(pid)
    else
        false;
    const play_label = if (playing) "Pause" else "Play";
    const play_btn = try makeButton(ui, font, NodeIds.play_btn, play_label, .{ .toggle_play = {} });
    const stop_btn = try makeButton(ui, font, NodeIds.stop_btn, "Stop", .{ .stop = {} });
    const transport_row = try ui.div(.{
        .style = .{
            .direction = .Row,
            .gap = 8.0,
            .margin = .{ .top = 8 },
        },
        .children = &.{ play_btn, stop_btn },
    });

    const main_pane = try ui.div(.{
        .style = .{
            .flex_grow = 1.0,
            .height = .Full,
            .direction = .Column,
            .gap = 12.0,
            .padding = .all(20.0),
            .background_color = .{ 0.07, 0.08, 0.11, 1.0 },
        },
        .children = &.{
            title_text,
            wave_plot,
            spectrum_plot,
            seek_slider,
            time_text,
            transport_row,
            try buildVizControls(ui, font, state),
        },
    });

    return ui.div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .direction = .Row,
        },
        .children = &.{ sidebar, main_pane },
    });
}

fn buildVizControls(
    ui: *AppUIContext,
    font: *lib.FontData,
    state: *const AppState,
) anyerror!*AppNode {
    const arena = ui.build_arena.allocator();
    const builder = comp.Builder(AppMessage){ .ui = ui };

    const mirror_idx: usize = switch (state.mirror_mode) {
        .none => 0,
        .x_axis => 1,
        .y_axis => 2,
    };
    const mirror_dd = try builder.dropdown(.{
        .base_id = NodeIds.mirror_dropdown,
        .is_open = state.mirror_dropdown_open,
        .active_index = mirror_idx,
        .options = &MIRROR_OPTIONS,
        .on_toggle = lib.bindTag(AppMessage, bool, .mirror_dropdown_toggle),
        .on_select = lib.bindTag(AppMessage, usize, .mirror_select),
        .font = font,
        .style = .{ .width = .{ .exact = 240.0 } },
    });

    const smoothing_norm: f32 = (state.smoothing - 0.5) / 0.49;
    const bands_norm: f32 = blk: {
        const range_f: f32 = @floatFromInt(SPECTRUM_BANDS_MAX - SPECTRUM_BANDS_MIN);
        const cur_f: f32 = @floatFromInt(state.n_bands - SPECTRUM_BANDS_MIN);
        break :blk if (range_f > 0) cur_f / range_f else 0.0;
    };
    const sensitivity_norm: f32 = (state.sensitivity - 0.5) / 4.5;
    const bar_gap_norm: f32 = state.bar_gap / 16.0;

    const smoothing_label = try labelValue(arena, "smoothing", state.smoothing);
    const bands_label = try labelValueInt(arena, "bands", state.n_bands);
    const sensitivity_label = try labelValue(arena, "sensitivity", state.sensitivity);
    const bar_gap_label = try labelValue(arena, "bar gap (px)", state.bar_gap);

    const smoothing_row = try labeledSlider(
        ui,
        font,
        smoothing_label,
        NodeIds.smoothing_slider,
        smoothing_norm,
        lib.bindTag(AppMessage, f32, .smoothing_change),
    );
    const bands_row = try labeledSlider(
        ui,
        font,
        bands_label,
        NodeIds.bands_slider,
        bands_norm,
        lib.bindTag(AppMessage, f32, .bands_change),
    );
    const sensitivity_row = try labeledSlider(
        ui,
        font,
        sensitivity_label,
        NodeIds.sensitivity_slider,
        sensitivity_norm,
        lib.bindTag(AppMessage, f32, .sensitivity_change),
    );
    const bar_gap_row = try labeledSlider(
        ui,
        font,
        bar_gap_label,
        NodeIds.bar_gap_slider,
        bar_gap_norm,
        lib.bindTag(AppMessage, f32, .bar_gap_change),
    );

    return ui.div(.{
        .style = .{
            .direction = .Column,
            .gap = 8.0,
            .margin = .{ .top = 12 },
            .padding = .{ .top = 12, .bottom = 4, .left = 0, .right = 0 },
            .border = .{ .top = .{ .width = 1, .color = .{ 0.18, 0.20, 0.26, 1.0 } } },
        },
        .children = &.{
            try ui.text(.{
                .content = "spectrum",
                .font = font,
                .style = .{ .text_color = .{ 0.7, 0.75, 0.85, 1.0 }, .font_size = 12 },
            }),
            try ui.div(.{
                .style = .{ .direction = .Row, .align_items = .Center, .gap = 10.0 },
                .children = &.{
                    try ui.text(.{
                        .content = "mirror",
                        .font = font,
                        .style = .{ .text_color = .{ 0.78, 0.83, 0.92, 1.0 }, .font_size = 12 },
                    }),
                    mirror_dd,
                },
            }),
            smoothing_row,
            bands_row,
            sensitivity_row,
            bar_gap_row,
        },
    });
}

fn labeledSlider(
    ui: *AppUIContext,
    font: *lib.FontData,
    label_text: []const u8,
    id: lib.NodeId,
    value: f32,
    cb: *const fn (f32, ?*const anyopaque) AppMessage,
) anyerror!*AppNode {
    const builder = comp.Builder(AppMessage){ .ui = ui };
    const slider_node = try builder.slider(.{
        .base_id = id,
        .value = value,
        .on_change = cb,
        .track = .{ .style = .{ .width = .Full, .height = .{ .exact = 6.0 } } },
        .fill = .{ .style = .{ .background_color = .{ 0.55, 0.75, 1.0, 1.0 } } },
        .handle = .{ .style = .{
            .width = .{ .exact = 14.0 },
            .height = .{ .exact = 14.0 },
            .background_color = .{ 0.95, 0.97, 1.0, 1.0 },
        } },
    });
    return ui.div(.{
        .style = .{
            .direction = .Row,
            .align_items = .Center,
            .gap = 10.0,
        },
        .children = &.{
            try ui.text(.{
                .content = label_text,
                .font = font,
                .style = .{
                    .text_color = .{ 0.78, 0.83, 0.92, 1.0 },
                    .font_size = 12,
                    .width = .{ .exact = 160.0 },
                },
            }),
            try ui.div(.{
                .style = .{ .flex_grow = 1.0 },
                .children = &.{slider_node},
            }),
        },
    });
}

fn labelValue(arena: std.mem.Allocator, name: []const u8, value: f32) ![]const u8 {
    const buf = try arena.alloc(u8, 64);
    return std.fmt.bufPrint(buf, "{s}: {d:.2}", .{ name, value });
}

fn labelValueInt(arena: std.mem.Allocator, name: []const u8, value: usize) ![]const u8 {
    const buf = try arena.alloc(u8, 64);
    return std.fmt.bufPrint(buf, "{s}: {d}", .{ name, value });
}

fn makeButton(
    ui: *AppUIContext,
    font: *lib.FontData,
    id: lib.NodeId,
    label: []const u8,
    msg: AppMessage,
) anyerror!*AppNode {
    return ui.div(.{
        .id = id,
        .style = .{
            .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
            .background_color = .{ 0.16, 0.18, 0.24, 1.0 },
            .corner_radius = layout.CornerRadius.all(4.0),
            .border = layout.Border.all(1.0, .{ 0.28, 0.33, 0.44, 1.0 }),
            .cursor = .pointer,
            .hover_color = .{ 0.20, 0.23, 0.30, 1.0 },
            .transition = layout.TransitionStyle.forColors(80),
        },
        .events = &.{.{ .event = .click, .msg = msg }},
        .children = &.{
            try ui.text(.{
                .content = label,
                .font = font,
                .style = .{ .text_color = .{ 0.95, 0.97, 1.0, 1.0 }, .pointer_events = .none },
            }),
        },
    });
}

fn buildRowContent(ctx: *AppUIContext, item: comp.TreeItem, userdata: ?*const anyopaque) anyerror!*AppNode {
    const state: *const AppState = @ptrCast(@alignCast(userdata.?));
    const found = findItemById(state.library.items, item.id);
    const label = if (found) |it| it.label else item.id;
    const is_group = if (found) |it| it.is_group else false;
    return ctx.text(.{
        .content = label,
        .font = state.font_data,
        .style = .{
            .pointer_events = .none,
            .text_color = if (item.is_selected)
                .{ 1.0, 1.0, 1.0, 1.0 }
            else if (is_group)
                .{ 0.78, 0.83, 0.92, 1.0 }
            else
                .{ 0.88, 0.91, 0.96, 1.0 },
            .font_size = if (is_group) @as(f32, 13) else @as(f32, 12),
        },
    });
}

fn formatTime(arena: std.mem.Allocator, seconds: f32) ![]const u8 {
    const total = @max(0.0, seconds);
    const minutes: u32 = @intFromFloat(@divFloor(total, 60.0));
    const secs: u32 = @intFromFloat(@mod(total, 60.0));
    const buf = try arena.alloc(u8, 16);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, secs });
}

// Audio thread; postEmptyEvent is documented thread-safe.
fn audioTapWake() callconv(.c) void {
    lib.glfw.postEmptyEvent();
}

fn shortcuts(
    state: *AppState,
    ir: *T.InteractionRegistry,
    key: i32,
    action: i32,
    _: *const lib.WindowContext,
) bool {
    _ = state;
    if (key == lib.glfw.KeySpace and action == lib.glfw.Press) {
        ir.postExternalMessage(.{ .id = .{ .toggle_play = {} } });
        return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();
    const io = init.io;

    var app = try App.init(
        allocator,
        io,
        .{ .title = "Audio Player" },
        AppState.init(allocator, io),
        update,
    );
    defer app.deinit();
    defer app.state.deinit();

    app.state.app = &app;
    app.state.font_data = try app.loadFont(
        "JetBrains Mono",
        .{ .memory = lib.assets.getFontData(.jetbrains_mono) },
        20,
    );
    try app.state.initWaveBuffers();
    {
        const sr: f32 = @floatFromInt(@max(app.audio_engine.getSampleRate(), 1));
        try app.state.initSpectrumBuffers(sr);
    }

    app.state.seek_worker = .{ .app = &app };
    app.state.seek_thread = try std.Thread.spawn(
        .{},
        SeekWorker.run,
        .{&app.state.seek_worker},
    );

    app.audio_engine.tap.setWakeCallback(audioTapWake);

    const cwd_path = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", allocator);
    defer allocator.free(cwd_path);
    const audio_dir = try std.fs.path.join(allocator, &.{ cwd_path, "audio" });
    defer allocator.free(audio_dir);
    scanDir(allocator, io, audio_dir, 1, &app.state.library) catch |err| {
        std.log.warn("audio_player: scan failed: {s}", .{@errorName(err)});
    };

    app.tick_fn = tick;
    app.setShortcutHandler(AppState, &app.state, shortcuts);
    try app.setRootBuilder(build);
    try app.run();
}
