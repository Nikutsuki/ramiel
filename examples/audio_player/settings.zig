//! Settings page - theme generator (oklch + randomize), visualizer, EQ, library.

const std = @import("std");
const lib = @import("ramiel");
const layout = lib.layout;
const comp = lib.components;
const state_mod = @import("state.zig");
const player = @import("player.zig");
const icons_mod = @import("icons.zig");
const IconId = icons_mod.IconId;

fn iconChild(ctx: anytype, id: IconId, dim: f32, color: [4]f32) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    return ctx.components.icon(.{
        .icon_id = @intFromEnum(id),
        .scale = 1.0,
        .intrinsic_size = .{ dim, dim },
        .style = blk: {
            var s: layout.Style = .{};
            s.width = .{ .exact = dim };
            s.height = .{ .exact = dim };
            s.pointer_events = .none;
            break :blk s;
        },
        .tint = color,
        .alt_text = "",
        .fallback_state = .ready,
    });
}

pub const SettingsState = struct {
    pub const snapshot_version: lib.state.SnapshotVersion = 1;
    pub const Snapshot = struct {};

    allocator: std.mem.Allocator,
    rng_seed: u64 = 0xdeadbeef,

    pub fn init(allocator: std.mem.Allocator) !SettingsState {
        return .{ .allocator = allocator };
    }
    pub fn deinit(_: *SettingsState) void {}
    pub fn snapshot(_: *const SettingsState) Snapshot {
        return .{};
    }
    pub fn restoreSnapshot(_: *SettingsState, _: *const Snapshot) !void {}
};

pub const SettingsMessage = union(enum) {
    theme_dark,
    theme_light,
    accent_hue: f32,
    accent_chroma: f32,
    accent_lightness: f32,
    randomize_theme,
    viz_enabled_toggle,
    viz_smoothing: f32,
    viz_bands: f32,
    viz_sensitivity: f32,
    viz_bar_gap: f32,
    eq_toggle,
    eq_low_gain: f32,
    eq_mid_gain: f32,
    eq_high_gain: f32,
    crossfade_change: f32,
    gapless_toggle,
    volume_change: f32,
    rescan_folder,
    clear_library,
};

pub const SettingsPage = struct {
    pub const State = SettingsState;
    pub const Msg = SettingsMessage;
    pub const build = build_;
    pub const update = update_;
};

const Ids = lib.declareIds("examples.music.settings", .{
    "back",   "dark",   "light",  "accent_h", "accent_c", "accent_l", "randomize",
    "viz_en", "viz_sm", "viz_bd", "viz_sn",   "viz_g",    "eq_on",    "eq_lo",
    "eq_mi",  "eq_hi",  "xf",     "gp",       "vol",      "rs",       "cl",
}){};

fn pad(h: f32, v: f32) layout.Spacing {
    return .{ .top = v, .bottom = v, .left = h, .right = h };
}

