const std = @import("std");
const core = @import("../core.zig");

fn guildInitial(name: []const u8) []const u8 {
    return name[0..@min(name.len, 1)];
}

fn guildButton(
    ui: *core.AppUIContext,
    font: *core.FontData,
    index: ?usize,
    key: []const u8,
    selected: bool,
    label: []const u8,
    icon_url: ?[]const u8,
) !*core.AppNode {
    const ux = ui.ux();
    const tw = core.tw;
    const tokens = ui.active_theme.tokens;
    const accent = tokens.action_default;
    const idle_bg: [4]f32 = .{ 0.19, 0.20, 0.23, 1.0 };
    const active_bg = if (selected) accent else idle_bg;
    const radius: f32 = if (selected) 16.0 else 24.0;

    const indicator = try ux.div(.{
        .class = .{
            tw.w(if (selected) 4.0 else 0.0),
            tw.h(if (selected) 38.0 else 0.0),
            tw.rounded(999.0),
            tw.bg("#ffffffeb"),
        },
    });

    const content = if (icon_url) |url|
        try ui.ux().asyncImage(.{
            .source = url,
            .style = tw.style(.{
                tw.size_full,
                tw.rounded(radius),
                tw.object_cover,
            }),
            .alt_text = label,
            .alt_font = font,
        })
    else
        try ux.text(.{
            .content = guildInitial(label),
            .font = font,
            .class = .{
                tw.text_color("#f2f5ffff"),
                tw.text(17),
                tw.pointer_events_none,
            },
        });

    const msg: core.AppMsg = if (index) |i| .{ .guild_click = i } else .{ .open_dms = {} };

    return try ux.div(.{
        .id = core.components.deriveChildId(core.NodeIds.guild_virtual_list, key),
        .class = .{
            tw.w_full,
            tw.h(52.0),
            tw.flex_row,
            tw.items_center,
            tw.gap_px(8.0),
            tw.cursor_pointer,
        },
        .on_click = msg,
        .on_hover_enter = if (index) |i| core.AppMsg{ .guild_hover_enter = i } else core.AppMsg{ .server_bar_hover_enter = {} },
        .on_hover_exit = if (index) |i| core.AppMsg{ .guild_hover_exit = i } else core.AppMsg{ .server_bar_hover_exit = {} },
        .children = .{
            indicator,
            try ux.div(.{
                .class = .{
                    tw.w(48.0),
                    tw.h(48.0),
                    tw.flex_row,
                    tw.items_center,
                    tw.justify_center,
                    tw.bg_value(active_bg),
                    tw.rounded(radius),
                    tw.overflow_hidden,
                    tw.hover_value(if (selected) accent else tokens.action_hover),
                    tw.transition_colors(120),
                },
                .children = .{content},
            }),
        },
    });
}

pub fn build(allocator: std.mem.Allocator, ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    _ = allocator;
    const ux = ui.ux();
    const tw = core.tw;
    const font = state.font_data;

    var children = try ux.keyed(core.NodeIds.guild_virtual_list, state.guilds.items.len + 3);
    try children.append("home", try guildButton(ui, font, null, "home", state.selected_guild_id == null, "DM", null));

    try children.append("divider", try ux.div(.{
        .class = .{
            tw.w(32.0),
            tw.h(2.0),
            tw.self_center,
            tw.my(1),
            tw.rounded(999.0),
            tw.bg_token(.border_subtle),
        },
    }));

    for (state.guilds.items, 0..) |guild, index| {
        try children.append(guild.id, try guildButton(
            ui,
            font,
            index,
            guild.id,
            core.isGuildSelected(state, guild.id),
            guild.name,
            guild.icon_url,
        ));
    }

    return try ux.div(.{
        .id = core.NodeIds.guild_bar_shell,
        .class = .{
            tw.w(72.0),
            tw.h_full,
            tw.flex_col,
            tw.items_center,
            tw.py(3),
            tw.bg("#14171cff"),
            tw.border_r(1.0,  "#050508ff"),
            tw.overflow_y_scroll,
        },
        .children = children.slice(),
    });
}
