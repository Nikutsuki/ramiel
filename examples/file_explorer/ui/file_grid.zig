const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const layout = lib.layout;
const tw = core.tw;

pub fn build(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const arena = ui.build_arena.allocator();
    const tokens = ui.active_theme.tokens;
    const font = state.font_data;

    var cells = std.ArrayList(?*core.AppNode).empty;

    if (state.current_entries.items.len == 0) {
        const empty = try ui.ux().text(.{
            .id = null,
            .content = if (state.status.len > 0) state.status else "(empty)",
            .font = font,
            .style = tw.style(.{
                tw.text_color_value(tokens.text_muted),
                tw.text(12.0),
                tw.pointer_events_none,
            }),
        });
        return ui.ux().div(.{
            .style = tw.style(.{
                tw.size_full,
                tw.bg_value(tokens.bg_base),
                tw.p_px(20.0),
                tw.grow_1,
                tw.items_center,
                tw.justify_center,
            }),
            .children = &.{empty},
        });
    }

    for (state.current_entries.items) |entry| {
        try cells.append(arena, try cell(ui, state, font, entry));
    }

    return try ui.ux().div(.{
        .id = core.NodeIds.grid_root,
        .style = tw.style(.{
            tw.size_full,
            tw.bg_value(tokens.bg_base),
            tw.p_px(12.0),
            tw.border_l_value(1.0, tokens.border_subtle),
            tw.grow_1,
            tw.grid,
            tw.cols(&([_]layout.GridTrack{.{ .fr = 1.0 }} ** 10)),
            .{ .grid_auto_rows = layout.GridTrack{ .exact = 110.0 } },
            tw.gap_px(6.0),
            tw.overflow_y_scroll,
        }),
        .children = try cells.toOwnedSlice(arena),
    });
}

fn cell(
    ui: *core.AppUIContext,
    state: *const core.AppState,
    font: *core.FontData,
    entry: core.FsEntry,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const asset_id: u32 = if (entry.is_dir)
        @intFromEnum(core.AppAssets.folder)
    else
        @intFromEnum(core.AppAssets.file_open);

    const is_selected = if (state.selected_path) |p| std.mem.eql(u8, p, entry.path) else false;

    const icon_node = try ui.components().icon(.{
        .icon_id = asset_id,
        .style = tw.style(.{
            tw.square(56.0),
            tw.mb(1.5), // 6px (unit=4)
            tw.pointer_events_none,
        }),
        .intrinsic_size = .{ 56.0, 56.0 },
        .tint = (if (entry.is_dir) tokens.action_default else tokens.text_muted).toArray(),
    });

    const label_node = try ui.ux().text(.{
        .id = null,
        .content = entry.name,
        .font = font,
        .style = tw.style(.{
            tw.text_color_value(tokens.text_main),
            tw.text(13.0),
            tw.pointer_events_none,
        }),
    });

    return ui.ux().div(.{
        .id = core.components.deriveChildId(core.NodeIds.grid_entry, entry.path),
        .style = tw.style(.{
            tw.flex,
            tw.flex_col,
            tw.items_center,
            tw.justify_center,
            tw.p_xy_px(4.0, 6.0),
            tw.bg_value(if (is_selected) tokens.action_pressed else layout.Color.transparent),
            tw.hover_value(tokens.action_hover),
            tw.rounded(6.0),
            tw.cursor_pointer,
        }),
        .children = &.{ icon_node, label_node },
        .events = &.{.{
            .event = .click,
            .msg = .{ .grid_click = .{ .path = entry.path, .is_dir = entry.is_dir } },
        }},
    });
}
