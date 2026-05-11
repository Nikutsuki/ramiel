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
    const font = state.runtime.font_data;
    const ux = ui.ux();
    const tw = core.tw;

    var root_children = try ux.keyed(core.NodeIds.root_children, 4);

    try root_children.append("top_bar", try top_bar.build(allocator, ui, state, font));
    try root_children.append("workspace", try ux.div(.{
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
        try root_children.append("palette", try overlays.buildPalette(allocator, ui, state, font));
    }
    if (state.editor.show_help) {
        try root_children.append("help", try overlays.buildHelp(ui, font));
    }

    return try ux.div(.{
        .class = .{
            tw.size_screen,
            tw.flex_col,
            tw.items_stretch,
            tw.bg_base,
        },
        .children = root_children.slice(),
    });
}
