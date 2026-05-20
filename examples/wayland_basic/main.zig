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
const tray_mod = @import("modules/tray.zig");
const network_mod = @import("modules/network.zig");
const power_mod = @import("modules/power.zig");
const settings_mod = @import("modules/settings.zig");
const icons = @import("icons.zig");

const NodeIds = ramiel.declareIds("wayland-basic", .{
    "bar_row",
    "hot_corner",
    "slide_panel",
    "tray_menu",
    "power_menu",
    "power_card",
    "power_header",
    "pwr_lock",
    "pwr_suspend",
    "pwr_logout",
    "pwr_reboot",
    "pwr_shutdown",
    "settings_menu",
    "settings_card",
    "set_accent_swatch",
    "set_track_0",
    "set_track_1",
    "set_track_2",
    "set_track_3",
    "set_track_4",
    "set_track_5",
    "set_track_6",
    "set_track_7",
    "set_knob_0",
    "set_knob_1",
    "set_knob_2",
    "set_knob_3",
    "set_knob_4",
    "set_knob_5",
    "set_knob_6",
    "set_knob_7",
}){};

const set_track_ids = [_]u32{
    NodeIds.set_track_0, NodeIds.set_track_1, NodeIds.set_track_2, NodeIds.set_track_3,
    NodeIds.set_track_4, NodeIds.set_track_5, NodeIds.set_track_6, NodeIds.set_track_7,
};
const set_knob_ids = [_]u32{
    NodeIds.set_knob_0, NodeIds.set_knob_1, NodeIds.set_knob_2, NodeIds.set_knob_3,
    NodeIds.set_knob_4, NodeIds.set_knob_5, NodeIds.set_knob_6, NodeIds.set_knob_7,
};

const AppMessage = union(enum) {
    switch_workspace: i32,
    edge_hover: bool,
    panel_hover: bool,
    panel_force_close: void,
    tray_menu: ?usize,
    tray_menu_hover: bool,
    tray_action: tray_mod.MenuAction,
    toggle_power_menu: void,
    close_power_menu: void,
    power_action: power_mod.Action,
    toggle_settings_menu: void,
    close_settings_menu: void,
    toggle_setting: settings_mod.Key,
    cycle_accent: void,
    cycle_rounding: void,
    noop: void,
};

const ICON_VOL_HIGH: u32 = 100;
const ICON_VOL_MUTE: u32 = 101;
const ICON_VOL_LOW: u32 = 102;
const ICON_BAT_FULL: u32 = 103;
const ICON_BAT_CHARGE: u32 = 104;
const ICON_BAT_LOW: u32 = 105;
const ICON_TRAY_NETWORK: u32 = 106;
const ICON_TRAY_MESSAGES: u32 = 107;
const ICON_TRAY_UPDATES: u32 = 108;
const ICON_PWR_LOCK: u32 = 110;
const ICON_PWR_SUSPEND: u32 = 111;
const ICON_PWR_LOGOUT: u32 = 112;
const ICON_PWR_REBOOT: u32 = 113;
const ICON_PWR_SHUTDOWN: u32 = 114;
const ICON_WIFI: u32 = 115;
const ICON_TUNE: u32 = 116;

const AppState = struct {
    font: *ramiel.FontData = undefined,
    bat: battery.State = .{},
    vol: audio_mod.State = .{},
    hypr: hyprland.State = .{},
    time: clock_mod.State = .{},
    tray: tray_mod.State = tray_mod.demoState(),
    net: network_mod.State = .{},
    power_menu_open: bool = false,
    // Flipped true one frame after open so the entrance has a change to animate.
    power_revealed: bool = false,
    power_confirm: ?power_mod.Action = null,
    settings: settings_mod.Settings = .{},
    settings_menu_open: bool = false,
    settings_revealed: bool = false,
    slide_panel_open: bool = false,
    hide_panel_at_ns: i128 = 0,
    edge_hovered: bool = false,
    panel_hovered: bool = false,
    open_tray_menu: ?usize = null,
    tray_menu_hovered: bool = false,
    hide_tray_menu_at_ns: i128 = 0,
    io: std.Io = undefined,
    env: *std.process.Environ.Map = undefined,
    tex_vol_high: u32 = 0,
    tex_vol_mute: u32 = 0,
    tex_vol_low: u32 = 0,
    tex_bat_full: u32 = 0,
    tex_bat_charge: u32 = 0,
    tex_bat_low: u32 = 0,
    tex_tray_network: u32 = 0,
    tex_tray_messages: u32 = 0,
    tex_tray_updates: u32 = 0,
    tex_pwr_lock: u32 = 0,
    tex_pwr_suspend: u32 = 0,
    tex_pwr_logout: u32 = 0,
    tex_pwr_reboot: u32 = 0,
    tex_pwr_shutdown: u32 = 0,
    tex_wifi: u32 = 0,
    tex_tune: u32 = 0,

    // Persisted surface: only the user settings round-trip to disk.
    pub const snapshot_version: ramiel.state.SnapshotVersion = 1;
    pub const Snapshot = struct { settings: settings_mod.Settings = .{} };

    pub fn snapshot(self: *const AppState) Snapshot {
        return .{ .settings = self.settings };
    }
    pub fn restoreSnapshot(self: *AppState, data: *const Snapshot) !void {
        self.settings = data.settings;
    }
};

const settings_file = "settings.json";

fn settingsLoad(app: *App, io: std.Io) void {
    var dbuf: [512]u8 = undefined;
    const dir = settings_mod.configDir(app.state.env, &dbuf) orelse return;
    var pbuf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, settings_file }) catch return;
    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, std.heap.page_allocator, .limited(8192)) catch return;
    defer std.heap.page_allocator.free(bytes);

    var parsed = ramiel.state.parseEnvelope(AppState.Snapshot, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    ramiel.state.expectEnvelopeVersion(AppState.Snapshot, &parsed, AppState.snapshot_version) catch return;
    app.state.restoreSnapshot(&parsed.value.data) catch {};
}

fn settingsSave(app: *App, io: std.Io) void {
    const json = ramiel.state.stringifyEnvelopeAlloc(AppState.Snapshot, std.heap.page_allocator, AppState.snapshot_version, app.state.snapshot(), .{}) catch return;
    defer std.heap.page_allocator.free(json);

    var dbuf: [512]u8 = undefined;
    const dir = settings_mod.configDir(app.state.env, &dbuf) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var pbuf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, settings_file }) catch return;
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = path, .data = json }) catch {};
}

const transparent = [4]f32{ 0.0, 0.0, 0.0, 0.0 };

