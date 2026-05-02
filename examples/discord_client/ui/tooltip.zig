const core = @import("../core.zig");

pub fn build(ui: *core.AppUIContext, state: *const core.AppState, font_data: *core.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const target_index = state.last_hovered_index;
    const is_visible = state.hovered_guild_index != null;
    const item_id = core.components.virtualListItemNodeId(core.NodeIds.guild_virtual_list, target_index);
    const fallback_base_x = 4.0 + @as(f32, @floatFromInt(target_index)) * 44.0;
    const tooltip_x = if (ui.getById(item_id)) |item_node|
        item_node.layout_result.x
    else
        fallback_base_x - @as(f32, @floatCast(state.guilds_list.scroll_offset));
    const tooltip_text = if (target_index < state.guilds.items.len) state.guilds.items[target_index].name else "";

    return try ui.div(.{
        .id = core.NodeIds.tooltip,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 80,
            .z_index = 100,
            .pointer_events = .none,
            .opacity = if (is_visible) 1.0 else 0.0,
            .transform = .{ .translate = .{ tooltip_x, 0 } },
            .background_color = tokens.bg_surface,
            .padding = .all(6),
            .corner_radius = .all(4),
            .transition = .{
                .property = .{ .opacity = true, .translate = true },
                .duration_ms = 200,
                .timing = .ease_out,
            },
        },
        .children = &.{
            try ui.text(.{
                .content = tooltip_text,
                .font = font_data,
                .style = .{ .text_color = tokens.text_main },
            }),
        },
    });
}
