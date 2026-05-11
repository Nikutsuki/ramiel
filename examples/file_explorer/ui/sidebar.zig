const std = @import("std");
const core = @import("../core.zig");
const filesystem = @import("../filesystem/root.zig");

pub fn build(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const components = ui.components();
    const tokens = ui.active_theme.tokens;

    const tree_node = try components.treeFromSource(.{
        .state = &state.tree_state,
        .root_items = state.root_node.children.items,
        .logic = core.components.TreeSourceLogic(core.AppMessage){
            .base_id = core.NodeIds.sidebar_tree,
            .build_row_content = buildRowContent,
            .wrap_message = struct {
                fn wrap(msg: core.components.TreeMessage([]const u8)) core.AppMessage {
                    return .{ .tree_msg = msg };
                }
            }.wrap,
            .userdata = @as(?*const anyopaque, @ptrCast(@constCast(state))),
        },
        .visuals = core.components.TreeDescriptor{
            .style = core.tw.style(.{ core.tw.w_full, core.tw.h_full, .{ .overflow_x = .scroll, .overflow_y = .scroll } }),
            .row_style = core.tw.style(.{ core.tw.px(2.5), core.tw.py(1.5), core.tw.pl(2), core.tw.rounded(5.0) }),
            .indent_px = 20.0,
            .expander_size = 22.0,
            .active_row_color = tokens.action_pressed,
            .hover_row_color = tokens.action_hover,
        },
    });

    tree_node.scroll_x = state.sidebar_scroll_x;
    tree_node.scroll_y = state.sidebar_scroll_y;

    return try ui.ux().div(.{
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
        return ctx.ux().text(.{
            .id = null,
            .content = "Unknown",
            .font = state.font_data,
            .style = .{ .text_color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Visually flag structural desyncs
        });
    };

    const tokens = ctx.active_theme.tokens;
    return ctx.ux().text(.{
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