// Theme-driven colors: resolved from the active Theme's semantic tokens by
// applyTheme() and re-applied whenever the user changes a theme setting. Kept as
// module vars so the existing tw.*_value(...) call sites need no changes.
var pill_bg = [4]f32{ 0.10, 0.10, 0.16, 0.92 };
var pill_border = [4]f32{ 0.45, 0.65, 1.0, 1.0 };
var panel_bg = [4]f32{ 0.08, 0.09, 0.14, 0.96 };
var menu_bg = [4]f32{ 0.08, 0.09, 0.14, 0.98 };
var fg = [4]f32{ 0.88, 0.90, 0.96, 1.0 };
var dim = [4]f32{ 0.52, 0.55, 0.66, 1.0 };
var accent = [4]f32{ 0.45, 0.65, 1.0, 1.0 };
var ws_active_bg = [4]f32{ 0.25, 0.32, 0.50, 1.0 };
var ws_hover = [4]f32{ 0.18, 0.20, 0.30, 0.9 };
var sep_color = [4]f32{ 0.25, 0.27, 0.35, 1.0 };
var danger = [4]f32{ 1.0, 0.40, 0.40, 1.0 };

// Driven by the border/rounding settings.
var pill_border_w: f32 = 2.0;
var pill_radius: f32 = 14.0;
const base_pill_radius = 14.0;

const font_size = 15.0;
const icon_px = 20;
const tray_icon_px = 20;
const tray_icon_box = 24;
const bar_h = 36.0;

fn withA(c: [4]f32, a: f32) [4]f32 {
    return .{ c[0], c[1], c[2], a };
}

/// Rebuild the theme from settings and push it into the color vars, the border
/// width, the pill radius, and the UI context (for any token-styled widgets).
fn applyTheme(app: *App) void {
    const s = app.state.settings;
    const o = s.accent.oklch();
    const t = ramiel.Theme.fromOklch(.{ .l = o.l, .c = o.c, .h = o.h }, if (s.dark_mode) .dark else .light);
    const k = t.tokens;

    pill_bg = withA(k.bg_surface, 0.92);
    panel_bg = withA(k.bg_base, 0.96);
    menu_bg = withA(k.bg_elevated, 0.98);
    fg = k.text_main;
    dim = k.text_muted;
    accent = k.accent_default;
    pill_border = k.accent_default;
    ws_active_bg = k.accent_subtle;
    ws_hover = withA(k.bg_elevated, 0.9);
    sep_color = k.border_subtle;
    danger = k.status_danger;

    pill_border_w = if (s.border_enabled) 2.0 else 0.0;
    pill_radius = base_pill_radius * s.rounding.scale();

    app.updateTheme(t);
}
const hover_transition = layout.TransitionStyle.forColors(150);
// Panel slides in from the right and fades simultaneously.
const panel_transition = layout.TransitionStyle{
    .property = .{ .translate = true, .opacity = true },
    .duration_ms = 240,
    .timing = .ease_out,
};
// Card slides only (opacity stays on the children — see buildPowerMenu).
const card_transition = layout.TransitionStyle{
    .property = .{ .translate = true },
    .duration_ms = 300,
    .timing = .ease_out,
};
const overlay_transition = layout.TransitionStyle.forColors(280);

const switch_track_transition = layout.TransitionStyle.forColors(150);
const switch_knob_transition = layout.TransitionStyle.forTransform(180);

// Staggered entrance fade; each row passes its own delay.
fn fadeIn(delay_ms: u32) layout.TransitionStyle {
    return .{
        .property = .{ .opacity = true },
        .duration_ms = 220,
        .delay_ms = delay_ms,
        .timing = .ease_out,
    };
}
const panel_hide_delay_ns: i128 = 300 * std.time.ns_per_ms;
const tray_menu_hide_delay_ns: i128 = 300 * std.time.ns_per_ms;

fn build(ui: *T.UIContext, state: *const AppState) anyerror!*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const bar_row = try buildBar(ui, state);
    const hot_corner = try ux.div(.{
        .id = NodeIds.hot_corner,
        .style = tw.style(.{
            tw.absolute,
            tw.top(0),
            tw.right(0),
            tw.bottom(0),
            tw.w(8),
            tw.z(30),
            tw.bg_value(transparent),
            tw.cursor_pointer,
        }),
        .on_hover_enter = .{ .edge_hover = true },
        .on_hover_exit = .{ .edge_hover = false },
    });

    var children: std.ArrayList(?*T.Node) = .empty;
    try children.append(arena, bar_row);
    try children.append(arena, hot_corner);
    try children.append(arena, try buildSlidePanel(ui, state));
    if (state.open_tray_menu) |item_id| {
        if (state.tray.itemById(item_id)) |item| {
            try children.append(arena, try buildTrayMenu(ui, state, item));
        }
    }
    if (state.power_menu_open) {
        try children.append(arena, try buildPowerMenu(ui, state));
    }
    if (state.settings_menu_open) {
        try children.append(arena, try buildSettingsMenu(ui, state));
    }

    return try ux.div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.relative,
            tw.overflow_hidden,
            tw.bg_value(transparent),
        }),
        .children = children.items,
    });
}

