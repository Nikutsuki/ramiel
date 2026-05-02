const std = @import("std");
const core = @import("../core.zig");

const GuildBuildCtx = struct {
    allocator: std.mem.Allocator,
    state: *const core.AppState,
};

fn onGuildNeedData(start: usize, end: usize) core.AppMsg {
    return .{ .virtual_list_need_data = .{ .target = .guilds, .start = start, .end = end } };
}

fn onGuildScroll(delta: f32) core.AppMsg {
    return .{ .virtual_list_scroll = .{ .target = .guilds, .delta = delta } };
}

fn buildGuildVirtualItem(ui: *core.AppUIContext, index: usize, userdata: ?*const anyopaque) anyerror!*core.AppNode {
    const payload: *const GuildBuildCtx = @ptrCast(@alignCast(userdata.?));
    if (index >= payload.state.guilds.items.len) return error.IndexOutOfBounds;
    const guild = payload.state.guilds.items[index];
    const is_selected = core.isGuildSelected(payload.state, guild.id);
    const tokens = ui.active_theme.tokens;

    var node_children = std.ArrayList(*core.AppNode).empty;
    defer node_children.deinit(payload.allocator);

    if (guild.icon_url) |url| {
        try node_children.append(
            payload.allocator,
            try ui.asyncImage(
                .{ .source = url, .style = .{
                    .width = .Full,
                    .height = .Full,
                    .corner_radius = .all(4),
                } },
            ),
        );
    }

    return ui.div(.{
        .style = .{
            .width = .{ .exact = 40 },
            .height = .{ .exact = 40 },
            .background_color = if (is_selected) tokens.action_default else tokens.bg_surface,
            .corner_radius = .all(8),
            .overflow_x = .hidden,
            .overflow_y = .hidden,
            .cursor = .pointer,
        },
        .children = node_children.items,
        .events = &.{
            .{ .event = .click, .msg = .{ .guild_click = index } },
            .{ .event = .hover_enter, .msg = .{ .guild_hover_enter = index } },
            .{ .event = .hover_exit, .msg = .{ .guild_hover_exit = index } },
        },
    });
}

pub fn build(allocator: std.mem.Allocator, ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const bar_height: f32 = 60.0;
    const handle_height: f32 = 14.0;
    const hidden_offset = -(bar_height - handle_height);
    const bar_expanded = state.server_bar_hovered or state.hovered_guild_index != null or state.guilds_list.is_scrolling;

    var guild_ctx = GuildBuildCtx{
        .allocator = allocator,
        .state = state,
    };
    const comp = core.components.Builder(core.AppMsg){ .ui = ui };
    const list_state = @constCast(&state.guilds_list);
    list_state.setTotalItems(state.guilds.items.len);

    var scrollbar_color = tokens.text_muted;
    scrollbar_color[3] = 0.65;

    const guild_list_node = try comp.virtualList(.{
        .base_id = core.NodeIds.guild_virtual_list,
        .state = list_state,
        .on_need_data = onGuildNeedData,
        .on_scroll = onGuildScroll,
        .build_item_fn = buildGuildVirtualItem,
        .build_userdata = @ptrCast(&guild_ctx),
        .on_drag_state_change = struct {
            fn cb(is_dragging: bool) core.AppMsg {
                return .{ .virtual_list_drag_state = .{
                    .target = .guilds,
                    .is_dragging = is_dragging,
                } };
            }
        }.cb,
    }, .{
        .style = .{
            .width = .Full,
            .height = .Full,
            .flex_grow = 1,
            .gap = 4,
            .scrollbar_width = 6,
            .scrollbar_min_height = 18,
            .scrollbar_radius = 999,
            .scrollbar_color = scrollbar_color,
        },
    });

    const bar_node = try ui.div(.{
        .id = core.NodeIds.guild_container,
        .style = .{
            .width = .Full,
            .height = .{ .exact = bar_height },
            .direction = .Row,
            .background_color = tokens.bg_surface,
            .padding = .all(4),
            .gap = 4,
        },
        .events = &.{
            .{ .event = .hover_enter, .msg = .{ .server_bar_hover_enter = {} } },
            .{ .event = .hover_exit, .msg = .{ .server_bar_hover_exit = {} } },
        },
        .children = &.{guild_list_node},
    });

    var handle_grip_bg = tokens.text_muted;
    handle_grip_bg[3] = 0.95;

    const handle_grip = try ui.div(.{
        .style = .{
            .width = .{ .exact = 28 },
            .height = .{ .exact = 4 },
            .background_color = handle_grip_bg,
            .corner_radius = .all(999),
            .pointer_events = .none,
        },
    });

    var handle_node_bg = tokens.bg_surface;
    handle_node_bg[3] = 0.96;

    var shadow_color = tokens.bg_base;
    shadow_color[3] = 0.5;

    const handle_node = try ui.div(.{
        .style = .{
            .width = .{ .exact = 88 },
            .height = .{ .exact = handle_height },
            .background_color = handle_node_bg,
            .corner_radius = .all(999),
            .align_items = .Center,
            .justify_content = .Center,
            .shadow_color = shadow_color,
            .shadow_blur = 8,
            .shadow_offset = .{ 0, 1 },
            .margin = .{ .top = 3, .right = 0, .bottom = 0, .left = 0 },
        },
        .events = &.{
            .{ .event = .hover_enter, .msg = .{ .server_bar_hover_enter = {} } },
            .{ .event = .hover_exit, .msg = .{ .server_bar_hover_exit = {} } },
        },
        .children = &.{handle_grip},
    });

    return try ui.div(.{
        .id = core.NodeIds.guild_bar_shell,
        .style = .{
            .position = .absolute,
            .width = .Full,
            .top = 0,
            .left = 0,
            .right = 0,
            .z_index = 120,
            .direction = .Column,
            .align_items = .Center,
            .transform = .{ .translate = .{ 0, if (bar_expanded) 0 else hidden_offset } },
            .transition = .{
                .property = .{ .translate = true },
                .duration_ms = 220,
                .timing = .ease_out,
            },
            .pointer_events = .auto,
        },
        .children = &.{ bar_node, handle_node },
    });
}
