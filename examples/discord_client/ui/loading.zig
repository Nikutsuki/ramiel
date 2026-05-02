const core = @import("../core.zig");
const Style = core.Style;
const tw = core.tw;

pub fn build(ui: *core.AppUIContext, font_data: *core.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    return try ui.div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .justify_content = .Center,
            .align_items = .Center,
            .background_color = tokens.bg_base,
        },
        .children = &.{
            try ui.text(.{
                .content = "Loading Discord Data...",
                .font = font_data,
                .style = Style.mix(.{
                    tw.text_3xl,
                    tw.font_bold,
                    .{
                        .text_color = tokens.text_main,
                    },
                }),
            }),
        },
    });
}