fn buildBar(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const font = state.font;

    var left_items: std.ArrayList(?*T.Node) = .empty;
    if (state.hypr.available and state.settings.show_workspaces) {
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
                .children = &.{try ux.text(.{
                    .content = label,
                    .font = font,
                    .style = tw.style(.{ tw.text(font_size), tw.text_color_value(text_color) }),
                })},
            }));
        }
    }

    const title = if (state.hypr.title_len > 0) state.hypr.activeTitle() else "";
    if (title.len > 0 and state.settings.show_title) {
        try appendSeparator(ui, &left_items, arena, font, 8);
        const truncated = if (title.len > 50) title[0..50] else title;
        try left_items.append(arena, try ux.text(.{
            .content = truncated,
            .font = font,
            .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(dim) }),
        }));
    }

    const left_pill = if (left_items.items.len == 0)
        try ux.div(.{ .style = tw.style(.{}) })
    else
        try ux.div(.{
            .style = tw.style(.{
                tw.flex_row,
                tw.items_center,
                tw.gap_px(2),
                tw.p_each_px(4, 12, 4, 6),
                tw.bg_value(pill_bg),
                tw.rounded(pill_radius),
                tw.border_value(pill_border_w, pill_border),
            }),
            .children = left_items.items,
        });

    const center_pill = try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.gap_px(8),
            tw.p_xy_px(16, 4),
            tw.bg_value(pill_bg),
            tw.rounded(pill_radius),
            tw.border_value(pill_border_w, pill_border),
        }),
        .children = &.{try ux.text(.{
            .content = try formatClock(arena, state.time, state.settings.clock_24h),
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
        })},
    });

    var right_items: std.ArrayList(?*T.Node) = .empty;
    if (state.settings.show_volume) {
        const vol_tex = if (state.vol.muted) state.tex_vol_mute else if (state.vol.volume_pct < 30) state.tex_vol_low else state.tex_vol_high;
        try right_items.append(arena, try ux.image(.{
            .tex_id = vol_tex,
            .tint = fg,
            .style = tw.style(.{tw.square(icon_px)}),
        }));
        try right_items.append(arena, try ux.text(.{
            .content = if (state.vol.available) try std.fmt.allocPrint(arena, "{d}%", .{state.vol.volume_pct}) else "--",
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
        }));
    }

    if (state.bat.present and state.settings.show_battery) {
        if (right_items.items.len > 0) try appendSeparator(ui, &right_items, arena, font, 6);
        const bat_color: [4]f32 = if (state.bat.capacity <= 15 and !state.bat.charging) danger else fg;
        const bat_tex = if (state.bat.charging) state.tex_bat_charge else if (state.bat.capacity <= 15) state.tex_bat_low else state.tex_bat_full;
        try right_items.append(arena, try ux.image(.{
            .tex_id = bat_tex,
            .tint = bat_color,
            .style = tw.style(.{tw.square(icon_px)}),
        }));
            const bat_status = if (state.bat.charging) "+" else "";
        try right_items.append(arena, try ux.text(.{
            .content = try std.fmt.allocPrint(arena, "{d}%{s}", .{ state.bat.capacity, bat_status }),
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(bat_color) }),
        }));
    }

    if (state.tray.available and state.tray.item_count > 0 and state.settings.show_tray) {
        if (right_items.items.len > 0) try appendSeparator(ui, &right_items, arena, font, 6);
        for (state.tray.itemSlice()) |item| {
            try right_items.append(arena, try buildTrayIcon(ui, state, item));
        }
    }

    const right_pill = try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.gap_px(6),
            tw.p_xy_px(14, 4),
            tw.bg_value(pill_bg),
            tw.rounded(pill_radius),
            tw.border_value(pill_border_w, pill_border),
        }),
        .children = right_items.items,
    });

    return try ux.div(.{
        .id = NodeIds.bar_row,
        .style = tw.style(.{
            tw.absolute,
            tw.top(4),
            tw.left(4),
            tw.right(4),
            tw.h(bar_h),
            tw.flex_row,
            tw.items_center,
            tw.p_xy_px(6, 0),
            tw.bg_value(transparent),
            tw.z(10),
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

fn appendSeparator(ui: *T.UIContext, items: *std.ArrayList(?*T.Node), arena: std.mem.Allocator, font: *ramiel.FontData, width: f32) !void {
    const ux = ui.ux();
    try items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(width)}) }));
    try items.append(arena, try ux.text(.{
        .content = "|",
        .font = font,
        .style = tw.style(.{ tw.text(font_size), tw.text_color_value(sep_color) }),
    }));
    try items.append(arena, try ux.div(.{ .style = tw.style(.{tw.w(width)}) }));
}

fn buildTrayIcon(ui: *T.UIContext, state: *const AppState, item: tray_mod.Item) !*T.Node {
    const ux = ui.ux();
    const active = state.open_tray_menu != null and state.open_tray_menu.? == item.id;
    return try ux.div(.{
        .style = tw.style(.{
            tw.square(tray_icon_box),
            tw.flex_row,
            tw.items_center,
            tw.justify_center,
            tw.bg_value(if (active) ws_active_bg else transparent),
            tw.hover_value(ws_hover),
            tw.rounded(8),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        }),
        .on_click = .{ .tray_menu = item.id },
        .on_context_menu = .{ .tray_menu = item.id },
        .children = &.{try ux.image(.{
            .tex_id = trayTexture(state, item),
            .tint = if (item.real and item.tex_id != 0) [4]f32{ 1, 1, 1, 1 } else fg,
            .style = tw.style(.{tw.square(tray_icon_px)}),
        })},
    });
}

fn buildTrayMenu(ui: *T.UIContext, state: *const AppState, item: *const tray_mod.Item) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    var rows: std.ArrayList(?*T.Node) = .empty;

    try rows.append(arena, try ux.div(.{
        .style = tw.style(.{ tw.flex_col, tw.gap_px(2), tw.p_each_px(2, 4, 8, 4) }),
        .children = &.{
            try ux.text(.{
                .content = item.title(),
                .font = state.font,
                .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
            }),
            try ux.text(.{
                .content = item.status(),
                .font = state.font,
                .style = tw.style(.{ tw.text(font_size - 2), tw.text_color_value(dim) }),
            }),
        },
    }));

    for (item.menuItems()) |*menu_item| {
        if (menu_item.kind == .separator) {
            try rows.append(arena, try ux.div(.{
                .style = tw.style(.{ tw.h(1), tw.bg_value(sep_color), tw.m_each_px(6, 4, 6, 4) }),
            }));
            continue;
        }

        const raw_label = menu_item.label();
        const label = if (menu_item.has_toggle and menu_item.checked)
            try std.fmt.allocPrint(arena, "[x] {s}", .{raw_label})
        else
            raw_label;
        const row_style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.justify_between,
            tw.p_xy_px(10, 7),
            tw.bg_value(transparent),
            tw.hover_value(if (menu_item.enabled) ws_hover else transparent),
            tw.rounded(8),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        });
        if (menu_item.enabled) {
            try rows.append(arena, try ux.div(.{
                .style = row_style,
                .on_click = .{ .tray_action = menu_item.action },
                .children = &.{try ux.text(.{
                    .content = label,
                    .font = state.font,
                    .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(fg) }),
                })},
            }));
        } else {
            try rows.append(arena, try ux.div(.{
                .style = row_style,
                .children = &.{try ux.text(.{
                    .content = label,
                    .font = state.font,
                    .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(dim) }),
                })},
            }));
        }
    }

    return try ux.div(.{
        .id = NodeIds.tray_menu,
        .style = tw.style(.{
            tw.absolute,
            tw.top(40),
            tw.right(8),
            tw.w(240),
            tw.p_px(8),
            tw.flex_col,
            tw.bg_value(menu_bg),
            tw.border_value(1, sep_color),
            tw.rounded(14),
            tw.z(24),
        }),
        .on_hover_enter = .{ .tray_menu_hover = true },
        .on_hover_exit = .{ .tray_menu_hover = false },
        .children = rows.items,
    });
}

