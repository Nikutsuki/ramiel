const std = @import("std");
const core = @import("../core.zig");

const sidebar = @import("sidebar.zig");
const top_bar = @import("top_bar.zig");
const file_grid = @import("file_grid.zig");

pub fn build(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const tokens = ui.active_theme.tokens;

    const sidebar_node = try sidebar.build(ui, state);
    const top_bar_node = try top_bar.build(ui, state);
    const file_grid_node = try file_grid.build(ui, state);

    const content = try ui.div(.{
        .style = .{
            .width = .Full,
            .height = .Full,
            .background_color = tokens.bg_base,
            .flex_grow = 1.0,
            .direction = .Row,
        },
        .children = &.{ sidebar_node, file_grid_node },
    });

    return try ui.div(.{
        .style = .{
            .width = .Full,
            .height = .Full,
            .background_color = tokens.bg_base,
        },
        .children = &.{ top_bar_node, content },
    });
}
