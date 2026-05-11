const std = @import("std");
const core = @import("../core.zig");
const lib = @import("ramiel");
const layout = lib.layout;

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
            .style = .{
                .text_color = tokens.text_muted,
                .font_size = 12.0,
                .pointer_events = .none,
            },
        });
        return ui.ux().div(.{
            .style = .{
                .width = .Full,
                .height = .Full,
                .background_color = tokens.bg_base,
                .padding = core.layout.Spacing.all(20.0),
                .flex_grow = 1.0,
                .align_items = .Center,
                .justify_content = .Center,
            },
            .children = &.{empty},
        });
    }

    for (state.current_entries.items) |entry| {
        try cells.append(arena, try cell(ui, state, font, entry));
    }

    const columns = layout.GridTemplate.fromSlice(&([_]layout.GridTrack{.{ .fr = 1.0 }} ** 10));

    return try ui.ux().div(.{
        .id = core.NodeIds.grid_root,
        .style = .{
            .width = .Full,
            .height = .Full,
            .background_color = tokens.bg_base,
            .padding = core.layout.Spacing.all(12.0),
            .border = .{ .left = .{ .width = 1.0, .color = tokens.border_subtle } },
            .flex_grow = 1.0,
            .display = .grid,
            .grid_template_columns = columns,
            .grid_auto_rows = .{ .exact = 110.0 },
            .gap = 6.0,
            .overflow_y = .scroll,
        },
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
        .style = .{
            .width = .{ .exact = 56.0 },
            .height = .{ .exact = 56.0 },
            .margin = .{ .bottom = 6.0 },
            .pointer_events = .none,
        },
        .intrinsic_size = .{ 56.0, 56.0 },
        .tint = if (entry.is_dir) tokens.action_default else tokens.text_muted,
    });

    const label_node = try ui.ux().text(.{
        .id = null,
        .content = entry.name,
        .font = font,
        .style = .{
            .text_color = tokens.text_main,
            .font_size = 13.0,
            .pointer_events = .none,
        },
    });

    return ui.ux().div(.{
        .id = core.components.deriveChildId(core.NodeIds.grid_entry, entry.path),
        .style = .{
            .display = .flex,
            .direction = .Column,
            .align_items = .Center,
            .justify_content = .Center,
            .padding = .{ .top = 6.0, .bottom = 6.0, .left = 4.0, .right = 4.0 },
            .background_color = if (is_selected) tokens.action_pressed else .{ 0.0, 0.0, 0.0, 0.0 },
            .hover_color = tokens.action_hover,
            .corner_radius = core.layout.CornerRadius.all(6.0),
            .cursor = .pointer,
        },
        .children = &.{ icon_node, label_node },
        .events = &.{.{
            .event = .click,
            .msg = .{ .grid_click = .{ .path = entry.path, .is_dir = entry.is_dir } },
        }},
    });
}