fn buildPowerMenu(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const revealed = state.power_revealed;

    const actions = [_]power_mod.Action{ .lock, .suspend_, .logout, .reboot, .shutdown };
    const btn_ids = [_]u32{ NodeIds.pwr_lock, NodeIds.pwr_suspend, NodeIds.pwr_logout, NodeIds.pwr_reboot, NodeIds.pwr_shutdown };

    var rows: std.ArrayList(?*T.Node) = .empty;

    try rows.append(arena, try ux.div(.{
        .id = NodeIds.power_header,
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.gap_px(10),
            tw.p_each_px(0, 4, 12, 4),
            tw.opacity(if (revealed) 1.0 else 0.0),
            tw.transition(fadeIn(40)),
        }),
        .children = &.{
            try ux.image(.{ .tex_id = state.tex_pwr_shutdown, .tint = accent, .style = tw.style(.{tw.square(22)}) }),
            try ux.text(.{
                .content = "Power",
                .font = state.font,
                .style = tw.style(.{ tw.text(20), tw.text_color_value(fg) }),
            }),
        },
    }));

    for (actions, 0..) |action, idx| {
        const confirming = state.power_confirm != null and state.power_confirm.? == action;
        const destructive = action.needsConfirm();
        const label = if (confirming)
            try std.fmt.allocPrint(arena, "Confirm {s}?", .{action.label()})
        else
            action.label();
        const base_bg: [4]f32 = if (confirming) danger else pill_bg;
        const text_col: [4]f32 = if (confirming) fg else if (destructive) danger else fg;
        const icon_tint: [4]f32 = if (confirming) fg else if (destructive) danger else accent;

        try rows.append(arena, try ux.div(.{
            .id = btn_ids[idx],
            .style = tw.style(.{
                tw.flex_row,
                tw.items_center,
                tw.gap_px(14),
                tw.w(248),
                tw.p_xy_px(14, 12),
                tw.bg_value(base_bg),
                tw.hover_value(ws_active_bg),
                tw.rounded(14),
                tw.border_value(1.0, sep_color),
                tw.cursor_pointer,
                tw.opacity(if (revealed) 1.0 else 0.0),
                tw.transition(fadeIn(@intCast(110 + 70 * idx))),
            }),
            .on_click = .{ .power_action = action },
            .children = &.{
                try ux.image(.{ .tex_id = powerActionTex(state, action), .tint = icon_tint, .style = tw.style(.{tw.square(20)}) }),
                try ux.text(.{
                    .content = label,
                    .font = state.font,
                    .style = tw.style(.{ tw.text(font_size + 1), tw.text_color_value(text_col) }),
                }),
            },
        }));
    }

    const card = try ux.div(.{
        .id = NodeIds.power_card,
        .style = tw.style(.{
            tw.flex_col,
            tw.items_start,
            tw.gap_px(8),
            tw.p_px(22),
            tw.bg_value(menu_bg),
            tw.border_value(1.0, sep_color),
            tw.rounded(22),
            // Card only slides; children fade (one opacity level).
            .{ .transform = layout.Transform{ .translate = .{ 0, if (revealed) 0 else 24 } } },
            tw.transition(card_transition),
        }),
        .on_click = .noop,
        .children = rows.items,
    });

    // Dimmed backdrop; click outside the card closes it. size_screen (not inset)
    // so flex centering has real dimensions.
    const overlay_bg: [4]f32 = if (revealed) .{ 0.0, 0.0, 0.0, 0.5 } else transparent;
    return try ux.div(.{
        .id = NodeIds.power_menu,
        .style = tw.style(.{
            tw.absolute,
            tw.top(0),
            tw.left(0),
            tw.size_screen,
            tw.flex_col,
            tw.items_center,
            tw.justify_center,
            tw.bg_value(overlay_bg),
            tw.transition(overlay_transition),
            tw.z(40),
        }),
        .on_click = .close_power_menu,
        .children = &.{card},
    });
}

fn powerActionTex(state: *const AppState, action: power_mod.Action) u32 {
    return switch (action) {
        .lock => state.tex_pwr_lock,
        .suspend_ => state.tex_pwr_suspend,
        .logout => state.tex_pwr_logout,
        .reboot => state.tex_pwr_reboot,
        .shutdown => state.tex_pwr_shutdown,
    };
}

fn buildSettingsMenu(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const revealed = state.settings_revealed;

    var rows: std.ArrayList(?*T.Node) = .empty;

    try rows.append(arena, try ux.div(.{
        .style = tw.style(.{ tw.flex_row, tw.items_center, tw.gap_px(10), tw.p_each_px(0, 4, 12, 4) }),
        .children = &.{
            try ux.image(.{ .tex_id = state.tex_tune, .tint = accent, .style = tw.style(.{tw.square(22)}) }),
            try ux.text(.{ .content = "Settings", .font = state.font, .style = tw.style(.{ tw.text(20), tw.text_color_value(fg) }) }),
        },
    }));

    for (settings_mod.keys, 0..) |key, idx| {
        try rows.append(arena, try buildSettingRow(ui, state, key, idx));
    }
    try rows.append(arena, try buildAccentRow(ui, state));
    try rows.append(arena, try buildCycleRow(ui, state, "Rounding", state.settings.rounding.label(), .cycle_rounding));

    const card = try ux.div(.{
        .id = NodeIds.settings_card,
        .style = tw.style(.{
            tw.flex_col,
            tw.items_start,
            tw.gap_px(8),
            tw.w(320),
            tw.p_px(22),
            tw.bg_value(menu_bg),
            tw.border_value(1.0, sep_color),
            tw.rounded(22),
            .{ .transform = layout.Transform{ .translate = .{ 0, if (revealed) 0 else 24 } } },
            tw.transition(card_transition),
        }),
        .on_click = .noop,
        .children = rows.items,
    });

    const overlay_bg: [4]f32 = if (revealed) .{ 0.0, 0.0, 0.0, 0.5 } else transparent;
    return try ux.div(.{
        .id = NodeIds.settings_menu,
        .style = tw.style(.{
            tw.absolute,
            tw.top(0),
            tw.left(0),
            tw.size_screen,
            tw.flex_col,
            tw.items_center,
            tw.justify_center,
            tw.bg_value(overlay_bg),
            tw.transition(overlay_transition),
            tw.z(41),
        }),
        .on_click = .close_settings_menu,
        .children = &.{card},
    });
}

fn buildSettingRow(ui: *T.UIContext, state: *const AppState, key: settings_mod.Key, idx: usize) !*T.Node {
    const ux = ui.ux();
    const on = settings_mod.get(state.settings, key);
    const track_bg: [4]f32 = if (on) accent else sep_color;
    const knob_x: f32 = if (on) 22 else 3;

    const knob = try ux.div(.{
        .id = set_knob_ids[idx],
        .style = tw.style(.{
            tw.square(18),
            tw.rounded(9),
            tw.bg_value(fg),
            .{ .transform = layout.Transform{ .translate = .{ knob_x, 0 } } },
            tw.transition(switch_knob_transition),
        }),
    });

    const track = try ux.div(.{
        .id = set_track_ids[idx],
        .style = tw.style(.{
            tw.w(44),
            tw.h(24),
            tw.flex_row,
            tw.items_center,
            tw.rounded(12),
            tw.bg_value(track_bg),
            tw.transition(switch_track_transition),
        }),
        .children = &.{knob},
    });

    return try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.justify_between,
            tw.gap_px(12),
            tw.w_full,
            tw.p_xy_px(12, 8),
            tw.bg_value(pill_bg),
            tw.hover_value(ws_hover),
            tw.rounded(12),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        }),
        .on_click = .{ .toggle_setting = key },
        .children = &.{
            try ux.text(.{ .content = key.label(), .font = state.font, .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }) }),
            track,
        },
    });
}

