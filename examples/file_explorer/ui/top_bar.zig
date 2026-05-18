const std = @import("std");
const core = @import("../core.zig");
const tw = core.tw;

pub fn build(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {

    const arena = ui.build_arena.allocator();
    const tokens = ui.active_theme.tokens;
    const font = state.font_data;

    const back_disabled = state.back_stack.items.len == 0;
    const fwd_disabled = state.forward_stack.items.len == 0;
    const up_disabled = (std.fs.path.dirname(state.current_path) == null);

    const back_btn = try navButton(ui, font, "<", .{ .navigate_back = {} }, back_disabled);
    const fwd_btn = try navButton(ui, font, ">", .{ .navigate_forward = {} }, fwd_disabled);
    const up_btn = try navButton(ui, font, "Up", .{ .navigate_up = {} }, up_disabled);
    const refresh_btn = try navButton(ui, font, "Refresh", .{ .refresh = {} }, false);
    const new_folder_btn = try navButton(ui, font, "+ Folder", .{ .new_folder = {} }, false);
    const delete_btn = try navButton(ui, font, "Delete", .{ .delete_selected = {} }, state.selected_path == null);

    const breadcrumb_strip = if (state.editing_path)
        try buildPathInput(ui, font, state)
    else
        try buildBreadcrumbs(ui, font, state, arena);

    const status_node = try ui.ux().text(.{
        .id = null,
        .content = state.status,
        .font = font,
        .style = tw.style(.{
            tw.text_color_value(tokens.status_warning),
            tw.text(12.0),
            tw.pointer_events_none,
        }),
    });

    return try ui.ux().div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.h(44.0),
            tw.bg_value(tokens.bg_surface),
            tw.p_xy_px(8.0, 4.0),
            tw.flex_row,
            tw.items_center,
            tw.border_b_value(1.0, tokens.border_subtle),
        }),
        .children = &.{ back_btn, fwd_btn, up_btn, refresh_btn, new_folder_btn, delete_btn, breadcrumb_strip, status_node },
    });
}

fn buildBreadcrumbs(
    ui: *core.AppUIContext,
    font: *core.FontData,
    state: *const core.AppState,
    arena: std.mem.Allocator,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;

    var breadcrumbs = std.ArrayList(?*core.AppNode).empty;
    const segments = try splitPathSegments(arena, state.current_path);
    for (segments, 0..) |seg, i| {
        try breadcrumbs.append(arena, try crumb(ui, font, state, seg.label, seg.path));
        if (i + 1 < segments.len) try breadcrumbs.append(arena, try separator(ui, font));
    }

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.flex_row,
            tw.items_center,
            tw.grow_1,
            tw.h_full,
            tw.p_xy_px(10.0, 4.0),
            tw.m_xy_px(6.0, 0),
            tw.overflow_x_scroll,
            tw.bg_value(tokens.bg_base),
            tw.rounded(6.0),
            tw.border_value(1.0, tokens.border_subtle),
            tw.cursor_text,
        }),
        .children = try breadcrumbs.toOwnedSlice(arena),
        .events = &.{.{ .event = .click, .msg = .{ .begin_path_edit = {} } }},
    });
}

fn buildPathInput(
    ui: *core.AppUIContext,
    font: *core.FontData,
    state: *const core.AppState,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;

    return ui.ux().textInput(.{
        .id = core.NodeIds.path_input,
        .font = font,
        .initial_text = state.current_path,
        .style = tw.style(.{
            tw.grow_1,
            tw.h_full,
            tw.p_xy_px(10.0, 6.0),
            tw.m_xy_px(6.0, 0),
            tw.bg_value(tokens.bg_base),
            tw.text_color_value(tokens.text_main),
            tw.rounded(6.0),
            tw.border_value(1.0, tokens.border_focus),
            tw.text(14.0),
        }),
        .events = &.{
            .{ .event = .key_down, .msg = .{ .path_input_event = {} } },
        },
    });
}

fn navButton(
    ui: *core.AppUIContext,
    font: *core.FontData,
    label: []const u8,
    msg: core.AppMessage,
    disabled: bool,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;

    const text_node = try ui.ux().text(.{
        .id = null,
        .content = label,
        .font = font,
        .style = tw.style(.{
            tw.text_color_value(.{ 1.0, 1.0, 1.0, 1.0 }),
            tw.text(13.0),
            tw.pointer_events_none,
        }),
    });

    if (disabled) {
        return ui.ux().div(.{
            .style = tw.style(.{
                tw.h_full,
                tw.p_xy_px(10.0, 0),
                tw.mr_px(4.0),
                tw.rounded(4.0),
                tw.bg_value(tokens.action_disabled),
                tw.flex_row,
                tw.items_center,
                tw.justify_center,
                tw.opacity(0.55),
            }),
            .children = &.{text_node},
        });
    }

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.h_full,
            tw.p_xy_px(10.0, 0),
            tw.mr_px(4.0),
            tw.rounded(4.0),
            tw.bg_value(tokens.action_default),
            tw.hover_value(tokens.action_hover),
            tw.flex_row,
            tw.items_center,
            tw.justify_center,
            tw.cursor_pointer,
        }),
        .children = &.{text_node},
        .events = &.{.{ .event = .click, .msg = msg }},
    });
}

const Segment = struct { label: []const u8, path: []const u8 };

fn splitPathSegments(arena: std.mem.Allocator, path: []const u8) ![]Segment {
    var out = std.ArrayList(Segment).empty;
    if (path.len == 0) return out.toOwnedSlice(arena);

    var i: usize = 0;
    while (i < path.len and !isSep(path[i])) i += 1;
    if (i == 0) i = 1; // POSIX root "/"
    if (i < path.len and isSep(path[i])) i += 1;
    try out.append(arena, .{ .label = path[0..i], .path = path[0..i] });

    while (i < path.len) {
        const start = i;
        while (i < path.len and !isSep(path[i])) i += 1;
        if (i > start) {
            const seg_end = i;
            try out.append(arena, .{ .label = path[start..seg_end], .path = path[0..seg_end] });
        }
        if (i < path.len and isSep(path[i])) i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn crumb(
    ui: *core.AppUIContext,
    font: *core.FontData,
    state: *const core.AppState,
    label: []const u8,
    target_path: []const u8,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const is_current = std.mem.eql(u8, target_path, state.current_path);

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.p_xy_px(6.0, 2.0),
            tw.rounded(3.0),
            tw.hover_value(tokens.action_hover),
            tw.cursor_pointer,
            tw.flex_row,
            tw.items_center,
        }),
        .children = &.{try ui.ux().text(.{
            .id = null,
            .content = label,
            .font = font,
            .style = tw.style(.{
                tw.text_color_value(if (is_current) tokens.text_main else tokens.text_muted),
                tw.text(13.0),
                tw.pointer_events_none,
            }),
        })},
        .events = &.{.{ .event = .click, .msg = .{ .navigate_to = target_path } }},
    });
}

fn separator(ui: *core.AppUIContext, font: *core.FontData) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    return ui.ux().text(.{
        .id = null,
        .content = ">",
        .font = font,
        .style = tw.style(.{
            tw.text_color_value(tokens.text_disabled),
            tw.text(12.0),
            tw.pointer_events_none,
            tw.p_xy_px(2.0, 0),
        }),
    });
}