fn build_(ctx: anytype, state: *const SettingsState) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    _ = state;
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const global = ctx.global;

    var children: std.ArrayList(*lib.Node(M)) = .empty;

    try children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.direction = .Row;
            s.align_items = .Center;
            s.gap = 16.0;
            s.padding = pad(0, 0);
            s.margin = .{ .top = 0, .bottom = 24, .left = 0, .right = 0 };
            break :blk s;
        },
        .children = .{
            try gotoBackBtn(ctx),
            try ux.text(.{
                .content = "Settings",
                .font = font,
                .style = blk: {
                    var s: layout.Style = .{};
                    s.text_color = tokens.text_main;
                    s.font_size = 28.0;
                    break :blk s;
                },
            }),
        },
    }));

    // Theme section
    try children.append(arena, try section(ctx, "Theme"));

    // Theme preview swatches
    try children.append(arena, try buildPaletteRow(ctx, tokens));

    // Mode toggle
    try children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.direction = .Row;
            s.gap = 8.0;
            s.margin = .{ .top = 12, .bottom = 12, .left = 0, .right = 0 };
            break :blk s;
        },
        .children = .{
            try modeBtn(ctx, Ids.dark, "Dark", global.theme_mode == .dark, SettingsMessage.theme_dark),
            try modeBtn(ctx, Ids.light, "Light", global.theme_mode == .light, SettingsMessage.theme_light),
            try primaryBtn(ctx, Ids.randomize, "↻  Randomize", SettingsMessage.randomize_theme),
        },
    }));

    try children.append(arena, try labeledSlider(ctx, "Hue", Ids.accent_h, global.accent_hue / 360.0, .accent_hue, fmtDeg(arena, global.accent_hue)));
    try children.append(arena, try labeledSlider(ctx, "Chroma", Ids.accent_c, global.accent_chroma / 0.4, .accent_chroma, fmtFloat(arena, global.accent_chroma)));
    try children.append(arena, try labeledSlider(ctx, "Lightness", Ids.accent_l, global.accent_lightness, .accent_lightness, fmtFloat(arena, global.accent_lightness)));

    // Visualizer
    try children.append(arena, try section(ctx, "Visualizer"));
    try children.append(arena, try toggleRow(ctx, Ids.viz_en, "Enabled", global.visualizer_defaults.enabled, SettingsMessage.viz_enabled_toggle));
    try children.append(arena, try labeledSlider(ctx, "Smoothing", Ids.viz_sm, global.visualizer_defaults.smoothing, .viz_smoothing, fmtFloat(arena, global.visualizer_defaults.smoothing)));
    const bands_norm = (@as(f32, @floatFromInt(global.visualizer_defaults.n_bands)) - 16.0) / (256.0 - 16.0);
    try children.append(arena, try labeledSlider(ctx, "Bands", Ids.viz_bd, bands_norm, .viz_bands, fmtInt(arena, global.visualizer_defaults.n_bands)));
    try children.append(arena, try labeledSlider(ctx, "Sensitivity", Ids.viz_sn, (global.visualizer_defaults.sensitivity - 0.5) / 4.5, .viz_sensitivity, fmtFloat(arena, global.visualizer_defaults.sensitivity)));
    try children.append(arena, try labeledSlider(ctx, "Bar gap", Ids.viz_g, global.visualizer_defaults.bar_gap / 16.0, .viz_bar_gap, fmtFloat(arena, global.visualizer_defaults.bar_gap)));

    // Playback
    try children.append(arena, try section(ctx, "Playback"));
    try children.append(arena, try labeledSlider(ctx, "Volume", Ids.vol, global.playback.volume, .volume_change, fmtFloat(arena, global.playback.volume)));
    try children.append(arena, try labeledSlider(ctx, "Crossfade", Ids.xf, @as(f32, @floatFromInt(global.playback.crossfade_ms)) / 10000.0, .crossfade_change, fmtMs(arena, global.playback.crossfade_ms)));
    try children.append(arena, try toggleRow(ctx, Ids.gp, "Gapless within group", global.playback.gapless_in_group, SettingsMessage.gapless_toggle));

    // EQ
    try children.append(arena, try section(ctx, "Equalizer"));
    try children.append(arena, try toggleRow(ctx, Ids.eq_on, "Enabled", global.playback.eq.enabled, SettingsMessage.eq_toggle));
    try children.append(arena, try labeledSlider(ctx, "Low (80 Hz)", Ids.eq_lo, (global.playback.eq.low.gain_db + 24.0) / 48.0, .eq_low_gain, fmtDb(arena, global.playback.eq.low.gain_db)));
    try children.append(arena, try labeledSlider(ctx, "Mid (1 kHz)", Ids.eq_mi, (global.playback.eq.mid.gain_db + 24.0) / 48.0, .eq_mid_gain, fmtDb(arena, global.playback.eq.mid.gain_db)));
    try children.append(arena, try labeledSlider(ctx, "High (8 kHz)", Ids.eq_hi, (global.playback.eq.high.gain_db + 24.0) / 48.0, .eq_high_gain, fmtDb(arena, global.playback.eq.high.gain_db)));

    // Library
    try children.append(arena, try section(ctx, "Library"));
    const last = global.library.last_folder orelse "(no folder picked yet)";
    try children.append(arena, try ux.text(.{
        .content = last,
        .font = font,
        .style = blk: {
            var s: layout.Style = .{};
            s.text_color = tokens.text_muted;
            s.font_size = 11.0;
            s.margin = .{ .top = 0, .bottom = 12, .left = 0, .right = 0 };
            break :blk s;
        },
    }));
    try children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.direction = .Row;
            s.gap = 8.0;
            break :blk s;
        },
        .children = .{
            try secondaryBtn(ctx, Ids.rs, "Rescan folder", SettingsMessage.rescan_folder),
            try secondaryBtn(ctx, Ids.cl, "Clear library", SettingsMessage.clear_library),
        },
    }));

    var root: layout.Style = .{};
    root.width = .Full;
    root.height = .Full;
    root.direction = .Column;
    root.padding = .{ .top = 32, .bottom = 32, .left = 64, .right = 64 };
    root.background_color = tokens.bg_base;
    root.overflow_y = .scroll;
    root.gap = 6.0;

    return ux.div(.{
        .style = root,
        .children = try children.toOwnedSlice(arena),
    });
}