fn buildAccentRow(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    const swatch = try ux.div(.{
        .id = NodeIds.set_accent_swatch,
        .style = tw.style(.{
            tw.square(22),
            tw.rounded(11),
            tw.bg_value(accent),
            tw.border_value(2.0, fg),
            tw.transition(switch_track_transition),
        }),
    });
    return try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.justify_between,
            tw.gap_px(12),
            tw.w_full,
            tw.p_xy_px(12, 8),
            tw.bg_value(pill_bg),
            tw.hover_value(ws_hover),
            tw.rounded(12),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        }),
        .on_click = .cycle_accent,
        .children = &.{
            try ux.text(.{ .content = "Accent", .font = state.font, .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }) }),
            swatch,
        },
    });
}

fn buildCycleRow(ui: *T.UIContext, state: *const AppState, label: []const u8, value: []const u8, msg: AppMessage) !*T.Node {
    const ux = ui.ux();
    return try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.justify_between,
            tw.gap_px(12),
            tw.w_full,
            tw.p_xy_px(12, 8),
            tw.bg_value(pill_bg),
            tw.hover_value(ws_hover),
            tw.rounded(12),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        }),
        .on_click = msg,
        .children = &.{
            try ux.text(.{ .content = label, .font = state.font, .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }) }),
            try ux.text(.{ .content = value, .font = state.font, .style = tw.style(.{ tw.text(font_size), tw.text_color_value(accent) }) }),
        },
    });
}

fn buildSlidePanel(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const panel_w: f32 = 330;
    const panel_translate: f32 = if (state.slide_panel_open) 0 else panel_w + 28;
    var rows: std.ArrayList(?*T.Node) = .empty;

    try rows.append(arena, try buildNetworkSection(ui, state, panel_w));
    try rows.append(arena, try buildBatterySection(ui, state, panel_w));

    try rows.append(arena, try buildPanelMetric(ui, state, "Volume", if (state.vol.available) try std.fmt.allocPrint(arena, "{d}%", .{state.vol.volume_pct}) else "--"));
    try rows.append(arena, try buildPanelMetric(ui, state, "Workspace", if (state.hypr.available) try std.fmt.allocPrint(arena, "{d}", .{state.hypr.active_workspace_id}) else "Unavailable"));

    try rows.append(arena, try buildPanelActions(ui, state));

    if (state.tray.available) {
        for (state.tray.itemSlice()) |item| {
            try rows.append(arena, try buildPanelTrayRow(ui, state, item));
        }
    }

    return try ux.div(.{
        .id = NodeIds.slide_panel,
        .style = tw.style(.{
            tw.absolute,
            tw.top(44),
            tw.right(8),
            tw.w(panel_w),
            tw.p_px(16),
            tw.flex_col,
            tw.gap_px(12),
            tw.bg_value(panel_bg),
            tw.border_value(1, sep_color),
            tw.rounded(18),
            tw.opacity(if (state.slide_panel_open) 1.0 else 0.0),
            tw.translate(panel_translate, 0),
            tw.transition(panel_transition),
            tw.z(20),
        }),
        .on_hover_enter = .{ .panel_hover = true },
        .on_hover_exit = .{ .panel_hover = false },
        .children = rows.items,
    });
}

fn buildPanelMetric(ui: *T.UIContext, state: *const AppState, label: []const u8, value: []const u8) !*T.Node {
    const ux = ui.ux();
    return try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.justify_between,
            tw.gap_px(12),
            tw.w_full,
            tw.p_xy_px(12, 8),
            tw.bg_value(pill_bg),
            tw.rounded(12),
        }),
        .children = &.{
            try ux.text(.{ .content = label, .font = state.font, .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(dim) }) }),
            try ux.text(.{ .content = value, .font = state.font, .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(fg) }) }),
        },
    });
}

fn buildPanelActions(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    return try ux.div(.{
        .style = tw.style(.{ tw.flex_row, tw.items_center, tw.gap_px(8), tw.w_full }),
        .children = &.{
            try panelActionButton(ui, state, state.tex_tune, "Settings", .toggle_settings_menu),
            try panelActionButton(ui, state, state.tex_pwr_shutdown, "Power", .toggle_power_menu),
        },
    });
}

fn panelActionButton(ui: *T.UIContext, state: *const AppState, tex: u32, label: []const u8, msg: AppMessage) !*T.Node {
    const ux = ui.ux();
    return try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.justify_center,
            tw.gap_px(8),
            tw.grow(1),
            tw.p_xy_px(12, 10),
            tw.bg_value(pill_bg),
            tw.hover_value(ws_active_bg),
            tw.rounded(12),
            tw.border_value(1.0, sep_color),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        }),
        .on_click = msg,
        .children = &.{
            try ux.image(.{ .tex_id = tex, .tint = accent, .style = tw.style(.{tw.square(18)}) }),
            try ux.text(.{
                .content = label,
                .font = state.font,
                .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
            }),
        },
    });
}

fn buildSectionHeader(ui: *T.UIContext, state: *const AppState, title: []const u8, icon_tex: u32) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    var items: std.ArrayList(?*T.Node) = .empty;
    if (icon_tex != 0) {
        try items.append(arena, try ux.image(.{
            .tex_id = icon_tex,
            .tint = dim,
            .style = tw.style(.{tw.square(14)}),
        }));
    }
    try items.append(arena, try ux.text(.{
        .content = title,
        .font = state.font,
        .style = tw.style(.{ tw.text(font_size - 3), tw.text_color_value(dim) }),
    }));
    return try ux.div(.{
        .style = tw.style(.{ tw.flex_row, tw.items_center, tw.gap_px(6), tw.p_each_px(2, 0, 2, 2) }),
        .children = items.items,
    });
}

