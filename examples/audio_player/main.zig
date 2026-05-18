//! Music player: ManagedApp with player + settings pages, persisted library
//! (groups + tags), customizable visualizers, and 3-band EQ + crossfade + gapless.

const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const state_mod = @import("state.zig");
const storage = @import("storage.zig");
const player_page = @import("player.zig");
const settings_page = @import("settings.zig");
const icons_mod = @import("icons.zig");
pub const IconId = icons_mod.IconId;

const Spec = struct {
    pub const Route = enum { player, settings };
    pub const Pages = .{
        .player = player_page.PlayerPage,
        .settings = settings_page.SettingsPage,
    };
    pub const initial_route = Route.player;
    pub const GlobalState = state_mod.AppGlobal;
    pub const RuntimeState = state_mod.AppRuntime;
};

pub const Managed = lib.ManagedApp(Spec);
pub const AppMessage = Managed.Message;
pub const App = Managed.App;
pub const T = lib.For(AppMessage);

const RunSpec = struct {
    pub const window: lib.AppBackendConfig = .{ .title = "Ramiel Music" };
    pub const default_font: lib.FontSpec = .{
        .name = "JetBrains Mono",
        .source = .{ .memory = lib.assets.getFontData(.jetbrains_mono) },
        .base_resolution = 20,
    };

    pub fn setup(ctx: anytype) !void {
        try setupImpl(ctx);
    }

    pub fn shutdown(ctx: anytype) void {
        const global = &ctx.app.state.global;
        const snap = global.snapshot();
        storage.save(ctx.allocator, ctx.io, &snap) catch |err| {
            std.log.warn("audio_player: shutdown save failed: {s}", .{@errorName(err)});
        };
    }

    pub fn tick(app: *App) lib.UpdateAction {
        return tickImpl(app);
    }
};

fn setupImpl(ctx: anytype) !void {
    const app = ctx.app;
    const allocator = ctx.allocator;

    app.state.runtime.font_data = app.requireFont("JetBrains Mono");
    app.state.runtime.app = @ptrCast(app);

    // Allocate visualizer buffers.
    const wave_n: usize = 4096;
    const rt = &app.state.runtime;
    rt.wave_samples = try allocator.alloc(f32, wave_n);
    rt.wave_xs = try allocator.alloc(f64, wave_n);
    rt.wave_ys = try allocator.alloc(f64, wave_n);
    @memset(rt.wave_samples, 0);
    @memset(rt.wave_ys, 0);
    for (rt.wave_xs, 0..) |*x, i| x.* = @floatFromInt(i);
    rt.wave_state = lib.components.PlotState.init(allocator);
    rt.wave_series[0] = .{
        .xs = rt.wave_xs, .ys = rt.wave_ys,
        .color = .{ 0.4, 0.85, 0.6, 1.0 }, .line_width = 1.5, .kind = .line,
    };
    rt.wave_state.setSeries(rt.wave_series[0..1]);
    rt.wave_state.setXRange(0.0, @floatFromInt(wave_n - 1));
    rt.wave_state.setYRange(-1.05, 1.05);

    const sr: f32 = @floatFromInt(@max(app.audio_engine.getSampleRate(), 1));
    rt.spectrum_sample_rate = sr;
    const n_bands: usize = app.state.global.visualizer_defaults.n_bands;
    rt.spectrum = try lib.audio_spectrum.Analyzer.init(allocator, wave_n, n_bands, sr);
    rt.spectrum_xs = try allocator.alloc(f64, n_bands * 2);
    rt.spectrum_ys_pos = try allocator.alloc(f64, n_bands * 2);
    rt.spectrum_ys_neg = try allocator.alloc(f64, n_bands * 2);
    @memset(rt.spectrum_ys_pos, 0);
    @memset(rt.spectrum_ys_neg, 0);
    for (rt.spectrum_xs, 0..) |*x, i| x.* = @floatFromInt(i);
    rt.spectrum_state = lib.components.PlotState.init(allocator);
    rt.spectrum_series[0] = .{
        .xs = rt.spectrum_xs[0..n_bands],
        .ys = rt.spectrum_ys_pos[0..n_bands],
        .color = .{ 0.55, 0.75, 1.0, 1.0 },
        .kind = .bar, .bar_baseline = 0.0,
    };
    rt.spectrum_state.setSeries(rt.spectrum_series[0..1]);
    rt.spectrum_state.setXRange(0.0, @floatFromInt(n_bands - 1));
    rt.spectrum_state.setYRange(0.0, 1.05);
    rt.spectrum_initialized = true;

    app.audio_engine.tap.setWakeCallback(audioTapWake);

    try icons_mod.loadAll(app);

    // Load saved library if any.
    if (try storage.load(allocator, ctx.io)) |loaded| {
        var loaded_mut = loaded;
        defer storage.freeLoadedSnapshot(allocator, &loaded_mut);
        try app.state.global.restoreSnapshot(&loaded_mut);
        app.state.route = if (loaded_mut.last_route == 1) .settings else .player;
    }

    // Apply theme + EQ.
    settings_page.applyTheme(app, &app.state.global);
    settings_page.applyEQ(app, &app.state.global);

    app.tick_fn = RunSpec.tick;
    app.setShortcutHandler(App, app, shortcuts);
}

