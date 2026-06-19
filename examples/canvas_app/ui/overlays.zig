const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const tw = core.tw;

pub fn buildPalette(
    allocator: std.mem.Allocator,
    ui: *core.AppUIContext,
    state: *const core.AppState,
    font: *lib.FontData,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const ux = ui.ux();
    var palette_children = std.ArrayList(*core.AppNode).empty;
    defer palette_children.deinit(allocator);

    try palette_children.append(allocator, try ux.textAny(.{
        .content = "Command Palette",
        .font = font,
        .class = tw.text_main,
    }));
    try palette_children.append(allocator, try ux.textInputAny(.{
        .id = core.NodeIds.palette_input,
        .class = .{
            tw.w_full,
            tw.h(36),
            tw.px(2.5),
            tw.py(2),
            tw.bg_base,
            tw.text_main,
            tw.rounded(6),
            tw.border_subtle,
        },
        .font = font,
        .initial_text = state.editor.palette_query.items,
        .on_key_down = .{ .palette_key_down = {} },
        .on_text_input = .{ .palette_query_changed = {} },
    }));

    const query = state.editor.palette_query.items;
    if (query.len > 0) {
        var cmd_it = std.mem.splitScalar(u8, query, ' ');
        const typed_cmd = cmd_it.next() orelse "";
        var suggestions = try ux.keyed(core.NodeIds.palette_suggestions, core.ALL_COMMANDS.len);
        for (core.ALL_COMMANDS) |cmd| {
            if (std.mem.startsWith(u8, cmd, typed_cmd)) {
                const suggestion = try std.fmt.allocPrint(ui.build_arena.allocator(), " >  {s}", .{cmd});
                try suggestions.append(cmd, try ux.textAny(.{
                    .content = suggestion,
                    .font = font,
                    .class = .{ tw.text_action, tw.mt(1) },
                }));
            }
        }
        try palette_children.append(allocator, try ux.fragment(suggestions.slice()));
    }

    var backdrop_color = tokens.bg_base;
    backdrop_color = backdrop_color.withAlpha(0.5);

    return try ux.divAny(.{
        .class = .{
            tw.absolute,
            tw.left(0),
            tw.top(0),
            tw.size_full,
            tw.justify_center,
            tw.items_center,
            tw.bg_value(backdrop_color),
            tw.z(100),
        },
        .on_click = .{ .close_palette = {} },
        .children = .{
            try ux.divAny(.{
                .class = .{
                    tw.w(400),
                    tw.p(4),
                    tw.bg_surface,
                    tw.rounded(8),
                    tw.flex_col,
                    tw.gap(2),
                    tw.border_subtle,
                },
                .on_click = .{ .palette_consume_click = {} },
                .children = palette_children.items,
            }),
        },
    });
}

pub fn buildHelp(ui: *core.AppUIContext, font: *lib.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const ux = ui.ux();

    var backdrop_color = tokens.bg_base;
    backdrop_color = backdrop_color.withAlpha(0.6);

    return try ux.divAny(.{
        .class = .{
            tw.absolute,
            tw.left(0),
            tw.top(0),
            tw.size_full,
            tw.justify_center,
            tw.items_center,
            tw.bg_value(backdrop_color),
            tw.z(200),
        },
        .on_click = .{ .toggle_help = {} },
        .children = .{
            try ux.divAny(.{
                .class = .{
                    tw.w(450),
                    tw.p(6),
                    tw.bg_surface,
                    tw.rounded(8),
                    tw.flex_col,
                    tw.gap_px(6),
                    tw.border_subtle,
                },
                .children = .{
                    try ux.textAny(.{ .content = "--- KEYBINDS ---", .font = font, .class = tw.text_action }),
                    try ux.textAny(.{ .content = "Ctrl+P : Open Command Palette", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "Ctrl+S : Commit Preview", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "Ctrl+R : Discard Preview", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "Ctrl+Z : Undo Last Commit", .font = font, .class = tw.text_main }),
                    try ux.divAny(.{ .class = tw.h(16) }),
                    try ux.textAny(.{ .content = "--- COMMANDS ---", .font = font, .class = tw.text_action }),
                    try ux.textAny(.{ .content = "open   : Open file dialog", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "invert : Invert colors", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "dilate : Dilation filter", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "erode  : Erosion filter", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "subtract: Subtract intensity (arg: amt)", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "mask [t]: luma, r, g, b, edge, contrast", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "restore [mode hist]: mode 0=mask,1=black-fill", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "glitch : Displacement (args: str, thresh)", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "kuwahara [r]: Edge-preserving smooth (1-15)", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "dither [s]: Bayer dithering spread (0-128)", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "sort [t dir]: Pixel sorting; dir 0=H, 1=V", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "aberration [x y]: RGB channel offsets", .font = font, .class = tw.text_main }),
                    try ux.textAny(.{ .content = "saveas <file.png|jpg|bmp|tga>: Save edited image", .font = font, .class = tw.text_main }),
                },
            }),
        },
    });
}
