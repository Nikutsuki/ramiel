const std = @import("std");
const ramiel = @import("ramiel");
pub const tracy_impl = @import("tracy_impl");

const layout = ramiel.layout;
const tw = ramiel.tw;
const App = ramiel.Application(AppState, AppMessage);
const T = ramiel.For(AppMessage);

const battery = @import("modules/battery.zig");
const audio_mod = @import("modules/audio.zig");
const hyprland = @import("modules/hyprland.zig");
const clock_mod = @import("modules/clock.zig");
const icons = @import("icons.zig");

const AppMessage = union(enum) {
    switch_workspace: i32,
};

// Icon IDs
const ICON_VOL_HIGH: u32 = 100;
const ICON_VOL_MUTE: u32 = 101;
const ICON_VOL_LOW: u32 = 102;
const ICON_BAT_FULL: u32 = 103;
const ICON_BAT_CHARGE: u32 = 104;
const ICON_BAT_LOW: u32 = 105;

const AppState = struct {
    font: *ramiel.FontData = undefined,
    bat: battery.State = .{},
    vol: audio_mod.State = .{},
    hypr: hyprland.State = .{},
    time: clock_mod.State = .{},
    io: std.Io = undefined,
    env: *std.process.Environ.Map = undefined,
    // Icon texture IDs
    tex_vol_high: u32 = 0,
    tex_vol_mute: u32 = 0,
    tex_vol_low: u32 = 0,
    tex_bat_full: u32 = 0,
    tex_bat_charge: u32 = 0,
    tex_bat_low: u32 = 0,
};

const transparent = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
const pill_bg = [4]f32{ 0.10, 0.10, 0.16, 0.92 };
const fg = [4]f32{ 0.88, 0.90, 0.96, 1.0 };
const dim = [4]f32{ 0.52, 0.55, 0.66, 1.0 };
const accent = [4]f32{ 0.45, 0.65, 1.0, 1.0 };
const ws_active_bg = [4]f32{ 0.25, 0.32, 0.50, 1.0 };
const ws_hover = [4]f32{ 0.18, 0.20, 0.30, 0.9 };
const sep_color = [4]f32{ 0.25, 0.27, 0.35, 1.0 };
const danger = [4]f32{ 1.0, 0.40, 0.40, 1.0 };

const font_size = 15.0;
const icon_px = 16;
const pill_radius = 14.0;
const hover_transition = layout.TransitionStyle.forColors(150);

