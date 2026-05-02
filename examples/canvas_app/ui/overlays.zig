const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const layout = lib.layout;

pub fn buildPalette(
    allocator: std.mem.Allocator,
    ui: *core.AppUIContext,
    state: *const core.AppState,
    font: *lib.FontData,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    var palette_children = std.ArrayList(*core.AppNode).empty;
    defer palette_children.deinit(allocator);

    try palette_children.append(allocator, try ui.text(.{
        .content = "Command Palette",
        .font = font,
        .style = .{ .text_color = tokens.text_main },
    }));
    try palette_children.append(allocator, try ui.textInput(.{
        .id = core.NodeIds.palette_input,
        .style = .{
            .width = .Full,
            .height = .{ .exact = 36 },
            .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 },
            .background_color = tokens.bg_base,
            .text_color = tokens.text_main,
            .corner_radius = layout.CornerRadius.all(6),
            .border = .all(1.0, tokens.border_subtle),
        },
        .font = font,
        .initial_text = state.editor.palette_query.items,
        .events = &.{
            .{ .event = .key_down, .msg = .{ .palette_key_down = {} } },
            .{ .event = .text_input, .msg = .{ .palette_query_changed = {} } },
        },
    }));

    const query = state.editor.palette_query.items;
    if (query.len > 0) {
        var cmd_it = std.mem.splitScalar(u8, query, ' ');
        const typed_cmd = cmd_it.next() orelse "";
        for (core.ALL_COMMANDS) |cmd| {
            if (std.mem.startsWith(u8, cmd, typed_cmd)) {
                const suggestion = try std.fmt.allocPrint(ui.build_arena.allocator(), " >  {s}", .{cmd});
                try palette_children.append(allocator, try ui.text(.{
                    .content = suggestion,
                    .font = font,
                    .style = .{ .text_color = tokens.action_default, .margin = .{ .top = 4 } },
                }));
            }
        }
    }

    var backdrop_color = tokens.bg_base;
    backdrop_color[3] = 0.5;

    return try ui.div(.{
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = .Full,
            .height = .Full,
            .justify_content = .Center,
            .align_items = .Center,
            .background_color = backdrop_color,
            .z_index = 100,
        },
        .events = &.{.{ .event = .click, .msg = .{ .close_palette = {} } }},
        .children = &.{
            try ui.div(.{
                .style = .{
                    .width = .{ .exact = 400 },
                    .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
                    .background_color = tokens.bg_surface,
                    .corner_radius = layout.CornerRadius.all(8),
                    .direction = .Column,
                    .gap = 8,
                    .border = .all(1.0, tokens.border_subtle),
                },
                .events = &.{.{ .event = .click, .msg = .{ .palette_consume_click = {} } }},
                .children = palette_children.items,
            }),
        },
    });
}

pub fn buildHelp(ui: *core.AppUIContext, font: *lib.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;

    var backdrop_color = tokens.bg_base;
    backdrop_color[3] = 0.6;

    return try ui.div(.{
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = .Full,
            .height = .Full,
            .justify_content = .Center,
            .align_items = .Center,
            .background_color = backdrop_color,
            .z_index = 200,
        },
        .events = &.{.{ .event = .click, .msg = .{ .toggle_help = {} } }},
        .children = &.{
            try ui.div(.{
                .style = .{
                    .width = .{ .exact = 450 },
                    .padding = .{ .left = 24, .right = 24, .top = 24, .bottom = 24 },
                    .background_color = tokens.bg_surface,
                    .corner_radius = layout.CornerRadius.all(8),
                    .direction = .Column,
                    .gap = 6,
                    .border = .all(1.0, tokens.border_subtle),
                },
                .children = &.{
                    try ui.text(.{ .content = "--- KEYBINDS ---", .font = font, .style = .{ .text_color = tokens.action_default } }),
                    try ui.text(.{ .content = "Ctrl+P : Open Command Palette", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "Ctrl+S : Commit Preview", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "Ctrl+R : Discard Preview", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "Ctrl+Z : Undo Last Commit", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.div(.{ .style = .{ .height = .{ .exact = 16 } } }),
                    try ui.text(.{ .content = "--- COMMANDS ---", .font = font, .style = .{ .text_color = tokens.action_default } }),
                    try ui.text(.{ .content = "open   : Open file dialog", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "invert : Invert colors", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "dilate : Dilation filter", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "erode  : Erosion filter", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "subtract: Subtract intensity (arg: amt)", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "mask [t]: luma, r, g, b, edge, contrast", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "restore [mode hist]: mode 0=mask,1=black-fill", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "glitch : Displacement (args: str, thresh)", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "kuwahara [r]: Edge-preserving smooth (1-15)", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "dither [s]: Bayer dithering spread (0-128)", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "sort [t dir]: Pixel sorting; dir 0=H, 1=V", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "aberration [x y]: RGB channel offsets", .font = font, .style = .{ .text_color = tokens.text_main } }),
                    try ui.text(.{ .content = "saveas <file.png|jpg|bmp|tga>: Save edited image", .font = font, .style = .{ .text_color = tokens.text_main } }),
                },
            }),
        },
    });
}