fn buildNetworkSection(ui: *T.UIContext, state: *const AppState, panel_w: f32) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const net = state.net;

    var rows: std.ArrayList(?*T.Node) = .empty;
    try rows.append(arena, try buildSectionHeader(ui, state, "NETWORK", state.tex_wifi));

    if (!net.connected) {
        try rows.append(arena, try buildPanelMetric(ui, state, "Status", if (net.available) "Disconnected" else "Unavailable"));
    } else {
        const kind_label: []const u8 = switch (net.kind) {
            .wifi => "Wi-Fi",
            .ethernet => "Ethernet",
            else => "Network",
        };
        const title = if (net.kind == .wifi and net.ssid_len > 0) net.ssid() else net.name();
        try rows.append(arena, try buildPanelMetric(ui, state, kind_label, title));
        if (net.kind == .wifi) {
            try rows.append(arena, try buildPanelMetric(ui, state, "Signal", try std.fmt.allocPrint(arena, "{d}%", .{net.signal})));
        }
        if (net.ip_len > 0) {
            try rows.append(arena, try buildPanelMetric(ui, state, "IP", net.ip()));
        }
    }

    return try ux.div(.{
        .style = tw.style(.{ tw.flex_col, tw.gap_px(6), tw.w(panel_w - 32) }),
        .children = rows.items,
    });
}

fn buildBatterySection(ui: *T.UIContext, state: *const AppState, panel_w: f32) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const bat = state.bat;

    var rows: std.ArrayList(?*T.Node) = .empty;
    try rows.append(arena, try buildSectionHeader(ui, state, "BATTERY", state.tex_bat_full));

    if (!bat.present) {
        try rows.append(arena, try buildPanelMetric(ui, state, "Status", "No battery"));
    } else {
        const total_label = if (bat.charging) "Total (charging)" else "Total";
        try rows.append(arena, try buildPanelMetric(ui, state, total_label, try std.fmt.allocPrint(arena, "{d}%", .{bat.capacity})));

        for (bat.slice()) |b| {
            const status_str = batteryStatusLabel(b);
            const value = try std.fmt.allocPrint(arena, "{d}% \u{00b7} {s}", .{ b.capacity, status_str });
            try rows.append(arena, try buildPanelMetric(ui, state, b.nameSlice(), value));

            if (b.secondsToFull()) |secs| {
                try rows.append(arena, try buildPanelSubMetric(ui, state, "  to full", formatDuration(arena, secs)));
            } else if (b.secondsToEmpty()) |secs| {
                try rows.append(arena, try buildPanelSubMetric(ui, state, "  remaining", formatDuration(arena, secs)));
            }
        }
    }

    return try ux.div(.{
        .style = tw.style(.{ tw.flex_col, tw.gap_px(6), tw.w(panel_w - 32) }),
        .children = rows.items,
    });
}

fn batteryStatusLabel(b: battery.Battery) []const u8 {
    return switch (b.status) {
        .charging => "Charging",
        .discharging => "Discharging",
        .not_charging => "Not charging",
        .full => "Full",
        .unknown => "Unknown",
    };
}

fn formatDuration(arena: std.mem.Allocator, seconds: u32) []const u8 {
    const hours = seconds / 3600;
    const minutes = (seconds % 3600) / 60;
    if (hours > 0) {
        return std.fmt.allocPrint(arena, "{d}h {d:0>2}m", .{ hours, minutes }) catch "?";
    }
    return std.fmt.allocPrint(arena, "{d}m", .{minutes}) catch "?";
}

fn buildPanelSubMetric(ui: *T.UIContext, state: *const AppState, label: []const u8, value: []const u8) !*T.Node {
    const ux = ui.ux();
    return try ux.div(.{
        .style = tw.style(.{ tw.flex_row, tw.items_center, tw.justify_between, tw.gap_px(12), tw.w_full, tw.p_xy_px(12, 2) }),
        .children = &.{
            try ux.text(.{ .content = label, .font = state.font, .style = tw.style(.{ tw.text(font_size - 3), tw.text_color_value(dim) }) }),
            try ux.text(.{ .content = value, .font = state.font, .style = tw.style(.{ tw.text(font_size - 3), tw.text_color_value(dim) }) }),
        },
    });
}

fn buildPanelTrayRow(ui: *T.UIContext, state: *const AppState, item: tray_mod.Item) !*T.Node {
    const ux = ui.ux();
    return try ux.div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.gap_px(10),
            tw.p_xy_px(12, 8),
            tw.bg_value(pill_bg),
            tw.hover_value(ws_hover),
            tw.rounded(12),
            tw.cursor_pointer,
            tw.transition(hover_transition),
        }),
        .on_click = .{ .tray_menu = item.id },
        .on_context_menu = .{ .tray_menu = item.id },
        .children = &.{
            try ux.image(.{ .tex_id = trayTexture(state, item), .tint = fg, .style = tw.style(.{tw.square(tray_icon_px)}) }),
            try ux.div(.{
                .style = tw.style(.{ tw.flex_col, tw.gap_px(2) }),
                .children = &.{
                    try ux.text(.{ .content = item.title(), .font = state.font, .style = tw.style(.{ tw.text(font_size - 1), tw.text_color_value(fg) }) }),
                    try ux.text(.{ .content = item.status(), .font = state.font, .style = tw.style(.{ tw.text(font_size - 3), tw.text_color_value(dim) }) }),
                },
            }),
        },
    });
}

fn trayTexture(state: *const AppState, item: tray_mod.Item) u32 {
    if (item.real and item.tex_id != 0) return item.tex_id;
    return switch (item.icon) {
        .network => state.tex_tray_network,
        .messages => state.tex_tray_messages,
        .updates => state.tex_tray_updates,
        .app => state.tex_tray_messages,
    };
}