fn build(ui: *T.UIContext, state: *const AppState) anyerror!*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const font = state.font;

    // === LEFT PILL: Workspaces + window title ===
    var left_items: std.ArrayList(?*T.Node) = .empty;

    if (state.hypr.available) {
        for (state.hypr.workspaces[0..state.hypr.workspace_count]) |ws| {
            const label = if (ws.name_len > 0) ws.nameSlice() else try std.fmt.allocPrint(arena, "{d}", .{ws.id});
            const bg: [4]f32 = if (ws.active) ws_active_bg else transparent;
            const text_color: [4]f32 = if (ws.active) accent else if (ws.windows > 0) fg else dim;
            try left_items.append(arena, try ux.div(.{
                .style = tw.style(.{
                    tw.p_xy_px(10, 4),
                    tw.bg_value(bg),
                    tw.hover_value(ws_hover),
                    tw.rounded(10),
                    tw.cursor_pointer,
                    tw.transition(hover_transition),
                }),
                .on_click = .{ .switch_workspace = ws.id },
                .children = &.{
                    try ux.text(.{
                        .content = label,
                        .font = font,
                        .style = tw.style(.{ tw.text(font_size), tw.text_color_value(text_color) }),
                    }),
                },
            }));
        }
    }

    const title = if (state.hypr.title_len > 0) state.hypr.activeTitle() else "";
    if (title.len > 0) {
        try left_items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(8)}) }));
        try left_items.append(arena, try ux.text(.{
            .content = "|",
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(sep_color) }),
        }));
        try left_items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(8)}) }));
        const truncated = if (title.len > 50) title[0..50] else title;
        try left_items.append(arena, try ux.text(.{
            .content = truncated,
            .font = font,
            .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(dim) }),
        }));
    }

    const left_pill = try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.gap_px(2),
            tw.p_each_px(4, 12, 4, 6),
            tw.bg_value(pill_bg),
            tw.rounded(pill_radius),
        }),
        .children = left_items.items,
    });

    // === CENTER PILL: Clock ===
    const center_pill = try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.gap_px(8),
            tw.p_xy_px(16, 4),
            tw.bg_value(pill_bg),
            tw.rounded(pill_radius),
        }),
        .children = &.{
            try ux.text(.{
                .content = try std.fmt.allocPrint(arena, "{s} {d:0>2} {s}  {d:0>2}:{d:0>2}", .{
                    state.time.weekday, state.time.day, monthName(state.time.month),
                    state.time.hour, state.time.minute,
                }),
                .font = font,
                .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
            }),
        },
    });

    // === RIGHT PILL: Volume icon + % | Battery icon + % ===
    var right_items: std.ArrayList(?*T.Node) = .empty;

    // Volume icon
    const vol_tex = if (state.vol.muted) state.tex_vol_mute else if (state.vol.volume_pct < 30) state.tex_vol_low else state.tex_vol_high;
    try right_items.append(arena, try ux.image(.{
        .tex_id = vol_tex,
        .tint = fg,
        .style = tw.style(.{tw.square(icon_px)}),
    }));
    try right_items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(6)}) }));
    try right_items.append(arena, try ux.text(.{
        .content = if (state.vol.available) try std.fmt.allocPrint(arena, "{d}%", .{state.vol.volume_pct}) else "--",
        .font = font,
        .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
    }));

    // Battery
    if (state.bat.present) {
        try right_items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(12)}) }));
        try right_items.append(arena, try ux.text(.{
            .content = "|",
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(sep_color) }),
        }));
        try right_items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(12)}) }));

        const bat_color: [4]f32 = if (state.bat.capacity <= 15 and !state.bat.charging) danger else fg;
        const bat_tex = if (state.bat.charging) state.tex_bat_charge else if (state.bat.capacity <= 15) state.tex_bat_low else state.tex_bat_full;

        try right_items.append(arena, try ux.image(.{
            .tex_id = bat_tex,
            .tint = bat_color,
            .style = tw.style(.{tw.square(icon_px)}),
        }));
        try right_items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(6)}) }));

        const bat_status = if (state.bat.charging) "+" else "";
        try right_items.append(arena, try ux.text(.{
            .content = try std.fmt.allocPrint(arena, "{d}%{s}", .{ state.bat.capacity, bat_status }),
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(bat_color) }),
        }));
    }

    const right_pill = try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.p_xy_px(14, 4),
            tw.bg_value(pill_bg),
            tw.rounded(pill_radius),
        }),
        .children = right_items.items,
    });

    // 3-column layout: left / center / right
    return try ux.div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.flex_row,
            tw.items_center,
            tw.px(2), // 8px each side
            tw.bg_value(transparent),
        }),
        .children = &.{
            try ux.div(.{
                .style = tw.style(.{ tw.w_frac(1, 3), tw.flex_row, tw.items_center, tw.justify_start }),
                .children = &.{left_pill},
            }),
            try ux.div(.{
                .style = tw.style(.{ tw.w_frac(1, 3), tw.flex_row, tw.items_center, tw.justify_center }),
                .children = &.{center_pill},
            }),
            try ux.div(.{
                .style = tw.style(.{ tw.w_frac(1, 3), tw.flex_row, tw.items_center, tw.justify_end }),
                .children = &.{right_pill},
            }),
        },
    });
}

fn monthName(m: u8) []const u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (m >= 1 and m <= 12) return names[m - 1];
    return "???";
}

fn update(app: *App, msg: T.InteractionMessage) ramiel.UpdateAction {
    switch (msg.id) {
        .switch_workspace => |ws_id| {
            // Optimistic update
            for (app.state.hypr.workspaces[0..app.state.hypr.workspace_count]) |*ws| {
                ws.active = (ws.id == ws_id);
            }
            app.state.hypr.active_workspace_id = ws_id;

            // Direct IPC — no process spawn
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "dispatch workspace {d}", .{ws_id}) catch return .rebuild;
            hyprland.dispatch(app.state.io, app.state.env, cmd);
            return .rebuild;
        },
    }
}

