const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const filters = @import("../filters.zig");
const tw = core.tw;

pub fn build(
    allocator: std.mem.Allocator,
    ui: *core.AppUIContext,
    state: *const core.AppState,
    font: *lib.FontData,
) !*core.AppNode {
    const components = ui.components();
    const tokens = ui.active_theme.tokens;
    const ux = ui.ux();
    var param_children = std.ArrayList(*core.AppNode).empty;
    defer param_children.deinit(allocator);

    if (state.editor.active_filter) |filter| {
        const meta = filters.getFilterMeta(filter);
        try param_children.append(allocator, try ux.textAny(.{
            .content = meta.name,
            .font = font,
            .class = .{ tw.text_main, tw.mb(2) },
        }));

        for (meta.params, 0..) |param_def, param_idx| {
            if (param_idx >= core.MAX_DYNAMIC_PARAMS) break;
            const node_id = core.makeParamNodeId(filter, param_idx, 0);
            switch (param_def.kind) {
                .slider => {
                    const current_val = state.editor.filter_params[param_idx];
                    const label_text = try std.fmt.allocPrint(ui.build_arena.allocator(), "{s}: {d:.1}", .{ param_def.name, current_val });
                    try param_children.append(allocator, try ux.textAny(.{ .content = label_text, .font = font, .class = tw.text_main }));

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
                    try param_children.append(allocator, try components.slider(.{
                        .base_id = node_id,
                        .value = std.math.clamp(normalized, 0.0, 1.0),
                        .on_change = core.Dispatch.pickParamOnChange(param_idx),
                    }));
                },
                .radio => {
                    try param_children.append(allocator, try ux.textAny(.{ .content = param_def.name, .font = font, .class = tw.text_main }));
                    const options = param_def.options orelse &.{};
                    var active_index: usize = @as(usize, @intFromFloat(@max(0.0, state.editor.filter_params[param_idx])));
                    if (core.isMaskFilter(filter) and param_idx == 0) {
                        active_index = core.maskFilterToIndex(filter);
                    }
                    if (options.len > 0) active_index = @min(active_index, options.len - 1);
                    try param_children.append(allocator, try components.radioGroup(.{
                        .logic = .{
                            .base_id = node_id,
                            .active_index = active_index,
                            .on_change = core.Dispatch.pickRadioOnChange(param_idx),
                        },
                        .visuals = .{
                            .options = options,
                            .font = font,
                        },
                    }));
                },
                .palette_editor => {
                    try param_children.append(allocator, try ux.textAny(.{ .content = param_def.name, .font = font, .class = tw.text_main }));

                    var swatches = try ux.keyed(core.NodeIds.palette_swatches, state.editor.dither_palette_hsv.items.len);
                    for (state.editor.dither_palette_hsv.items, 0..) |hsv, i| {
                        const rgb = lib.Color.hsvToRgb(hsv[0], hsv[1], hsv[2]);
                        const is_selected = i == state.editor.dither_selected_color;
                        const swatch_color: [4]f32 = .{ rgb[0], rgb[1], rgb[2], 1.0 };
                        var swatch_style = tw.style(.{
                            tw.square(24.0),
                            tw.bg_value(swatch_color),
                            tw.rounded(4.0),
                            tw.cursor_pointer,
                        });
                        if (is_selected) {
                            swatch_style = tw.apply(swatch_style, tw.border_value(2.0, tokens.action_default));
                        }
                        try swatches.append(i, try ux.div(.{
                            .style = swatch_style,
                            .on_click = .{ .palette_select = i },
                        }));
                    }
                    try param_children.append(allocator, try ux.divAny(.{
                        .class = .{ tw.flex_row, tw.gap_px(6.0), tw.flex_wrap },
                        .children = swatches.slice(),
                    }));

                    try param_children.append(allocator, try ux.divAny(.{
                        .class = .{ tw.flex_row, tw.gap(2), tw.mt(1.5) },
                        .children = .{
                            try ux.buttonAny(.{
                                .label = "+ Add",
                                .font = font,
                                .class = .{
                                    tw.px(2),
                                    tw.py(1),
                                    tw.bg_action,
                                    tw.rounded(6.0),
                                },
                                .label_class = tw.text_inverse,
                                .on_click = .{ .palette_add = {} },
                            }),
                            try ux.buttonAny(.{
                                .label = "- Remove",
                                .font = font,
                                .class = .{
                                    tw.px(2),
                                    tw.py(1),
                                    tw.bg_base,
                                    tw.rounded(6.0),
                                    tw.border_subtle,
                                },
                                .label_class = tw.text_main,
                                .on_click = .{ .palette_remove = {} },
                            }),
                        },
                    }));

                    if (state.runtime.color_picker_canvas) |picker_canvas| {
                        const selected = @min(state.editor.dither_selected_color, state.editor.dither_palette_hsv.items.len - 1);
                        const active_hsv = state.editor.dither_palette_hsv.items[selected];
                        try param_children.append(allocator, try components.colorPicker(.{
                            .logic = .{
                                .base_id = core.makeParamNodeId(filter, param_idx, 1),
                                .plane_canvas = picker_canvas,
                                .hsv = active_hsv,
                                .on_hue_change = core.Dispatch.pickerHue,
                                .on_sv_change = core.Dispatch.pickerSv,
                            },
                            .visuals = .{
                                .plane_size = 200.0,
                                .hex_font = font,
                            },
                        }));
                    }
                },
            }
            try param_children.append(allocator, try ux.divAny(.{ .class = tw.h(8.0) }));
        }
    } else {
        try param_children.append(allocator, try ux.textAny(.{
            .content = "No active filter",
            .font = font,
            .class = tw.text_muted,
        }));
    }

    return try ux.divAny(.{
        .class = .{
            tw.flex_col,
            tw.w(250),
            tw.h_full,
            tw.bg_surface,
            tw.p(3),
            tw.gap(2),
        },
        .children = param_children.items,
    });
}