fn formatClock(arena: std.mem.Allocator, time: clock_mod.State, clock_24h: bool) ![]const u8 {
    if (clock_24h) {
        return std.fmt.allocPrint(arena, "{s} {d:0>2} {s}  {d:0>2}:{d:0>2}", .{
            time.weekday, time.day, monthName(time.month), time.hour, time.minute,
        });
    }
    const h = time.hour % 12;
    const h12: u8 = if (h == 0) 12 else h;
    const period = if (time.hour < 12) "AM" else "PM";
    return std.fmt.allocPrint(arena, "{s} {d:0>2} {s}  {d}:{d:0>2} {s}", .{
        time.weekday, time.day, monthName(time.month), h12, time.minute, period,
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
            for (app.state.hypr.workspaces[0..app.state.hypr.workspace_count]) |*ws| {
                ws.active = (ws.id == ws_id);
            }
            app.state.hypr.active_workspace_id = ws_id;
            var buf: [64]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "dispatch workspace {d}", .{ws_id}) catch return .rebuild;
            hyprland.dispatch(app.state.io, app.state.env, cmd);
            return .rebuild;
        },
        .edge_hover => |v| {
            app.state.edge_hovered = v;
            if (v) {
                app.state.hide_panel_at_ns = 0;
                if (!app.state.slide_panel_open) {
                    app.state.slide_panel_open = true;
                    return .rebuild;
                }
            }
            return .none;
        },
        .panel_hover => |v| {
            app.state.panel_hovered = v;
            if (v) app.state.hide_panel_at_ns = 0;
            return .none;
        },
        .panel_force_close => {
            app.state.slide_panel_open = false;
            app.state.edge_hovered = false;
            app.state.panel_hovered = false;
            app.state.hide_panel_at_ns = 0;
            return .rebuild;
        },
        .tray_menu => |item_id| {
            if (item_id) |id| {
                if (app.state.open_tray_menu != null and app.state.open_tray_menu.? == id) {
                    app.state.open_tray_menu = null;
                } else {
                    app.state.open_tray_menu = id;
                }
            } else {
                app.state.open_tray_menu = null;
            }
            app.state.tray_menu_hovered = false;
            app.state.hide_tray_menu_at_ns = 0;
            return .rebuild;
        },
        .tray_menu_hover => |v| {
            app.state.tray_menu_hovered = v;
            if (v) {
                app.state.hide_tray_menu_at_ns = 0;
            } else if (app.state.open_tray_menu != null) {
                const now_ns: i128 = std.Io.Clock.real.now(app.state.io).nanoseconds;
                app.state.hide_tray_menu_at_ns = now_ns + tray_menu_hide_delay_ns;
            }
            return .none;
        },
        .tray_action => |action| {
            app.state.tray.applyAction(action);
            app.state.open_tray_menu = null;
            app.state.tray_menu_hovered = false;
            app.state.hide_tray_menu_at_ns = 0;
            return .rebuild;
        },
        .toggle_power_menu => {
            app.state.power_menu_open = !app.state.power_menu_open;
            app.state.power_revealed = false;
            app.state.power_confirm = null;
            return .rebuild;
        },
        .close_power_menu => {
            app.state.power_menu_open = false;
            app.state.power_revealed = false;
            app.state.power_confirm = null;
            return .rebuild;
        },
        .power_action => |action| {
            if (action.needsConfirm() and (app.state.power_confirm == null or app.state.power_confirm.? != action)) {
                // First click on a destructive action arms the confirm state.
                app.state.power_confirm = action;
                return .rebuild;
            }
            power_mod.run(app.state.io, action);
            app.state.power_menu_open = false;
            app.state.power_confirm = null;
            return .rebuild;
        },
        .toggle_settings_menu => {
            app.state.settings_menu_open = !app.state.settings_menu_open;
            app.state.settings_revealed = false;
            return .rebuild;
        },
        .close_settings_menu => {
            app.state.settings_menu_open = false;
            app.state.settings_revealed = false;
            return .rebuild;
        },
        .toggle_setting => |key| {
            settings_mod.toggle(&app.state.settings, key);
            applyTheme(app);
            settingsSave(app, app.state.io);
            return .rebuild;
        },
        .cycle_accent => {
            settings_mod.cycleAccent(&app.state.settings);
            applyTheme(app);
            settingsSave(app, app.state.io);
            return .rebuild;
        },
        .cycle_rounding => {
            settings_mod.cycleRounding(&app.state.settings);
            applyTheme(app);
            settingsSave(app, app.state.io);
            return .rebuild;
        },
        .noop => return .none,
    }
}

var hypr_state: hyprland.State = .{};
var hypr_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var bg_bat: battery.State = .{};
var bg_vol: audio_mod.State = .{};
var bg_time: clock_mod.State = .{};
var bg_net: network_mod.State = .{};
var bg_slow_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var net_poll_counter: u8 = 0;

fn hyprlandWorker(io: std.Io, env: *std.process.Environ.Map) void {
    hyprland.eventLoop(io, env, &hypr_state, &hypr_ready);
}