fn buildPaletteRow(ctx: anytype, tokens: lib.SemanticTokens) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();

    const swatches = [_]struct { c: [4]f32, label: []const u8 }{
        .{ .c = tokens.action_default, .label = "action" },
        .{ .c = tokens.accent_default, .label = "accent" },
        .{ .c = tokens.secondary_default, .label = "secondary" },
        .{ .c = tokens.bg_base, .label = "bg base" },
        .{ .c = tokens.bg_surface, .label = "surface" },
        .{ .c = tokens.bg_elevated, .label = "elevated" },
        .{ .c = tokens.text_main, .label = "text" },
    };
    var nodes: std.ArrayList(*lib.Node(M)) = .empty;
    for (swatches) |sw| {
        var ss: layout.Style = .{};
        ss.width = .{ .exact = 56.0 };
        ss.height = .{ .exact = 56.0 };
        ss.background_color = sw.c;
        ss.corner_radius = layout.CornerRadius.all(8.0);
        var label_s: layout.Style = .{};
        label_s.text_color = tokens.text_muted;
        label_s.font_size = 9.0;
        label_s.margin = .{ .top = 4, .bottom = 0, .left = 0, .right = 0 };
        try nodes.append(arena, try ux.div(.{
            .style = blk: {
                var s: layout.Style = .{};
                s.direction = .Column;
                s.align_items = .Center;
                break :blk s;
            },
            .children = .{
                try ux.div(.{ .style = ss }),
                try ux.text(.{ .content = sw.label, .font = ctx.runtime.font_data, .style = label_s }),
            },
        }));
    }

    var row: layout.Style = .{};
    row.direction = .Row;
    row.gap = 12.0;
    row.padding = pad(0, 4);
    return ux.div(.{
        .style = row,
        .children = try nodes.toOwnedSlice(arena),
    });
}

fn section(ctx: anytype, label: []const u8) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    return ux.text(.{
        .content = label,
        .font = font,
        .style = blk: {
            var s: layout.Style = .{};
            s.text_color = tokens.text_main;
            s.font_size = 18.0;
            s.margin = .{ .top = 24, .bottom = 12, .left = 0, .right = 0 };
            break :blk s;
        },
    });
}

fn modeBtn(ctx: anytype, id: lib.NodeId, label: []const u8, active: bool, msg: SettingsMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.padding = pad(16, 8);
    s.background_color = if (active) tokens.action_default else tokens.bg_surface;
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    s.hover_color = if (active) tokens.action_hover else tokens.bg_elevated;
    var ts: layout.Style = .{};
    ts.text_color = if (active) tokens.action_text else tokens.text_main;
    ts.font_size = 12.0;
    ts.pointer_events = .none;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = ts }),
        },
    });
}

fn primaryBtn(ctx: anytype, id: lib.NodeId, label: []const u8, msg: SettingsMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.padding = pad(16, 8);
    s.background_color = tokens.accent_default;
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    s.hover_color = tokens.accent_hover;
    var ts: layout.Style = .{};
    ts.text_color = tokens.action_text;
    ts.font_size = 12.0;
    ts.pointer_events = .none;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = ts }),
        },
    });
}

fn secondaryBtn(ctx: anytype, id: lib.NodeId, label: []const u8, msg: SettingsMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.padding = pad(16, 8);
    s.background_color = tokens.bg_surface;
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    s.hover_color = tokens.bg_elevated;
    var ts: layout.Style = .{};
    ts.text_color = tokens.text_main;
    ts.font_size = 12.0;
    ts.pointer_events = .none;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = ts }),
        },
    });
}