// Hyprland state — updated by event socket thread, read by main thread.
var hypr_state: hyprland.State = .{};
var hypr_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Slow-poll state (battery, volume, clock) — updated by a timer thread.
var bg_bat: battery.State = .{};
var bg_vol: audio_mod.State = .{};
var bg_time: clock_mod.State = .{};
var bg_slow_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn hyprlandWorker(io: std.Io, env: *std.process.Environ.Map) void {
    hyprland.eventLoop(io, env, &hypr_state, &hypr_ready);
}

fn slowPollWorker(io: std.Io) void {
    while (true) {
        bg_bat = battery.poll();
        bg_vol = audio_mod.poll(io);
        bg_time = clock_mod.poll(io);
        bg_slow_ready.store(true, .release);
        var ts = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

fn tick(app: *App) ramiel.UpdateAction {
    var changed = false;

    // Hyprland events (instant)
    if (hypr_ready.swap(false, .acquire)) {
        app.state.hypr = hypr_state;
        changed = true;
    }

    // Slow poll (battery, volume, clock)
    if (bg_slow_ready.swap(false, .acquire)) {
        app.state.bat = bg_bat;
        app.state.vol = bg_vol;
        app.state.time = bg_time;
        changed = true;
    }

    return if (changed) .rebuild else .none;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = ramiel.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var app = try App.init(allocator, io, .{
        .backend = .wayland,
        .surface_kind = .{ .layer_shell = .{
            .layer = .top,
            .anchors = .{ .top = true, .left = true, .right = true },
            .exclusive_zone = 36,
            .keyboard_interactivity = .none,
            .namespace = "ramiel-bar",
            .margin = .{ .top = 4, .left = 4, .right = 4 },
        } },
        .transparent = true,
        .width = 0,
        .height = 36,
    }, .{ .io = io, .env = init.environ_map }, update);
    defer app.deinit();

    app.state.font = try app.loadDefaultFont(
        "JetBrains Mono",
        .{ .memory = ramiel.assets.getFontData(.jetbrains_mono) },
        16,
    );

    // Load SVG icons
    try app.loadIconSvgFromMemory(ICON_VOL_HIGH, icons.volume_high, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_VOL_MUTE, icons.volume_mute, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_VOL_LOW, icons.volume_low, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_FULL, icons.battery_full, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_CHARGE, icons.battery_charging, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_LOW, icons.battery_low, icon_px, icon_px, 1.0);

    // Resolve texture IDs
    app.state.tex_vol_high = app.getIconTextureId(ICON_VOL_HIGH, 1.0) orelse 0;
    app.state.tex_vol_mute = app.getIconTextureId(ICON_VOL_MUTE, 1.0) orelse 0;
    app.state.tex_vol_low = app.getIconTextureId(ICON_VOL_LOW, 1.0) orelse 0;
    app.state.tex_bat_full = app.getIconTextureId(ICON_BAT_FULL, 1.0) orelse 0;
    app.state.tex_bat_charge = app.getIconTextureId(ICON_BAT_CHARGE, 1.0) orelse 0;
    app.state.tex_bat_low = app.getIconTextureId(ICON_BAT_LOW, 1.0) orelse 0;

    app.setTickFn(tick, 0.05); // check for background results every 50ms

    // Initial data
    app.state.bat = battery.poll();
    app.state.vol = audio_mod.poll(io);
    app.state.hypr = hyprland.poll(io, init.environ_map);
    app.state.time = clock_mod.poll(io);

    // Hyprland event socket thread (instant workspace/window updates)
    const hypr_thread = try std.Thread.spawn(.{}, hyprlandWorker, .{ io, init.environ_map });
    hypr_thread.detach();

    // Slow poll thread (battery, volume, clock — every 1s)
    const slow_thread = try std.Thread.spawn(.{}, slowPollWorker, .{io});
    slow_thread.detach();

    try app.setRootBuilder(build);
    try app.run();
}
