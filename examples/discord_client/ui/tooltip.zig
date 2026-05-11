const core = @import("../core.zig");

pub fn build(ui: *core.AppUIContext, state: *const core.AppState, font_data: *core.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const ux = ui.ux();
    const tw = core.tw;
    const target_index = state.last_hovered_index;
    const is_visible = state.hovered_guild_index != null;
    const item_id = if (target_index < state.guilds.items.len)
        core.components.deriveChildId(core.NodeIds.guild_virtual_list, state.guilds.items[target_index].id)
    else
        core.components.deriveChildId(core.NodeIds.guild_virtual_list, "home");
    const tooltip_x = if (ui.getById(item_id)) |item_node|
        item_node.layout_result.x + item_node.layout_result.width + 8.0
    else
        80.0;
    const tooltip_y = if (ui.getById(item_id)) |item_node|
        item_node.layout_result.y + 8.0
    else
        80.0;
    const tooltip_text = if (target_index < state.guilds.items.len) state.guilds.items[target_index].name else "";

    return try ux.div(.{
        .id = core.NodeIds.tooltip,
        .style = core.Style{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .z_index = 100,
            .pointer_events = .none,
            .opacity = @as(f32, if (is_visible) 1.0 else 0.0),
            .transform = .{ .translate = .{ tooltip_x, tooltip_y } },
            .background_color = tokens.bg_surface,
            .padding = .{ .top = 6, .right = 8, .bottom = 6, .left = 8 },
            .corner_radius = core.lib.layout.CornerRadius.all(4),
            .transition = .{
                .property = .{ .opacity = true, .translate = true },
                .duration_ms = 200,
                .timing = .ease_out,
            },
        },
        .children = .{
            try ux.text(.{
                .content = tooltip_text,
                .font = font_data,
                .class = .{ tw.text_main, tw.text(12) },
            }),
        },
    });
}
