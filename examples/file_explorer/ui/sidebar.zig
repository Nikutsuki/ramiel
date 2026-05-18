const std = @import("std");
const core = @import("../core.zig");
const tw = core.tw;
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
            .style = tw.style(.{ tw.size_full, tw.overflow_scroll }),
            // p_each_px to preserve the multi-side intent that tw padding partials clobber.
            .row_style = tw.style(.{ tw.p_each_px(6.0, 10.0, 6.0, 8.0), tw.rounded(5.0) }),
            .indent_px = 20.0,
            .expander_size = 22.0,
            .active_row_color = tokens.action_pressed,
            .hover_row_color = tokens.action_hover,
        },
    });

    tree_node.scroll_x = state.sidebar_scroll_x;
    tree_node.scroll_y = state.sidebar_scroll_y;

    return try ui.ux().div(.{
        .style = tw.style(.{
            tw.w(240.0),
            tw.h_full,
            tw.bg_value(tokens.bg_surface),
            tw.border_r_value(1.0, tokens.border_subtle),
            tw.py(1), // 4px top + bottom (unit=4)
        }),
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
            .style = tw.style(.{tw.text_color_value(.{ 1.0, 0.0, 0.0, 1.0 })}), // Visually flag structural desyncs
        });
    };

    const tokens = ctx.active_theme.tokens;
    return ctx.ux().text(.{
        .id = null,
        .content = node.name,
        .font = state.font_data,
        .style = tw.style(.{
            tw.pointer_events_none,
            tw.text(14.0),
            tw.text_color_value(if (item.is_selected) tokens.text_inverse else tokens.text_main),
        }),
    });
}