fn tickImpl(app: *App) lib.UpdateAction {
    const rt = &app.state.runtime;

    // Drain audio engine advance events (gapless transitions). Post each as a
    // player message so the UI selects the new song.
    const evs = app.audio_engine.registry.takeAdvanceEvents(app.allocator) catch &[_]lib.AdvanceEvent{};
    defer if (evs.len > 0) app.allocator.free(evs);
    for (evs) |ev| {
        if (rt.current_song_id) |cur| {
            if (nextSongInGroupForGlobal(&app.state, cur)) |next_sid| {
                app.postMessageId(.{ .player = .{ .advanced_to_song = .{ .song = next_sid, .new_pid = ev.new_id } } });
            }
        }
    }

    const pid_opt = rt.playback_id;
    const seeking = if (pid_opt) |pid| app.isStreamSeeking(pid) else false;
    const seek_active = if (pid_opt) |pid| app.isStreamSeekActive(pid) else false;

    const playing = if (pid_opt) |pid|
        if (seeking) rt.last_known_playing else app.isStreamPlaying(pid)
    else
        false;
    if (!seeking) rt.last_known_playing = playing;

    app.audio_engine.tap.setWakeEnabled(playing);
    app.tick_interval_s = null;

    // Auto-save debounce: write when dirty, then clear.
    if (app.state.global.library_dirty) {
        const snap = app.state.global.snapshot();
        storage.save(app.allocator, app.io, &snap) catch |err| {
            std.log.warn("audio_player: auto-save failed: {s}", .{@errorName(err)});
        };
        app.state.global.library_dirty = false;
    }

    if (pid_opt) |pid| {
        if (playing) {
            app.audio_engine.tap.readSnapshot(rt.wave_samples);
            for (rt.wave_samples, 0..) |sample, i| rt.wave_ys[i] = @floatCast(sample);
            rt.wave_state.setSeries(rt.wave_series[0..1]);

            if (rt.spectrum_initialized) {
                rt.spectrum.compute(rt.wave_samples);
                const sensitivity = app.state.global.visualizer_defaults.sensitivity;
                for (rt.spectrum.bands, 0..) |b, i| {
                    rt.spectrum_ys_pos[i] = @floatCast(@min(b * sensitivity, 1.0));
                }
                rt.spectrum_state.setSeries(rt.spectrum_series[0..1]);
            }

            if (!seek_active) {
                rt.cursor_seconds = app.getStreamCursorSeconds(pid);
                if (rt.duration_seconds == 0.0) rt.duration_seconds = app.getStreamDurationSeconds(pid);
            } else if (!seeking and rt.duration_seconds == 0.0) {
                rt.duration_seconds = app.getStreamDurationSeconds(pid);
            }
            return .rebuild;
        }
    }
    return .none;
}

fn nextSongInGroupForGlobal(state: anytype, current: state_mod.SongId) ?state_mod.SongId {
    const player = &state.pages.player;
    if (player.selected_kind == .group) {
        for (state.global.library.groups) |g| {
            if (g.id != player.selected_id) continue;
            for (g.song_ids, 0..) |sid, i| {
                if (sid == current and i + 1 < g.song_ids.len) return g.song_ids[i + 1];
            }
        }
    }
    return null;
}

fn audioTapWake() callconv(.c) void {
    lib.glfw.postEmptyEvent();
}

fn shortcuts(
    app: *App,
    ir: *T.InteractionRegistry,
    key: i32,
    action: i32,
    _: bool,
    _: bool,
) bool {
    _ = app;
    if (key == lib.glfw.KeySpace and action == lib.glfw.Press) {
        ir.postExternalMessage(.{ .id = .{ .player = .toggle_play } });
        return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    Managed.run(init, RunSpec) catch |err| {
        std.log.err("audio_player: run failed: {s}", .{@errorName(err)});
        return err;
    };
}
