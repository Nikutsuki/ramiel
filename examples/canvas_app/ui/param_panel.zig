const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const filters = @import("../filters.zig");
const layout = lib.layout;

pub fn build(
    allocator: std.mem.Allocator,
    ui: *core.AppUIContext,
    state: *const core.AppState,
    font: *lib.FontData,
) !*core.AppNode {
    const comp = lib.components.Builder(core.AppMessage){ .ui = ui };
    const tokens = ui.active_theme.tokens;
    var param_children = std.ArrayList(*core.AppNode).empty;
    defer param_children.deinit(allocator);

    if (state.editor.active_filter) |filter| {
        const meta = filters.getFilterMeta(filter);
        try param_children.append(allocator, try ui.text(.{
            .content = meta.name,
            .font = font,
            .style = .{ .text_color = tokens.text_main, .margin = .{ .bottom = 8 } },
        }));

        for (meta.params, 0..) |param_def, param_idx| {
            if (param_idx >= core.MAX_DYNAMIC_PARAMS) break;
            const node_id = core.makeParamNodeId(filter, param_idx, 0);
            switch (param_def.kind) {
                .slider => {
                    const current_val = state.editor.filter_params[param_idx];
                    const label_text = try std.fmt.allocPrint(ui.build_arena.allocator(), "{s}: {d:.1}", .{ param_def.name, current_val });
                    try param_children.append(allocator, try ui.text(.{ .content = label_text, .font = font, .style = .{ .text_color = tokens.text_main } }));

                    var normalized = if (@abs(param_def.max - param_def.min) > 0.0001)
                        (current_val - param_def.min) / (param_def.max - param_def.min)
                    else
                        0.0;
                    if (filter == .restore and param_idx == 1) {
                        const max_hist = if (state.editor.history.items.len > 0)
                            @as(f32, @floatFromInt(state.editor.history.items.len - 1))
                        else
                            0.0;
                        normalized = if (max_hist > 0.0) current_val / max_hist else 0.0;
                    }
                    try param_children.append(allocator, try comp.slider(.{
                        .base_id = node_id,
                        .value = std.math.clamp(normalized, 0.0, 1.0),
                        .on_change = core.Dispatch.pickParamOnChange(param_idx),
                    }));
                },
                .radio => {
                    try param_children.append(allocator, try ui.text(.{ .content = param_def.name, .font = font, .style = .{ .text_color = tokens.text_main } }));
                    const options = param_def.options orelse &.{};
                    var active_index: usize = @as(usize, @intFromFloat(@max(0.0, state.editor.filter_params[param_idx])));
                    if (core.isMaskFilter(filter) and param_idx == 0) {
                        active_index = core.maskFilterToIndex(filter);
                    }
                    if (options.len > 0) active_index = @min(active_index, options.len - 1);
                    try param_children.append(allocator, try comp.radioGroup(.{
                        .base_id = node_id,
                        .active_index = active_index,
                        .on_change = core.Dispatch.pickRadioOnChange(param_idx),
                    }, .{
                        .options = options,
                        .font = font,
                    }));
                },
                .palette_editor => {
                    try param_children.append(allocator, try ui.text(.{ .content = param_def.name, .font = font, .style = .{ .text_color = tokens.text_main } }));

                    var swatches = std.ArrayList(*core.AppNode).empty;
                    defer swatches.deinit(allocator);
                    for (state.editor.dither_palette_hsv.items, 0..) |hsv, i| {
                        const rgb = lib.Color.hsvToRgb(hsv[0], hsv[1], hsv[2]);
                        const is_selected = i == state.editor.dither_selected_color;
                        var swatch_style = layout.Style{
                            .width = .{ .exact = 24.0 },
                            .height = .{ .exact = 24.0 },
                            .background_color = .{ rgb[0], rgb[1], rgb[2], 1.0 },
                            .corner_radius = layout.CornerRadius.all(4.0),
                            .cursor = .pointer,
                        };
                        if (is_selected) {
                            swatch_style.border = .{
                                .top = .{ .width = 2.0, .color = tokens.action_default },
                                .right = .{ .width = 2.0, .color = tokens.action_default },
                                .bottom = .{ .width = 2.0, .color = tokens.action_default },
                                .left = .{ .width = 2.0, .color = tokens.action_default },
                            };
                        }
                        try swatches.append(allocator, try ui.div(.{
                            .style = swatch_style,
                            .events = &.{.{ .event = .click, .msg = .{ .palette_select = i } }},
                        }));
                    }
                    try param_children.append(allocator, try ui.div(.{
                        .style = .{ .direction = .Row, .gap = 6.0, .flex_wrap = .Wrap },
                        .children = swatches.items,
                    }));

                    try param_children.append(allocator, try ui.div(.{
                        .style = .{ .direction = .Row, .gap = 8.0, .margin = .{ .top = 6.0 } },
                        .children = &.{
                            try ui.button(.{
                                .label = "+ Add",
                                .font = font,
                                .style = .{
                                    .padding = .{ .left = 8.0, .right = 8.0, .top = 4.0, .bottom = 4.0 },
                                    .background_color = tokens.action_default,
                                    .corner_radius = layout.CornerRadius.all(6.0),
                                },
                                .label_style = .{ .text_color = tokens.text_inverse },
                                .events = &.{.{ .event = .click, .msg = .{ .palette_add = {} } }},
                            }),
                            try ui.button(.{
                                .label = "- Remove",
                                .font = font,
                                .style = .{
                                    .padding = .{ .left = 8.0, .right = 8.0, .top = 4.0, .bottom = 4.0 },
                                    .background_color = tokens.bg_base,
                                    .corner_radius = layout.CornerRadius.all(6.0),
                                    .border = .all(1.0, tokens.border_subtle),
                                },
                                .label_style = .{ .text_color = tokens.text_main },
                                .events = &.{.{ .event = .click, .msg = .{ .palette_remove = {} } }},
                            }),
                        },
                    }));

                    if (state.color_picker_canvas) |picker_canvas| {
                        const selected = @min(state.editor.dither_selected_color, state.editor.dither_palette_hsv.items.len - 1);
                        const active_hsv = state.editor.dither_palette_hsv.items[selected];
                        try param_children.append(allocator, try comp.colorPicker(.{
                            .base_id = core.makeParamNodeId(filter, param_idx, 1),
                            .plane_canvas = picker_canvas,
                            .hsv = active_hsv,
                            .on_hue_change = core.Dispatch.pickerHue,
                            .on_sv_change = core.Dispatch.pickerSv,
                        }, .{
                            .plane_size = 200.0,
                            .hex_font = font,
                        }));
                    }
                },
            }
            try param_children.append(allocator, try ui.div(.{ .style = .{ .height = .{ .exact = 8.0 } } }));
        }
    } else {
        try param_children.append(allocator, try ui.text(.{
            .content = "No active filter",
            .font = font,
            .style = .{ .text_color = tokens.text_muted },
        }));
    }

    return try ui.div(.{
        .style = .{
            .direction = .Column,
            .width = .{ .exact = 250 },
            .height = .Full,
            .background_color = tokens.bg_surface,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .gap = 8,
        },
        .children = param_children.items,
    });
}
