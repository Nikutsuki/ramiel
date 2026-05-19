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
const icons = @import("icons.zig");

const NodeIds = ramiel.declareIds("wayland-basic", .{
    "bar_row",
    "hot_corner",
    "slide_panel",
    "tray_menu",
}){};

const AppMessage = union(enum) {
    switch_workspace: i32,
    edge_hover: bool,
    panel_hover: bool,
    panel_force_close: void,
    tray_menu: ?usize,
    tray_menu_hover: bool,
    tray_action: tray_mod.MenuAction,
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

const AppState = struct {
    font: *ramiel.FontData = undefined,
    bat: battery.State = .{},
    vol: audio_mod.State = .{},
    hypr: hyprland.State = .{},
    time: clock_mod.State = .{},
    tray: tray_mod.State = tray_mod.demoState(),
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
};

const transparent = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
const pill_bg = [4]f32{ 0.10, 0.10, 0.16, 0.92 };
const pill_border = [4]f32{ 1.0, 0.2, 0.6, 1.0 };
const panel_bg = [4]f32{ 0.08, 0.09, 0.14, 0.96 };
const menu_bg = [4]f32{ 0.08, 0.09, 0.14, 0.98 };
const fg = [4]f32{ 0.88, 0.90, 0.96, 1.0 };
const dim = [4]f32{ 0.52, 0.55, 0.66, 1.0 };
const accent = [4]f32{ 0.45, 0.65, 1.0, 1.0 };
const ws_active_bg = [4]f32{ 0.25, 0.32, 0.50, 1.0 };
const ws_hover = [4]f32{ 0.18, 0.20, 0.30, 0.9 };
const sep_color = [4]f32{ 0.25, 0.27, 0.35, 1.0 };
const danger = [4]f32{ 1.0, 0.40, 0.40, 1.0 };

const font_size = 15.0;
const icon_px = 20;
const tray_icon_px = 20;
const tray_icon_box = 24;
const pill_radius = 14.0;
const bar_h = 36.0;
const hover_transition = layout.TransitionStyle.forColors(150);
const panel_transition = layout.TransitionStyle.forTransform(220);
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
                .children = &.{try ux.text(.{
                    .content = label,
                    .font = font,
                    .style = tw.style(.{ tw.text(font_size), tw.text_color_value(text_color) }),
                })},
            }));
        }
    }

    const title = if (state.hypr.title_len > 0) state.hypr.activeTitle() else "";
    if (title.len > 0) {
        try appendSeparator(ui, &left_items, arena, font, 8);
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
            tw.border_value(2.0, pill_border),
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
            tw.border_value(2.0, pill_border),
        }),
        .children = &.{try ux.text(.{
            .content = try std.fmt.allocPrint(arena, "{s} {d:0>2} {s}  {d:0>2}:{d:0>2}", .{
                state.time.weekday,
                state.time.day,
                monthName(state.time.month),
                state.time.hour,
                state.time.minute,
            }),
            .font = font,
            .style = tw.style(.{ tw.text(font_size), tw.text_color_value(fg) }),
        })},
    });

    var right_items: std.ArrayList(?*T.Node) = .empty;
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

    if (state.bat.present) {
        try appendSeparator(ui, &right_items, arena, font, 6);
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

    if (state.tray.available and state.tray.item_count > 0) {
        try appendSeparator(ui, &right_items, arena, font, 6);
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
            tw.border_value(2.0, pill_border),
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

fn buildSlidePanel(ui: *T.UIContext, state: *const AppState) !*T.Node {
    const ux = ui.ux();
    const arena = ui.build_arena.allocator();
    const panel_w: f32 = 330;
    const panel_translate: f32 = if (state.slide_panel_open) 0 else panel_w + 28;
    var rows: std.ArrayList(?*T.Node) = .empty;

    try rows.append(arena, try ux.div(.{
        .style = tw.style(.{ tw.flex_row, tw.items_center, tw.justify_between }),
        .children = &.{
            try ux.text(.{
                .content = "Quick panel",
                .font = state.font,
                .style = tw.style(.{ tw.text(18), tw.text_color_value(fg) }),
            }),
            try ux.div(.{
                .style = tw.style(.{
                    tw.p_xy_px(10, 5),
                    tw.bg_value(ws_hover),
                    tw.hover_value(ws_active_bg),
                    tw.rounded(10),
                    tw.cursor_pointer,
                    tw.transition(hover_transition),
                }),
                .on_click = .panel_force_close,
                .children = &.{try ux.text(.{
                    .content = "Close",
                    .font = state.font,
                    .style = tw.style(.{ tw.text(font_size - 2), tw.text_color_value(fg) }),
                })},
            }),
        },
    }));

    try rows.append(arena, try ux.text(.{
        .content = "Move the cursor to the right edge of the screen to reveal this surface. Only the bar, hot edge, menu, and panel are in the Wayland input region.",
        .font = state.font,
        .max_width = panel_w - 32,
        .style = tw.style(.{ tw.text(font_size - 2), tw.text_color_value(dim) }),
    }));

    try rows.append(arena, try buildPanelMetric(ui, state, "Volume", if (state.vol.available) try std.fmt.allocPrint(arena, "{d}%", .{state.vol.volume_pct}) else "--"));
    try rows.append(arena, try buildPanelMetric(ui, state, "Battery", if (state.bat.present) try std.fmt.allocPrint(arena, "{d}%", .{state.bat.capacity}) else "No battery"));
    try rows.append(arena, try buildPanelMetric(ui, state, "Workspace", if (state.hypr.available) try std.fmt.allocPrint(arena, "{d}", .{state.hypr.active_workspace_id}) else "Unavailable"));

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
    }
}

var hypr_state: hyprland.State = .{};
var hypr_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

    if (hypr_ready.swap(false, .acquire)) {
        app.state.hypr = hypr_state;
        changed = true;
    }

    if (bg_slow_ready.swap(false, .acquire)) {
        app.state.bat = bg_bat;
        app.state.vol = bg_vol;
        app.state.time = bg_time;
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
        .height = 2160,
    }, .{ .io = io, .env = init.environ_map }, update);
    defer app.deinit();

    app.state.font = try app.loadDefaultFont(
        "JetBrains Mono",
        .{ .memory = ramiel.assets.getFontData(.jetbrains_mono) },
        16,
    );

    try app.loadIconSvgFromMemory(ICON_VOL_HIGH, icons.volume_high, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_VOL_MUTE, icons.volume_mute, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_VOL_LOW, icons.volume_low, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_FULL, icons.battery_full, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_CHARGE, icons.battery_charging, icon_px, icon_px, 1.0);
    try app.loadIconSvgFromMemory(ICON_BAT_LOW, icons.battery_low, icon_px, icon_px, 1.0);

    app.state.tex_vol_high = app.getIconTextureId(ICON_VOL_HIGH, 1.0) orelse 0;
    app.state.tex_vol_mute = app.getIconTextureId(ICON_VOL_MUTE, 1.0) orelse 0;
    app.state.tex_vol_low = app.getIconTextureId(ICON_VOL_LOW, 1.0) orelse 0;
    app.state.tex_bat_full = app.getIconTextureId(ICON_BAT_FULL, 1.0) orelse 0;
    app.state.tex_bat_charge = app.getIconTextureId(ICON_BAT_CHARGE, 1.0) orelse 0;
    app.state.tex_bat_low = app.getIconTextureId(ICON_BAT_LOW, 1.0) orelse 0;

    app.setTickFn(tick, 0.05);
    tray_mod.start();

    app.state.bat = battery.poll();
    app.state.vol = audio_mod.poll(io);
    app.state.hypr = hyprland.poll(io, init.environ_map);
    app.state.time = clock_mod.poll(io);
    app.state.tray = tray_mod.demoState();

    const hypr_thread = try std.Thread.spawn(.{}, hyprlandWorker, .{ io, init.environ_map });
    hypr_thread.detach();

    const slow_thread = try std.Thread.spawn(.{}, slowPollWorker, .{io});
    slow_thread.detach();

    try app.setRootBuilder(build);
    try app.run();
}