fn toggleRow(ctx: anytype, id: lib.NodeId, label: []const u8, on: bool, msg: SettingsMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.direction = .Row;
    s.align_items = .Center;
    s.justify_content = .SpaceBetween;
    s.padding = pad(16, 12);
    s.background_color = tokens.bg_surface;
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    s.hover_color = tokens.bg_elevated;
    s.margin = .{ .top = 0, .bottom = 6, .left = 0, .right = 0 };

    var pill: layout.Style = .{};
    pill.width = .{ .exact = 36.0 };
    pill.height = .{ .exact = 20.0 };
    pill.direction = .Row;
    pill.background_color = if (on) tokens.accent_default else tokens.bg_elevated;
    pill.corner_radius = layout.CornerRadius.all(10.0);
    pill.align_items = .Center;
    pill.padding = .{ .top = 0, .bottom = 0, .left = 0, .right = 0 };

    // Position the dot via margin so the slide animates predictably across themes.
    var dot: layout.Style = .{};
    dot.width = .{ .exact = 14.0 };
    dot.height = .{ .exact = 14.0 };
    dot.background_color = .{ 1, 1, 1, 1 };
    dot.corner_radius = layout.CornerRadius.all(7.0);
    dot.flex_shrink = 0.0;
    dot.margin = .{
        .top = 0,
        .bottom = 0,
        .left = if (on) 19.0 else 3.0,
        .right = if (on) 3.0 else 19.0,
    };

    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{
                .content = label,
                .font = font,
                .style = blk: {
                    var ts: layout.Style = .{};
                    ts.text_color = tokens.text_main;
                    ts.font_size = 12.0;
                    ts.pointer_events = .none;
                    break :blk ts;
                },
            }),
            try ux.div(.{
                .style = pill,
                .children = .{try ux.div(.{ .style = dot })},
            }),
        },
    });
}

fn labeledSlider(ctx: anytype, label: []const u8, id: lib.NodeId, value: f32, comptime tag: anytype, value_label: []const u8) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const Self = @TypeOf(ctx.*);
    const M = Self.Message;
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const Cb = struct {
        fn cb(v: f32, _: ?*const anyopaque) M {
            return @unionInit(M, "settings", @unionInit(SettingsMessage, @tagName(tag), v));
        }
    };
    var row: layout.Style = .{};
    row.direction = .Row;
    row.align_items = .Center;
    row.gap = 16.0;
    row.padding = pad(16, 10);
    row.background_color = tokens.bg_surface;
    row.corner_radius = layout.CornerRadius.all(6.0);
    row.margin = .{ .top = 0, .bottom = 6, .left = 0, .right = 0 };

    var label_s: layout.Style = .{};
    label_s.width = .{ .exact = 130.0 };
    label_s.text_color = tokens.text_main;
    label_s.font_size = 12.0;

    var value_s: layout.Style = .{};
    value_s.width = .{ .exact = 70.0 };
    value_s.text_color = tokens.text_muted;
    value_s.font_size = 11.0;

    return ux.div(.{
        .style = row,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = label_s }),
            try ux.div(.{
                .style = blk: {
                    var s: layout.Style = .{};
                    s.flex_grow = 1.0;
                    break :blk s;
                },
                .children = .{
                    try ctx.components.slider(.{
                        .base_id = id,
                        .value = std.math.clamp(value, 0.0, 1.0),
                        .on_change = Cb.cb,
                    }),
                },
            }),
            try ux.text(.{ .content = value_label, .font = font, .style = value_s }),
        },
    });
}

fn gotoBackBtn(ctx: anytype) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    var s: layout.Style = .{};
    s.width = .{ .exact = 40.0 };
    s.height = .{ .exact = 40.0 };
    s.direction = .Row;
    s.justify_content = .Center;
    s.align_items = .Center;
    s.background_color = tokens.bg_surface;
    s.corner_radius = layout.CornerRadius.all(20.0);
    s.cursor = .pointer;
    s.hover_color = tokens.bg_elevated;
    return ux.div(.{
        .id = Ids.back,
        .style = s,
        .on_click = ctx.goto(.player),
        .children = .{
            try iconChild(ctx, .back, 18.0, tokens.text_main),
        },
    });
}

fn fmtFloat(arena: std.mem.Allocator, v: f32) []const u8 {
    const buf = arena.alloc(u8, 16) catch return "?";
    return std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "?";
}

