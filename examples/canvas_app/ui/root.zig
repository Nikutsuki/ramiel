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
    const ux = core.uix.builder(core.AppMessage, ui);
    const tw = core.tw;

    var root_children = try ux.keyedList(4);

    try root_children.append(root_children.keyAt(0, core.NodeIds.root_children, "top_bar"), try top_bar.build(allocator, ui, state, font));
    try root_children.append(root_children.keyAt(1, core.NodeIds.root_children, "workspace"), try ux.div(.{
        .class = .{
            tw.flex_row,
            tw.w_full,
            tw.h_full,
            tw.grow_1,
            tw.gap(2),
        },
        .children = .{
            try workspace.buildLeftCanvas(ui, state),
            try workspace.buildRightCanvas(ui, state),
            try param_panel.build(allocator, ui, state, font),
        },
    }));

    if (state.editor.palette_open) {
        try root_children.append(root_children.keyAt(root_children.len, core.NodeIds.root_children, "palette"), try overlays.buildPalette(allocator, ui, state, font));
    }
    if (state.editor.show_help) {
        try root_children.append(root_children.keyAt(root_children.len, core.NodeIds.root_children, "help"), try overlays.buildHelp(ui, font));
    }

    return try ux.div(.{
        .class = .{
            tw.size_screen,
            tw.flex_col,
            tw.items_stretch,
            tw.bg(tokens.bg_base),
        },
        .children = root_children.slice(),
    });
}
