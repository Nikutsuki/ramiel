const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const tw = core.tw;

pub fn build(_: std.mem.Allocator, ui: *core.AppUIContext, state: *const core.AppState, font: *lib.FontData) !*core.AppNode {
    const ux = core.uix.builder(core.AppMessage, ui);
    const tokens = ui.active_theme.tokens;
    return ux.div(.{
        .class = .{
            tw.flex_row,
            tw.w_full,
            tw.h(50),
            tw.bg(tokens.bg_surface),
            tw.items_center,
            tw.px(4),
            tw.py(2),
            tw.gap(2),
        },
        .children = .{
            try ux.text(.{
                .content = state.editor.status_text.items,
                .font = font,
                .class = tw.text_color(tokens.text_main),
            }),
            try ux.div(.{ .class = tw.grow_1 }),
            try ux.button(.{
                .label = "Help [?]",
                .font = font,
                .class = .{
                    tw.px(2.5),
                    tw.py(1.5),
                    tw.bg(tokens.action_default),
                    tw.rounded(6),
                    tw.shrink_0,
                    tw.justify_center,
                    tw.items_center,
                },
                .label_class = tw.text_color(tokens.text_inverse),
                .on_click = .{ .toggle_help = {} },
            }),
        },
    });
}