fn fmtInt(arena: std.mem.Allocator, v: usize) []const u8 {
    const buf = arena.alloc(u8, 16) catch return "?";
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

fn fmtDeg(arena: std.mem.Allocator, v: f32) []const u8 {
    const buf = arena.alloc(u8, 16) catch return "?";
    return std.fmt.bufPrint(buf, "{d:.0}°", .{v}) catch "?";
}

fn fmtDb(arena: std.mem.Allocator, v: f32) []const u8 {
    const buf = arena.alloc(u8, 16) catch return "?";
    return std.fmt.bufPrint(buf, "{d:.1} dB", .{v}) catch "?";
}

fn fmtMs(arena: std.mem.Allocator, v: u32) []const u8 {
    const buf = arena.alloc(u8, 16) catch return "?";
    return std.fmt.bufPrint(buf, "{d} ms", .{v}) catch "?";
}

fn update_(ctx: anytype, state: *SettingsState, msg: SettingsMessage) lib.UpdateAction {
    const app = ctx.app;
    const global = ctx.global;
    switch (msg) {
        .theme_dark => {
            global.theme_mode = .dark;
            applyTheme(app, global);
            global.markDirty();
        },
        .theme_light => {
            global.theme_mode = .light;
            applyTheme(app, global);
            global.markDirty();
        },
        .accent_hue => |v| {
            global.accent_hue = v * 360.0;
            applyTheme(app, global);
            global.markDirty();
        },
        .accent_chroma => |v| {
            global.accent_chroma = v * 0.4;
            applyTheme(app, global);
            global.markDirty();
        },
        .accent_lightness => |v| {
            global.accent_lightness = v;
            applyTheme(app, global);
            global.markDirty();
        },
        .randomize_theme => {
            const ns: i96 = std.Io.Timestamp.now(app.io, .awake).toNanoseconds();
            state.rng_seed +%= @as(u64, @truncate(@as(u128, @bitCast(@as(i128, ns)))));
            var prng = std.Random.DefaultPrng.init(state.rng_seed);
            const r = prng.random();
            global.accent_hue = r.float(f32) * 360.0;
            global.accent_chroma = 0.10 + r.float(f32) * 0.18;
            global.accent_lightness = 0.55 + r.float(f32) * 0.15;
            applyTheme(app, global);
            global.markDirty();
        },
        .viz_enabled_toggle => {
            global.visualizer_defaults.enabled = !global.visualizer_defaults.enabled;
            global.markDirty();
        },
        .viz_smoothing => |v| {
            global.visualizer_defaults.smoothing = v;
            global.markDirty();
        },
        .viz_bands => |v| {
            global.visualizer_defaults.n_bands = 16 + @as(usize, @intFromFloat(@round(v * (256.0 - 16.0))));
            global.markDirty();
        },
        .viz_sensitivity => |v| {
            global.visualizer_defaults.sensitivity = 0.5 + v * 4.5;
            global.markDirty();
        },
        .viz_bar_gap => |v| {
            global.visualizer_defaults.bar_gap = v * 16.0;
            global.markDirty();
        },
        .eq_toggle => {
            global.playback.eq.enabled = !global.playback.eq.enabled;
            applyEQ(app, global);
            global.markDirty();
        },
        .eq_low_gain => |v| {
            global.playback.eq.low.gain_db = v * 48.0 - 24.0;
            applyEQ(app, global);
            global.markDirty();
        },
        .eq_mid_gain => |v| {
            global.playback.eq.mid.gain_db = v * 48.0 - 24.0;
            applyEQ(app, global);
            global.markDirty();
        },
        .eq_high_gain => |v| {
            global.playback.eq.high.gain_db = v * 48.0 - 24.0;
            applyEQ(app, global);
            global.markDirty();
        },
        .crossfade_change => |v| {
            global.playback.crossfade_ms = @intFromFloat(v * 10000.0);
            global.markDirty();
        },
        .gapless_toggle => {
            global.playback.gapless_in_group = !global.playback.gapless_in_group;
            global.markDirty();
        },
        .volume_change => |v| {
            global.playback.volume = v;
            if (ctx.runtime.playback_id) |pid| app.setSoundVolume(pid, v);
            global.markDirty();
        },
        .rescan_folder => app.openFileDialog(
            "audio,mp3,flac,wav,ogg,m4a",
            player.importPickedCb(@import("main.zig").AppMessage),
        ),
        .clear_library => global.clearLibrary(),
    }
    return .rebuild;
}

pub fn applyTheme(app: anytype, global: *const state_mod.AppGlobal) void {
    const is_dark = global.theme_mode == .dark;
    const oklch: [4]f32 = .{ global.accent_lightness, global.accent_chroma, global.accent_hue, 1.0 };
    const theme = lib.theme.Theme.init(oklch, is_dark);
    app.updateTheme(theme);
}

pub fn applyEQ(app: anytype, global: *const state_mod.AppGlobal) void {
    const eq = global.playback.eq;
    const cfg: lib.audio_engine.EQConfig = .{
        .enabled = eq.enabled,
        .low = .{ .freq_hz = eq.low.freq_hz, .gain_db = eq.low.gain_db, .q = eq.low.q },
        .mid = .{ .freq_hz = eq.mid.freq_hz, .gain_db = eq.mid.gain_db, .q = eq.mid.q },
        .high = .{ .freq_hz = eq.high.freq_hz, .gain_db = eq.high.gain_db, .q = eq.high.q },
    };
    app.setEQ(cfg) catch {};
}
