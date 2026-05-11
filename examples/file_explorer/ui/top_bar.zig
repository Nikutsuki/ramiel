const std = @import("std");
const core = @import("../core.zig");

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
        .style = .{
            .text_color = tokens.status_warning,
            .font_size = 12.0,
            .pointer_events = .none,
        },
    });

    return try ui.ux().div(.{
        .style = .{
            .width = .Full,
            .height = .{ .exact = 44.0 },
            .background_color = tokens.bg_surface,
            .padding = .{ .left = 8.0, .right = 8.0, .top = 4.0, .bottom = 4.0 },
            .direction = .Row,
            .align_items = .Center,
            .border = .{ .bottom = .{ .width = 1.0, .color = tokens.border_subtle } },
        },
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
        .style = .{
            .direction = .Row,
            .align_items = .Center,
            .flex_grow = 1.0,
            .height = .Full,
            .padding = .{ .left = 10.0, .right = 10.0, .top = 4.0, .bottom = 4.0 },
            .margin = .{ .left = 6.0, .right = 6.0 },
            .overflow_x = .scroll,
            .background_color = tokens.bg_base,
            .corner_radius = core.layout.CornerRadius.all(6.0),
            .border = core.layout.Border.all(1.0, tokens.border_subtle),
            .cursor = .text,
        },
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
        .style = .{
            .flex_grow = 1.0,
            .height = .Full,
            .padding = .{ .left = 10.0, .right = 10.0, .top = 6.0, .bottom = 6.0 },
            .margin = .{ .left = 6.0, .right = 6.0 },
            .background_color = tokens.bg_base,
            .text_color = tokens.text_main,
            .corner_radius = core.layout.CornerRadius.all(6.0),
            .border = core.layout.Border.all(1.0, tokens.border_focus),
            .font_size = 14.0,
        },
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
        .style = .{
            .text_color = .{ 1.0, 1.0, 1.0, 1.0 },
            .font_size = 13.0,
            .pointer_events = .none,
        },
    });

    if (disabled) {
        return ui.ux().div(.{
            .style = .{
                .height = .Full,
                .padding = .{ .left = 10.0, .right = 10.0 },
                .margin = .{ .right = 4.0 },
                .corner_radius = core.layout.CornerRadius.all(4.0),
                .background_color = tokens.action_disabled,
                .direction = .Row,
                .align_items = .Center,
                .justify_content = .Center,
                .opacity = 0.55,
            },
            .children = &.{text_node},
        });
    }

    return ui.ux().div(.{
        .style = .{
            .height = .Full,
            .padding = .{ .left = 10.0, .right = 10.0 },
            .margin = .{ .right = 4.0 },
            .corner_radius = core.layout.CornerRadius.all(4.0),
            .background_color = tokens.action_default,
            .hover_color = tokens.action_hover,
            .direction = .Row,
            .align_items = .Center,
            .justify_content = .Center,
            .cursor = .pointer,
        },
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
        .style = .{
            .padding = .{ .left = 6.0, .right = 6.0, .top = 2.0, .bottom = 2.0 },
            .corner_radius = core.layout.CornerRadius.all(3.0),
            .hover_color = tokens.action_hover,
            .cursor = .pointer,
            .direction = .Row,
            .align_items = .Center,
        },
        .children = &.{try ui.ux().text(.{
            .id = null,
            .content = label,
            .font = font,
            .style = .{
                .text_color = if (is_current) tokens.text_main else tokens.text_muted,
                .font_size = 13.0,
                .pointer_events = .none,
            },
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
        .style = .{
            .text_color = tokens.text_disabled,
            .font_size = 12.0,
            .pointer_events = .none,
            .padding = .{ .left = 2.0, .right = 2.0 },
        },
    });
}
