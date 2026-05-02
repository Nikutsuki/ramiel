const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const layout = lib.layout;

pub fn build(_: std.mem.Allocator, ui: *core.AppUIContext, state: *const core.AppState, font: *lib.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    return ui.div(.{
        .style = .{
            .direction = .Row,
            .width = .Full,
            .height = .{ .exact = 50 },
            .background_color = tokens.bg_surface,
            .align_items = .Center,
            .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
            .gap = 8,
        },
        .children = &.{
            try ui.text(.{
                .content = state.editor.status_text.items,
                .font = font,
                .style = .{ .text_color = tokens.text_main },
            }),
            try ui.div(.{ .style = .{ .flex_grow = 1 } }),
            try ui.button(.{
                .label = "Help [?]",
                .font = font,
                .style = .{
                    .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
                    .background_color = tokens.action_default,
                    .corner_radius = layout.CornerRadius.all(6),
                    .flex_shrink = 0,
                    .justify_content = .Center,
                    .align_items = .Center,
                },
                .label_style = .{ .text_color = tokens.text_inverse },
                .events = &.{.{ .event = .click, .msg = .{ .toggle_help = {} } }},
            }),
        },
    });
}