fn slowPollWorker(io: std.Io) void {
    while (true) {
        bg_bat = battery.poll();
        bg_vol = audio_mod.poll(io);
        bg_time = clock_mod.poll(io);
        // Network polling is heavier (spawns nmcli) — refresh every ~5s.
        if (net_poll_counter == 0) {
            bg_net = network_mod.poll(io);
        }
        net_poll_counter = (net_poll_counter + 1) % 5;
        bg_slow_ready.store(true, .release);
        var ts = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

fn tick(app: *App) ramiel.UpdateAction {
    var changed = false;

    if (hypr_ready.swap(false, .acquire)) {
        app.state.hypr = hypr_state;
        changed = true;
    }

    if (bg_slow_ready.swap(false, .acquire)) {
        app.state.bat = bg_bat;
        // Keep the last good volume on a transient wpctl failure (avoids "--" blips).
        if (bg_vol.available or !app.state.vol.available) {
            app.state.vol = bg_vol;
        }
        app.state.time = bg_time;
        app.state.net = bg_net;
        changed = true;
    }

    // One frame after open, reveal so the entrance has a change to animate.
    if (app.state.power_menu_open and !app.state.power_revealed) {
        app.state.power_revealed = true;
        changed = true;
    }
    if (app.state.settings_menu_open and !app.state.settings_revealed) {
        app.state.settings_revealed = true;
        changed = true;
    }

    if (tray_mod.poll()) |tray_state| {
        mergeTrayState(app, tray_state);
        uploadTrayPixmaps(app);
        changed = true;
    }

    const cursor = app.getCursorPos();
    const off_surface = cursor.x < 0 or cursor.y < 0;
    if (off_surface) {
        app.state.edge_hovered = false;
        app.state.panel_hovered = false;
    }

    if (app.state.open_tray_menu != null and !app.state.tray_menu_hovered and app.state.hide_tray_menu_at_ns != 0) {
        const now_ns: i128 = std.Io.Clock.real.now(app.state.io).nanoseconds;
        if (now_ns >= app.state.hide_tray_menu_at_ns) {
            app.state.open_tray_menu = null;
            app.state.hide_tray_menu_at_ns = 0;
            changed = true;
        }
    }

    if (app.state.slide_panel_open) {
        if (app.state.edge_hovered or app.state.panel_hovered) {
            app.state.hide_panel_at_ns = 0;
        } else {
            const now_ns: i128 = std.Io.Clock.real.now(app.state.io).nanoseconds;
            if (app.state.hide_panel_at_ns == 0) {
                app.state.hide_panel_at_ns = now_ns + panel_hide_delay_ns;
            } else if (now_ns >= app.state.hide_panel_at_ns) {
                app.state.slide_panel_open = false;
                app.state.hide_panel_at_ns = 0;
                changed = true;
            }
        }
    } else {
        app.state.hide_panel_at_ns = 0;
    }

    return if (changed) .rebuild else .none;
}

fn mergeTrayState(app: *App, next: tray_mod.State) void {
    var merged = next;
    for (merged.items[0..merged.item_count]) |*new_item| {
        if (!new_item.real) continue;
        for (app.state.tray.items[0..app.state.tray.item_count]) |old_item| {
            if (!old_item.real) continue;
            if (!std.mem.eql(u8, new_item.service(), old_item.service())) continue;
            if (!std.mem.eql(u8, new_item.path(), old_item.path())) continue;
            new_item.icon_id = old_item.icon_id;
            new_item.tex_id = old_item.tex_id;
            new_item.tex_serial = old_item.tex_serial;
            break;
        }
    }
    app.state.tray = merged;
}

fn uploadTrayPixmaps(app: *App) void {
    var buf: [96 * 96 * 4]u8 = undefined;
    for (app.state.tray.items[0..app.state.tray.item_count]) |*item| {
        if (!item.real) continue;
        if (item.pixmap_serial == 0) continue;
        if (item.tex_id != 0 and item.tex_serial == item.pixmap_serial) continue;

        const info = tray_mod.fetchPixmap(item.id, &buf) orelse continue;
        const byte_len = info.width * info.height * 4;
        if (byte_len > buf.len) continue;

        const new_tex = app.engine.resources.texture_registry.uploadManagedRgba(
            &app.engine.core,
            buf[0..byte_len],
            info.width,
            info.height,
        ) catch continue;

        if (item.tex_id != 0) {
            app.engine.resources.texture_registry.freeManagedTexture(&app.engine.core, item.tex_id);
        }
        item.tex_id = new_tex;
        item.tex_serial = info.serial;
    }
}

fn captureFirstLine(io: std.Io, argv: []const []const u8, buf: []u8) ?[]const u8 {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var mutable_child = child;

    var read_buf: [1024]u8 = undefined;
    var reader = mutable_child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(std.heap.page_allocator, .limited(buf.len)) catch {
        _ = mutable_child.wait(io) catch {};
        return null;
    };
    defer std.heap.page_allocator.free(out);
    _ = mutable_child.wait(io) catch {};

    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    @memcpy(buf[0..trimmed.len], trimmed);
    return buf[0..trimmed.len];
}

/// Register a color emoji font as the default fallback so emoji/symbols in
/// window titles and other text resolve to it. Best-effort.
fn loadEmojiFallback(app: *App, io: std.Io) void {
    var out_buf: [1024]u8 = undefined;
    const path = captureFirstLine(io, &.{ "fc-match", "-f", "%{file}", "Noto Color Emoji" }, &out_buf) orelse return;
    if (path.len >= 1023) return;

    var path_buf: [1024]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path.len :0];

    _ = app.loadFont("emoji", .{ .path = path_z }, 109) catch return;
    app.setDefaultFallbackChain(&.{"emoji"}) catch {};
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
            .exclusive_zone = 40,
            .keyboard_interactivity = .none,
            .namespace = "ramiel-bar",
        } },
        .transparent = true,
        .input_region = .auto_interactive,
        .width = 0,
        // 0 = fill the output height (backend queries wl_output); the bar stays
        // anchored to the top and reserves its strip via exclusive_zone.
        .height = 0,
    }, .{ .io = io, .env = init.environ_map }, update);
    defer app.deinit();

    app.state.font = try app.loadDefaultFont(
        "JetBrains Mono",
        .{ .memory = ramiel.assets.getFontData(.jetbrains_mono) },
        16,
    );
    loadEmojiFallback(&app, io);

    try app.loadIconSvgFromMemory(ICON_VOL_HIGH, icons.volume_high, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_VOL_MUTE, icons.volume_mute, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_VOL_LOW, icons.volume_low, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_FULL, icons.battery_full, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_CHARGE, icons.battery_charging, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_LOW, icons.battery_low, icon_px, icon_px, 1.0);

    // Power menu + panel accent icons (rendered larger, so rasterize at 24px).
    try app.loadIconSvgFromMemory(ICON_PWR_LOCK, icons.power_lock, 24, 24, 1.0);
    try app.loadIconSvgFromMemory(ICON_PWR_SUSPEND, icons.power_suspend, 24, 24, 1.0);
    try app.loadIconSvgFromMemory(ICON_PWR_LOGOUT, icons.power_logout, 24, 24, 1.0);
    try app.loadIconSvgFromMemory(ICON_PWR_REBOOT, icons.power_reboot, 24, 24, 1.0);
    try app.loadIconSvgFromMemory(ICON_PWR_SHUTDOWN, icons.power_shutdown, 24, 24, 1.0);
    try app.loadIconSvgFromMemory(ICON_WIFI, icons.net_wifi, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_TUNE, icons.panel_tune, icon_px, icon_px, 1.0);

    app.state.tex_vol_high = app.getIconTextureId(ICON_VOL_HIGH, 1.0) orelse 0;
    app.state.tex_vol_mute = app.getIconTextureId(ICON_VOL_MUTE, 1.0) orelse 0;
    app.state.tex_vol_low = app.getIconTextureId(ICON_VOL_LOW, 1.0) orelse 0;
    app.state.tex_bat_full = app.getIconTextureId(ICON_BAT_FULL, 1.0) orelse 0;
    app.state.tex_bat_charge = app.getIconTextureId(ICON_BAT_CHARGE, 1.0) orelse 0;
    app.state.tex_bat_low = app.getIconTextureId(ICON_BAT_LOW, 1.0) orelse 0;
    app.state.tex_pwr_lock = app.getIconTextureId(ICON_PWR_LOCK, 1.0) orelse 0;
    app.state.tex_pwr_suspend = app.getIconTextureId(ICON_PWR_SUSPEND, 1.0) orelse 0;
    app.state.tex_pwr_logout = app.getIconTextureId(ICON_PWR_LOGOUT, 1.0) orelse 0;
    app.state.tex_pwr_reboot = app.getIconTextureId(ICON_PWR_REBOOT, 1.0) orelse 0;
    app.state.tex_pwr_shutdown = app.getIconTextureId(ICON_PWR_SHUTDOWN, 1.0) orelse 0;
    app.state.tex_wifi = app.getIconTextureId(ICON_WIFI, 1.0) orelse 0;
    app.state.tex_tune = app.getIconTextureId(ICON_TUNE, 1.0) orelse 0;

    app.setTickFn(tick, 0.05);
    tray_mod.start();

    app.state.bat = battery.poll();
    app.state.vol = audio_mod.poll(io);
    app.state.hypr = hyprland.poll(io, init.environ_map);
    app.state.time = clock_mod.poll(io);
    app.state.net = network_mod.poll(io);
    app.state.tray = tray_mod.demoState();
    settingsLoad(&app, io);
    applyTheme(&app);

    const hypr_thread = try std.Thread.spawn(.{}, hyprlandWorker, .{ io, init.environ_map });
    hypr_thread.detach();

    const slow_thread = try std.Thread.spawn(.{}, slowPollWorker, .{io});
    slow_thread.detach();

    try app.setRootBuilder(build);
    try app.run();
}
