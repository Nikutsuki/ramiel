const std = @import("std");
const core = @import("../core.zig");
const filesystem = @import("../filesystem/root.zig");

pub fn build(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const builder = core.components.Builder(core.AppMessage){ .ui = ui };
    const tokens = ui.active_theme.tokens;

    const tree_node = try builder.treeFromSource(core.FsNode, &state.tree_state, state.root_node.children.items, .{
        .base_id = 100,
        .build_row_content = buildRowContent,
        .wrap_message = struct {
            fn wrap(msg: core.components.TreeMessage([]const u8)) core.AppMessage {
                return .{ .tree_msg = msg };
            }
        }.wrap,
        .userdata = @as(?*const anyopaque, @ptrCast(@constCast(state))),
    }, .{
        .style = .{
            .width = .Full,
            .height = .Full,
            .overflow_x = .scroll,
            .overflow_y = .scroll,
        },
        .row_style = .{
            .padding = .{
                .left = 8.0,
                .right = 10.0,
                .top = 6.0,
                .bottom = 6.0,
            },
            .corner_radius = .all(5.0),
        },
        .indent_px = 20.0,
        .expander_size = 22.0,
        .active_row_color = tokens.action_pressed,
        .hover_row_color = tokens.action_hover,
    });

    tree_node.scroll_x = state.sidebar_scroll_x;
    tree_node.scroll_y = state.sidebar_scroll_y;

    return try ui.div(.{
        .style = .{
            .width = .{ .exact = 240.0 },
            .height = .Full,
            .background_color = tokens.bg_surface,
            .border = .{ .right = .{ .width = 1.0, .color = tokens.border_subtle } },
            .padding = .{ .top = 4.0, .bottom = 4.0 },
        },
        .children = &.{tree_node},
    });
}

fn buildRowContent(ctx: *core.AppUIContext, item: core.components.TreeItem, userdata: ?*const anyopaque) anyerror!*core.AppNode {
    const state: *const core.AppState = @ptrCast(@alignCast(userdata.?));

    const node = filesystem.findFsNode(@constCast(&state.root_node), item.id) orelse {
        return ctx.text(.{
            .id = null,
            .content = "Unknown",
            .font = state.font_data,
            .style = .{ .text_color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Visually flag structural desyncs
        });
    };

    const tokens = ctx.active_theme.tokens;
    return ctx.text(.{
        .id = null,
        .content = node.name,
        .font = state.font_data,
        .style = .{
            .pointer_events = .none,
            .font_size = 14.0,
            .text_color = if (item.is_selected) tokens.text_inverse else tokens.text_main,
        },
    });
}
