const core = @import("../core.zig");
const tw = core.tw;

pub fn build(ui: *core.AppUIContext, font_data: *core.FontData) !*core.AppNode {
    const ux = ui.ux();
    return try ux.divAny(.{
        .class = .{ tw.size_screen, tw.justify_center, tw.items_center, tw.bg_base },
        .children = .{
            try ux.textAny(.{
                .content = "Loading Discord Data...",
                .font = font_data,
                .class = .{ tw.text_3xl, tw.font_bold, tw.text_main },
            }),
        },
    });
}
