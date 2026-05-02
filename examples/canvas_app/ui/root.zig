const std = @import("std");
const core = @import("../core.zig");

const top_bar = @import("top_bar.zig");
const workspace = @import("workspace.zig");
const param_panel = @import("param_panel.zig");
const overlays = @import("overlays.zig");

pub fn build(
    ui: *core.AppUIContext,
    state: *const core.AppState,
) anyerror!*core.AppNode {
    const allocator = ui.gpa;
    const font = state.font_data;
    const tokens = ui.active_theme.tokens;

    var root_children = std.ArrayList(*core.AppNode).empty;
    defer root_children.deinit(allocator);

    try root_children.append(allocator, try top_bar.build(allocator, ui, state, font));
    try root_children.append(allocator, try ui.div(.{
        .style = .{
            .direction = .Row,
            .width = .Full,
            .height = .Full,
            .flex_grow = 1,
            .gap = 8,
        },
        .children = &.{
            try workspace.buildLeftCanvas(ui, state),
            try workspace.buildRightCanvas(ui, state),
            try param_panel.build(allocator, ui, state, font),
        },
    }));

    if (state.editor.palette_open) {
        try root_children.append(allocator, try overlays.buildPalette(allocator, ui, state, font));
    }
    if (state.editor.show_help) {
        try root_children.append(allocator, try overlays.buildHelp(ui, font));
    }

    return try ui.div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .direction = .Column,
            .align_items = .Stretch,
            .background_color = tokens.bg_base,
        },
        .children = root_children.items,
    });
}
