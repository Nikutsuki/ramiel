//! Music player page - Spotify-ish layout: left library tree, center song table, bottom playback bar.

const std = @import("std");
const lib = @import("ramiel");
const tw = lib.tw;
const comp = lib.components;
const layout = lib.layout;
const state_mod = @import("state.zig");
const icons_mod = @import("icons.zig");
const IconId = icons_mod.IconId;

fn iconChild(ctx: anytype, id: IconId, dim: f32, color: [4]f32) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    return ctx.components.icon(.{
        .icon_id = @intFromEnum(id),
        .scale = 1.0,
        .intrinsic_size = .{ dim, dim },
        .style = blk: {
            var s: layout.Style = .{};
            s.width = .{ .exact = dim };
            s.height = .{ .exact = dim };
            s.pointer_events = .none;
            break :blk s;
        },
        .tint = color,
        .alt_text = "",
        .fallback_state = .ready,
    });
}

pub const TreeView = enum { groups, tags };

pub const PlayerState = struct {
    pub const snapshot_version: lib.state.SnapshotVersion = 1;

    allocator: std.mem.Allocator,
    tree_view: TreeView = .groups,
    tree_state: comp.tree.TreeState([]const u8),
    selected_kind: SelectKind = .all,
    selected_id: u64 = 0,
    show_visualizer: bool = true,
    renaming_id: u64 = 0,
    renaming_kind: SelectKind = .all,
    rename_seed: []const u8 = "",
    view_dropdown_open: bool = false,
    context_menu_song: u64 = 0,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,

    pub const SelectKind = enum { all, group, tag };

    pub const Snapshot = struct {
        tree_view: TreeView = .groups,
        selected_kind: SelectKind = .all,
        selected_id: u64 = 0,
        show_visualizer: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator) !PlayerState {
        return .{
            .allocator = allocator,
            .tree_state = comp.tree.TreeState([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PlayerState) void {
        self.tree_state.deinit();
        if (self.rename_seed.len > 0) self.allocator.free(self.rename_seed);
    }

    pub fn snapshot(self: *const PlayerState) Snapshot {
        return .{
            .tree_view = self.tree_view,
            .selected_kind = self.selected_kind,
            .selected_id = self.selected_id,
            .show_visualizer = self.show_visualizer,
        };
    }

    pub fn restoreSnapshot(self: *PlayerState, d: *const Snapshot) !void {
        self.tree_view = d.tree_view;
        self.selected_kind = d.selected_kind;
        self.selected_id = d.selected_id;
        self.show_visualizer = d.show_visualizer;
    }
};

pub const PlayerMessage = union(enum) {
    set_view: TreeView,
    select_all,
    select_group: state_mod.GroupId,
    select_tag: state_mod.TagId,
    play_song: state_mod.SongId,
    toggle_play,
    stop,
    next_song,
    prev_song,
    seek: f32,
    create_group_quick,
    create_tag_quick,
    delete_group: state_mod.GroupId,
    delete_tag: state_mod.TagId,
    delete_song: state_mod.SongId,
    add_song_to_selected_group: state_mod.SongId,
    toggle_song_first_tag: state_mod.SongId,
    toggle_visualizer,
    open_import_dialog,
    import_picked: ?[]const u8,
    advanced_to_song: AdvancedTo,
    tree_msg: comp.TreeMessage([]const u8),
    volume_change: f32,
    search_changed,
    rename_changed,
    rename_key,
    begin_rename: BeginRename,
    cancel_rename,
    noop,
    view_dropdown_toggle: bool,
    view_dropdown_select: usize,
    open_context_menu: state_mod.SongId,
    close_context_menu,
    ctx_assign_to_group: AssignTo,
    ctx_toggle_tag: AssignTo,

    pub const AdvancedTo = struct { song: state_mod.SongId, new_pid: u64 };
    pub const BeginRename = struct { kind: PlayerState.SelectKind, id: u64, name: []const u8 };
    pub const AssignTo = struct { song: state_mod.SongId, target: u64 };
};

pub const PlayerPage = struct {
    pub const State = PlayerState;
    pub const Msg = PlayerMessage;
    pub const build = buildPlayer;
    pub const update = updatePlayer;
};

const Ids = lib.declareIds("examples.music.player", .{
    "shell",        "sidebar",       "tree",         "list",         "playbar",      "seek",
    "settings_cog", "view_groups",   "view_tags",    "import_btn",   "create_grp",   "create_tag",
    "play_btn",     "next_btn",      "prev_btn",     "viz_btn",      "context_menu", "wave",
    "spec",         "volume_slider", "search_input", "rename_input",
}){};

// Tree id format:
//   "g:<u64>"   group
//   "s:<u64>"   song (under group)
//   "t:<u64>"   tag
//   "st:<u64>:<u64>" song-under-tag (tag id, song id)
//   "all"       virtual "All Songs" root

const TreeViewItem = struct {
    id: []const u8,
    label: []const u8,
    is_group: bool = false,
    children: std.ArrayList(TreeViewItem) = .empty,
    icon_glyph: []const u8 = "",
    accent_color: ?[4]f32 = null,
};

fn buildTreeItems(arena: std.mem.Allocator, view: TreeView, lib_data: *const state_mod.Library) !std.ArrayList(TreeViewItem) {
    var roots: std.ArrayList(TreeViewItem) = .empty;

    // Tree-state tracks hover/selection by id, so each visible row needs a
    // unique string. Prefix every leaf with its parent's structural id so the
    // same song appears as distinct nodes under "all" vs each group/tag.
    var all_root: TreeViewItem = .{
        .id = try arena.dupe(u8, "all"),
        .label = try arena.dupe(u8, "All songs"),
        .is_group = true,
        .icon_glyph = "♪",
    };
    for (lib_data.songs) |s| {
        try all_root.children.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "all/s:{d}|{s}", .{ s.id, s.display_name }),
            .label = try arena.dupe(u8, s.display_name),
            .icon_glyph = "♪",
        });
    }
    try roots.append(arena, all_root);

    if (view == .groups) {
        for (lib_data.groups) |g| {
            var item: TreeViewItem = .{
                .id = try std.fmt.allocPrint(arena, "g:{d}|{s}", .{ g.id, g.name }),
                .label = try arena.dupe(u8, g.name),
                .is_group = true,
                .icon_glyph = "▣",
            };
            for (g.song_ids) |sid| {
                if (findSongById(lib_data, sid)) |s| {
                    try item.children.append(arena, .{
                        .id = try std.fmt.allocPrint(arena, "g:{d}/s:{d}|{s}", .{ g.id, s.id, s.display_name }),
                        .label = try arena.dupe(u8, s.display_name),
                        .icon_glyph = "♪",
                    });
                }
            }
            try roots.append(arena, item);
        }
    } else {
        for (lib_data.tags) |t| {
            const c = state_mod.hslToRgb(t.hue, 0.55, 0.6);
            var item: TreeViewItem = .{
                .id = try std.fmt.allocPrint(arena, "t:{d}|{s}", .{ t.id, t.name }),
                .label = try arena.dupe(u8, t.name),
                .is_group = true,
                .icon_glyph = "●",
                .accent_color = c,
            };
            for (lib_data.songs) |s| {
                for (s.tag_ids) |tid| if (tid == t.id) {
                    try item.children.append(arena, .{
                        .id = try std.fmt.allocPrint(arena, "t:{d}/s:{d}|{s}", .{ t.id, s.id, s.display_name }),
                        .label = try arena.dupe(u8, s.display_name),
                        .icon_glyph = "♪",
                    });
                    break;
                };
            }
            try roots.append(arena, item);
        }
    }
    return roots;
}

fn findSongById(lib_data: *const state_mod.Library, id: state_mod.SongId) ?*const state_mod.Song {
    for (lib_data.songs) |*s| if (s.id == id) return s;
    return null;
}

fn parseId(id_full: []const u8) struct { kind: PlayerState.SelectKind, song: ?state_mod.SongId, tag_or_group: ?u64 } {
    // Strip optional "|label" suffix so callers always work with the structural id.
    const id = if (std.mem.indexOfScalar(u8, id_full, '|')) |i| id_full[0..i] else id_full;
    // Format options:
    //   "all"                  → All-songs root
    //   "g:<id>"               → group root
    //   "t:<id>"               → tag root
    //   "all/s:<id>"           → song under All
    //   "g:<gid>/s:<sid>"      → song under group
    //   "t:<tid>/s:<sid>"      → song under tag
    if (std.mem.indexOf(u8, id, "/s:")) |slash| {
        const sid_text = id[slash + 3 ..];
        const sid = std.fmt.parseInt(u64, sid_text, 10) catch 0;
        const head = id[0..slash];
        if (std.mem.eql(u8, head, "all")) return .{ .kind = .all, .song = sid, .tag_or_group = null };
        if (head.len > 2 and std.mem.eql(u8, head[0..2], "g:")) {
            const gid = std.fmt.parseInt(u64, head[2..], 10) catch 0;
            return .{ .kind = .group, .song = sid, .tag_or_group = gid };
        }
        if (head.len > 2 and std.mem.eql(u8, head[0..2], "t:")) {
            const tid = std.fmt.parseInt(u64, head[2..], 10) catch 0;
            return .{ .kind = .tag, .song = sid, .tag_or_group = tid };
        }
        return .{ .kind = .all, .song = sid, .tag_or_group = null };
    }
    if (std.mem.eql(u8, id, "all")) return .{ .kind = .all, .song = null, .tag_or_group = null };
    if (id.len > 2 and std.mem.eql(u8, id[0..2], "g:")) {
        const v = std.fmt.parseInt(u64, id[2..], 10) catch 0;
        return .{ .kind = .group, .song = null, .tag_or_group = v };
    }
    if (id.len > 2 and std.mem.eql(u8, id[0..2], "t:")) {
        const v = std.fmt.parseInt(u64, id[2..], 10) catch 0;
        return .{ .kind = .tag, .song = null, .tag_or_group = v };
    }
    return .{ .kind = .all, .song = null, .tag_or_group = null };
}

fn buildPlayer(ctx: anytype, state: *const PlayerState) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;

    const top = try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.width = .Full;
            s.flex_grow = 1.0;
            s.direction = .Row;
            break :blk s;
        },
        .children = .{
            try buildSidebar(ctx, state),
            try buildSongList(ctx, state),
        },
    });

    var children: std.ArrayList(*lib.Node(M)) = .empty;
    try children.append(arena, top);
    try children.append(arena, try buildPlaybar(ctx, state));
    if (state.context_menu_song != 0) {
        try children.append(arena, try buildContextMenu(ctx, state.context_menu_song, state.context_menu_x, state.context_menu_y));
    }

    var root: layout.Style = .{};
    root.width = .Full;
    root.height = .Full;
    root.direction = .Column;
    root.background_color = tokens.bg_base;

    return ux.div(.{
        .id = Ids.shell,
        .style = root,
        .children = try children.toOwnedSlice(arena),
    });
}

fn buildContextMenu(ctx: anytype, song_id: state_mod.SongId, click_x: f32, click_y: f32) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const global = ctx.global;

    var items: std.ArrayList(*lib.Node(M)) = .empty;

    try items.append(arena, try menuHeader(ctx, "Add to playlist"));
    if (global.library.groups.len == 0) {
        try items.append(arena, try menuHint(ctx, "(no playlists yet)"));
    } else {
        for (global.library.groups) |g| {
            try items.append(arena, try menuItem(ctx, g.name, PlayerMessage{
                .ctx_assign_to_group = .{ .song = song_id, .target = g.id },
            }));
        }
    }
    try items.append(arena, try menuDivider(ctx));
    try items.append(arena, try menuHeader(ctx, "Toggle tag"));
    if (global.library.tags.len == 0) {
        try items.append(arena, try menuHint(ctx, "(no tags yet)"));
    } else {
        for (global.library.tags) |t| {
            try items.append(arena, try menuItem(ctx, t.name, PlayerMessage{
                .ctx_toggle_tag = .{ .song = song_id, .target = t.id },
            }));
        }
    }
    try items.append(arena, try menuDivider(ctx));
    try items.append(arena, try menuItemDanger(ctx, "Delete song", PlayerMessage{ .delete_song = song_id }));

    var panel: layout.Style = .{};
    panel.width = .{ .exact = 240.0 };
    panel.direction = .Column;
    panel.padding = pad(6, 6);
    panel.background_color = tokens.bg_elevated;
    panel.corner_radius = layout.CornerRadius.all(8.0);
    panel.gap = 2.0;
    panel.border = layout.Border.all(1.0, tokens.border_subtle);
    panel.position = .absolute;
    panel.left = click_x;
    panel.top = click_y;

    var backdrop: layout.Style = .{};
    backdrop.width = .Full;
    backdrop.height = .Full;
    backdrop.background_color = .{ 0, 0, 0, 0.001 };

    _ = font;
    return ux.portal(.{
        .id = Ids.context_menu,
        .style = backdrop,
        .on_click = PlayerMessage{ .close_context_menu = {} },
        .on_context_menu = PlayerMessage{ .close_context_menu = {} },
        .children = .{
            try ux.div(.{
                .style = panel,
                .on_click = PlayerMessage{ .noop = {} },
                .children = try items.toOwnedSlice(arena),
            }),
        },
    });
}

fn menuItem(ctx: anytype, label: []const u8, msg: PlayerMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.padding = pad(12, 8);
    s.background_color = ghost(tokens.action_subtle);
    s.hover_color = tokens.action_subtle;
    s.cursor = .pointer;
    s.corner_radius = layout.CornerRadius.all(4.0);
    s.transition = .{ .property = .{ .hover_color = true, .background_color = true }, .duration_ms = 80, .timing = .ease_out };
    var ts: layout.Style = .{};
    ts.text_color = tokens.text_main;
    ts.font_size = 12.0;
    ts.pointer_events = .none;
    return ux.div(.{
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = ts }),
        },
    });
}

fn menuItemDanger(ctx: anytype, label: []const u8, msg: PlayerMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.padding = pad(12, 8);
    s.background_color = ghost(tokens.status_danger_bg);
    s.hover_color = tokens.status_danger_bg;
    s.cursor = .pointer;
    s.corner_radius = layout.CornerRadius.all(4.0);
    s.transition = .{ .property = .{ .hover_color = true, .background_color = true }, .duration_ms = 80, .timing = .ease_out };
    var ts: layout.Style = .{};
    ts.text_color = tokens.status_danger;
    ts.font_size = 12.0;
    ts.pointer_events = .none;
    return ux.div(.{
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = ts }),
        },
    });
}

fn menuHeader(ctx: anytype, label: []const u8) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.text_color = tokens.text_muted;
    s.font_size = 10.0;
    s.padding = pad(12, 6);
    return ux.text(.{ .content = label, .font = font, .style = s });
}

fn menuHint(ctx: anytype, label: []const u8) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.text_color = tokens.text_disabled;
    s.font_size = 11.0;
    s.padding = pad(12, 4);
    return ux.text(.{ .content = label, .font = font, .style = s });
}

fn menuDivider(ctx: anytype) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    var s: layout.Style = .{};
    s.width = .Full;
    s.height = .{ .exact = 1.0 };
    s.background_color = tokens.border_subtle;
    s.margin = .{ .top = 4, .bottom = 4, .left = 0, .right = 0 };
    return ux.div(.{ .style = s });
}

fn buildSidebar(ctx: anytype, state: *const PlayerState) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const global = ctx.global;

    var children: std.ArrayList(*lib.Node(M)) = .empty;

    const view_dropdown = try ctx.components.dropdown(.{
        .base_id = Ids.view_groups,
        .is_open = state.view_dropdown_open,
        .active_index = if (state.tree_view == .groups) @as(usize, 0) else @as(usize, 1),
        .options = &[_][]const u8{ "Playlists", "Tags" },
        .on_toggle = onViewDropdownToggle(M),
        .on_select = onViewDropdownSelect(M),
        .font = font,
        .style = blk: {
            var s: layout.Style = .{};
            s.flex_grow = 1.0;
            break :blk s;
        },
        .trigger = .{ .style = blk: {
            var s: layout.Style = .{};
            s.background_color = tokens.bg_subtle;
            s.padding = pad(12, 8);
            s.border = layout.Border.all(1.0, tokens.border_strong);
            s.corner_radius = layout.CornerRadius.all(6.0);
            break :blk s;
        } },
        .menu = .{ .style = blk: {
            var s: layout.Style = .{};
            s.background_color = tokens.bg_subtle;
            s.min_width = .{ .exact = 180.0 };
            s.border = layout.Border.all(1.0, tokens.border_strong);
            s.corner_radius = layout.CornerRadius.all(6.0);
            break :blk s;
        } },
        .item = .{
            .active_color = tokens.accent_subtle,
            .hover_color = tokens.action_subtle,
            .style = blk: {
                var s: layout.Style = .{};
                s.width = .Full;
                s.background_color = tokens.bg_subtle;
                s.padding = pad(12, 8);
                break :blk s;
            },
        },
    });
    try children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.direction = .Row;
            s.gap = 8.0;
            s.padding = pad(12, 12);
            s.align_items = .Center;
            break :blk s;
        },
        .children = .{
            view_dropdown,
            try squareIconBtn(ctx, Ids.import_btn, .import, PlayerMessage.open_import_dialog, true),
            try squareIconBtn(
                ctx,
                if (state.tree_view == .groups) Ids.create_grp else Ids.create_tag,
                .plus,
                if (state.tree_view == .groups) PlayerMessage.create_group_quick else PlayerMessage.create_tag_quick,
                false,
            ),
        },
    }));

    const tree_items = try buildTreeItems(arena, state.tree_view, &global.library);
    var tree_visuals = comp.TreeDescriptor{};
    tree_visuals.style = blk: {
        var s: layout.Style = .{};
        s.width = .Full;
        s.padding = pad(8, 4);
        break :blk s;
    };
    tree_visuals.row_style = blk: {
        var s: layout.Style = .{};
        s.padding = pad(10, 6);
        s.corner_radius = layout.CornerRadius.all(4.0);
        break :blk s;
    };
    tree_visuals.active_row_color = tokens.action_subtle;
    tree_visuals.hover_row_color = tokens.bg_elevated;

    const tree_node = try ctx.components.treeFromSource(.{
        .state = &state.tree_state,
        .root_items = tree_items.items,
        .logic = comp.TreeSourceLogic(M){
            .base_id = Ids.tree,
            .build_row_content = buildTreeRow(M),
            .wrap_message = wrapTreeMsg(M),
            .userdata = @as(?*const anyopaque, @ptrCast(state)),
        },
        .visuals = tree_visuals,
    });

    try children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.flex_grow = 1.0;
            s.overflow_y = .scroll;
            s.width = .Full;
            break :blk s;
        },
        .children = .{tree_node},
    }));

    try children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.direction = .Row;
            s.align_items = .Center;
            s.padding = pad(8, 8);
            s.background_color = tokens.bg_surface;
            s.border = layout.Border{
                .top = .{ .width = 1.0, .color = tokens.border_subtle },
                .bottom = .{ .width = 0, .color = tokens.border_subtle },
                .left = .{ .width = 0, .color = tokens.border_subtle },
                .right = .{ .width = 0, .color = tokens.border_subtle },
            };
            break :blk s;
        },
        .children = .{try gotoIconBtn(ctx, Ids.settings_cog, .settings, "Settings", .settings)},
    }));

    var sidebar_style: layout.Style = .{};
    sidebar_style.width = .{ .exact = 300.0 };
    sidebar_style.height = .Full;
    sidebar_style.direction = .Column;
    sidebar_style.background_color = tokens.bg_surface;
    sidebar_style.border = layout.Border{
        .right = .{ .width = 1.0, .color = tokens.border_subtle },
        .top = .{ .width = 0, .color = tokens.border_subtle },
        .bottom = .{ .width = 0, .color = tokens.border_subtle },
        .left = .{ .width = 0, .color = tokens.border_subtle },
    };

    return ux.div(.{
        .id = Ids.sidebar,
        .style = sidebar_style,
        .children = try children.toOwnedSlice(arena),
    });
}

fn buildSegmented(ctx: anytype, view: TreeView) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    var s: layout.Style = .{};
    s.direction = .Row;
    s.padding = pad(12, 0);
    s.gap = 6.0;
    return ux.div(.{
        .style = s,
        .children = .{
            try segmentBtn(ctx, Ids.view_groups, "Groups", view == .groups, .{ .set_view = .groups }),
            try segmentBtn(ctx, Ids.view_tags, "Tags", view == .tags, .{ .set_view = .tags }),
        },
    });
}

fn segmentBtn(
    ctx: anytype,
    id: lib.NodeId,
    label: []const u8,
    active: bool,
    msg: PlayerMessage,
) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.flex_grow = 1.0;
    s.padding = pad(0, 7);
    s.justify_content = .Center;
    s.align_items = .Center;
    s.background_color = if (active) tokens.action_default else tokens.bg_elevated;
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    var ts: layout.Style = .{};
    ts.text_color = if (active) tokens.action_text else tokens.text_muted;
    ts.font_size = 12.0;
    ts.pointer_events = .none;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try ux.text(.{ .content = label, .font = font, .style = ts }),
        },
    });
}

fn squareIconBtn(
    ctx: anytype,
    id: lib.NodeId,
    icon: IconId,
    msg: PlayerMessage,
    primary: bool,
) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    var s: layout.Style = .{};
    s.width = .{ .exact = 36.0 };
    s.height = .{ .exact = 36.0 };
    s.direction = .Row;
    s.align_items = .Center;
    s.justify_content = .Center;
    s.background_color = if (primary) tokens.action_default else tokens.bg_elevated;
    s.corner_radius = layout.CornerRadius.all(8.0);
    s.cursor = .pointer;
    s.hover_color = if (primary) tokens.action_hover else tokens.bg_subtle;
    s.transition = .{ .property = .{ .hover_color = true, .background_color = true }, .duration_ms = 80, .timing = .ease_out };
    const tint: [4]f32 = if (primary) tokens.action_text else tokens.text_main;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try iconChild(ctx, icon, 18.0, tint),
        },
    });
}

fn onViewDropdownToggle(comptime M: type) *const fn (bool, ?*const anyopaque) M {
    return struct {
        fn cb(open: bool, _: ?*const anyopaque) M {
            return .{ .player = .{ .view_dropdown_toggle = open } };
        }
    }.cb;
}

fn onViewDropdownSelect(comptime M: type) *const fn (usize, ?*const anyopaque) M {
    return struct {
        fn cb(idx: usize, _: ?*const anyopaque) M {
            return .{ .player = .{ .view_dropdown_select = idx } };
        }
    }.cb;
}

fn iconBtn(
    ctx: anytype,
    id: lib.NodeId,
    icon: IconId,
    label: []const u8,
    msg: PlayerMessage,
    primary: bool,
) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.flex_grow = 1.0;
    s.direction = .Row;
    s.align_items = .Center;
    s.justify_content = .Center;
    s.gap = 6.0;
    s.padding = pad(0, 8);
    s.background_color = if (primary) tokens.action_default else tokens.bg_elevated;
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    s.hover_color = if (primary) tokens.action_hover else tokens.bg_subtle;
    var label_s: layout.Style = .{};
    label_s.text_color = if (primary) tokens.action_text else tokens.text_main;
    label_s.font_size = 11.0;
    label_s.pointer_events = .none;
    const tint: [4]f32 = if (primary) tokens.action_text else tokens.text_main;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try iconChild(ctx, icon, 16.0, tint),
            try ux.text(.{ .content = label, .font = font, .style = label_s }),
        },
    });
}

fn gotoIconBtn(
    ctx: anytype,
    id: lib.NodeId,
    icon: IconId,
    label: []const u8,
    comptime route: anytype,
) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    var s: layout.Style = .{};
    s.width = .Full;
    s.direction = .Row;
    s.align_items = .Center;
    s.gap = 10.0;
    s.padding = pad(12, 8);
    s.background_color = ghost(tokens.bg_elevated);
    s.corner_radius = layout.CornerRadius.all(6.0);
    s.cursor = .pointer;
    s.hover_color = tokens.bg_elevated;
    s.transition = .{ .property = .{ .hover_color = true, .background_color = true }, .duration_ms = 100, .timing = .ease_out };
    var label_s: layout.Style = .{};
    label_s.text_color = tokens.text_muted;
    label_s.font_size = 13.0;
    label_s.pointer_events = .none;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = ctx.goto(route),
        .children = .{
            try iconChild(ctx, icon, 18.0, tokens.text_main),
            try ux.text(.{ .content = label, .font = font, .style = label_s }),
        },
    });
}

fn buildTreeRow(comptime M: type) *const fn (*lib.UIContext(M), comp.TreeItem, ?*const anyopaque) anyerror!*lib.Node(M) {
    return struct {
        fn b(ctx: *lib.UIContext(M), item: comp.TreeItem, _: ?*const anyopaque) anyerror!*lib.Node(M) {
            const tokens = ctx.active_theme.tokens;
            const label = labelFromId(item.id);
            var ts: layout.Style = .{};
            ts.text_color = if (item.is_selected) tokens.text_main else tokens.text_muted;
            ts.font_size = 12.0;
            ts.pointer_events = .none;
            return ctx.text(.{
                .content = label,
                .font = ctx.default_font,
                .style = ts,
            });
        }
    }.b;
}

fn labelFromId(id: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, id, '|')) |i| return id[i + 1 ..];
    if (std.mem.eql(u8, id, "all")) return "All songs";
    return id;
}

fn wrapTreeMsg(comptime M: type) *const fn (comp.TreeMessage([]const u8)) M {
    return struct {
        fn w(m: comp.TreeMessage([]const u8)) M {
            return .{ .player = .{ .tree_msg = m } };
        }
    }.w;
}

fn buildSongList(ctx: anytype, state: *const PlayerState) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const global = ctx.global;

    var rows: std.ArrayList(*lib.Node(M)) = .empty;

    const title_node: *lib.Node(M) = if (state.renaming_id != 0 and isCurrentRenaming(state)) blk: {
        var box: layout.Style = .{};
        box.width = .{ .exact = 420.0 };
        box.font_size = 28.0;
        box.padding = pad(10, 6);
        box.background_color = tokens.bg_surface;
        box.corner_radius = layout.CornerRadius.all(6.0);
        box.text_color = tokens.text_main;
        break :blk try ux.textInput(.{
            .id = Ids.rename_input,
            .style = box,
            .font = font,
            .initial_text = state.rename_seed,
            .placeholder = "Name…",
            .placeholder_color = tokens.text_disabled,
            .on_text_input = .{ .rename_changed = {} },
            .on_key_down = .{ .rename_key = {} },
        });
    } else blk: {
        const title_text = switch (state.selected_kind) {
            .all => "All songs",
            .group => if (global.groupById(state.selected_id)) |g| g.name else "Group",
            .tag => if (global.tagById(state.selected_id)) |t| t.name else "Tag",
        };
        var s: layout.Style = .{};
        s.text_color = tokens.text_main;
        s.font_size = 32.0;
        break :blk try ux.text(.{ .content = title_text, .font = font, .style = s });
    };

    var header_children: std.ArrayList(*lib.Node(M)) = .empty;
    try header_children.append(arena, title_node);
    if (state.selected_kind != .all) {
        if (state.renaming_id != 0 and isCurrentRenaming(state)) {
            try header_children.append(arena, try miniIconBtn(ctx, .close, PlayerMessage.cancel_rename));
        } else {
            const cur_name = switch (state.selected_kind) {
                .group => if (global.groupById(state.selected_id)) |g| g.name else "",
                .tag => if (global.tagById(state.selected_id)) |t| t.name else "",
                .all => "",
            };
            try header_children.append(arena, try miniIconBtn(ctx, .edit, PlayerMessage{ .begin_rename = .{
                .kind = state.selected_kind,
                .id = state.selected_id,
                .name = cur_name,
            } }));
        }
    }
    try header_children.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.flex_grow = 1.0;
            break :blk s;
        },
    }));
    const visible_count = blk: {
        const search_q = ctx.ui.getInputText(Ids.search_input) orelse "";
        const v = collectVisibleSongs(arena, state, global, search_q) catch break :blk @as(usize, 0);
        break :blk v.len;
    };
    try header_children.append(arena, try ux.text(.{
        .content = countLabel(arena, visible_count) catch "",
        .font = font,
        .style = blk: {
            var s: layout.Style = .{};
            s.text_color = tokens.text_muted;
            s.font_size = 12.0;
            break :blk s;
        },
    }));

    try rows.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.padding = pad(28, 20);
            s.direction = .Row;
            s.gap = 12.0;
            s.align_items = .Center;
            break :blk s;
        },
        .children = try header_children.toOwnedSlice(arena),
    }));

    var search_box: layout.Style = .{};
    search_box.width = .{ .exact = 320.0 };
    search_box.background_color = tokens.bg_subtle;
    search_box.padding = pad(14, 10);
    search_box.corner_radius = layout.CornerRadius.all(8.0);
    search_box.font_size = 14.0;
    search_box.text_color = tokens.text_main;
    try rows.append(arena, try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.padding = pad(28, 0);
            s.margin = .{ .top = 0, .bottom = 12, .left = 0, .right = 0 };
            break :blk s;
        },
        .children = .{
            try ux.textInput(.{
                .id = Ids.search_input,
                .style = search_box,
                .font = font,
                .placeholder = "Search songs…",
                .placeholder_color = tokens.text_disabled,
                .on_text_input = .{ .search_changed = {} },
                .on_key_down = .{ .search_changed = {} },
            }),
        },
    }));

    const search_q = ctx.ui.getInputText(Ids.search_input) orelse "";
    const visible = try collectVisibleSongs(arena, state, global, search_q);

    var any = false;
    for (visible, 0..) |sid, i| {
        if (global.songById(sid)) |s| {
            any = true;
            try rows.append(arena, try songRow(ctx, s, i + 1));
        }
    }
    if (!any) {
        const msg_text = if (global.library.songs.len == 0)
            "Import a folder to start your library."
        else
            "Nothing here yet - pick a different filter.";
        try rows.append(arena, try ux.text(.{
            .content = msg_text,
            .font = font,
            .style = blk: {
                var s: layout.Style = .{};
                s.text_color = tokens.text_muted;
                s.font_size = 13.0;
                s.padding = pad(28, 32);
                break :blk s;
            },
        }));
    }

    var list_style: layout.Style = .{};
    list_style.height = .Full;
    list_style.flex_grow = 1.0;
    list_style.direction = .Column;
    list_style.background_color = tokens.bg_base;
    list_style.overflow_y = .scroll;

    return ux.div(.{
        .id = Ids.list,
        .style = list_style,
        .children = try rows.toOwnedSlice(arena),
    });
}

fn colHeaderText(comptime M: type, ux: anytype, font: ?*lib.FontData, tokens: lib.SemanticTokens, content: []const u8, width: f32) anyerror!*lib.Node(M) {
    var s: layout.Style = .{};
    s.text_color = tokens.text_muted;
    s.font_size = 10.0;
    if (width > 0) {
        s.width = .{ .exact = width };
    } else {
        s.flex_grow = 1.0;
    }
    return ux.text(.{ .content = content, .font = font, .style = s });
}

fn countLabel(arena: std.mem.Allocator, count: usize) ![]const u8 {
    const buf = try arena.alloc(u8, 32);
    return std.fmt.bufPrint(buf, "{d} songs", .{count});
}

fn collectVisibleSongs(
    arena: std.mem.Allocator,
    state: *const PlayerState,
    global: *const state_mod.AppGlobal,
    search_text: []const u8,
) ![]state_mod.SongId {
    var out: std.ArrayList(state_mod.SongId) = .empty;
    const q = search_text;

    switch (state.selected_kind) {
        .all => {
            for (global.library.songs) |s| {
                if (q.len > 0 and !containsCaseInsensitive(s.display_name, q)) continue;
                try out.append(arena, s.id);
            }
        },
        .group => {
            const g = global.groupById(state.selected_id) orelse return out.toOwnedSlice(arena);
            for (g.song_ids) |sid| {
                const s = global.songById(sid) orelse continue;
                if (q.len > 0 and !containsCaseInsensitive(s.display_name, q)) continue;
                try out.append(arena, sid);
            }
        },
        .tag => {
            const t = global.tagById(state.selected_id) orelse return out.toOwnedSlice(arena);
            for (global.library.songs) |s| {
                var has = false;
                for (s.tag_ids) |tid| if (tid == t.id) {
                    has = true;
                    break;
                };
                if (!has) continue;
                if (q.len > 0 and !containsCaseInsensitive(s.display_name, q)) continue;
                try out.append(arena, s.id);
            }
        },
    }
    return out.toOwnedSlice(arena);
}

fn matchesFilter(state: *const PlayerState, song: *const state_mod.Song) bool {
    return switch (state.selected_kind) {
        .all => true,
        .group => blk: {
            for (song.group_ids) |g| if (g == state.selected_id) break :blk true;
            break :blk false;
        },
        .tag => blk: {
            for (song.tag_ids) |t| if (t == state.selected_id) break :blk true;
            break :blk false;
        },
    };
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn isCurrentRenaming(state: *const PlayerState) bool {
    return state.renaming_kind == state.selected_kind and state.renaming_id == state.selected_id;
}

fn inputWithPlaceholder(
    ctx: anytype,
    comptime M: type,
    id: lib.NodeId,
    placeholder: []const u8,
    text_changed_msg: anytype,
    key_msg: anytype,
    font_size: f32,
    width: layout.Size,
) anyerror!*lib.Node(M) {
    return inputWithPlaceholderSeeded(ctx, M, id, placeholder, text_changed_msg, key_msg, font_size, width, "");
}

fn inputWithPlaceholderSeeded(
    ctx: anytype,
    comptime M: type,
    id: lib.NodeId,
    placeholder: []const u8,
    text_changed_msg: anytype,
    key_msg: anytype,
    font_size: f32,
    width: layout.Size,
    initial_text: []const u8,
) anyerror!*lib.Node(M) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const arena = ctx.ui.build_arena.allocator();

    const min_h: f32 = font_size + 16.0;

    var input_style: layout.Style = .{};
    input_style.width = .Full;
    input_style.font_size = font_size;
    input_style.padding = .{ .top = 0, .bottom = 0, .left = 0, .right = 0 };
    input_style.background_color = .{ 0, 0, 0, 0 };
    input_style.text_color = tokens.text_main;
    input_style.position = .absolute;
    input_style.left = 12.0;
    input_style.top = 0.0;
    input_style.bottom = 0.0;
    input_style.right = 12.0;

    var ph_style: layout.Style = .{};
    ph_style.text_color = tokens.text_disabled;
    ph_style.font_size = font_size;
    ph_style.position = .absolute;
    ph_style.left = 12.0;
    ph_style.top = (min_h - font_size) / 2.0;
    ph_style.pointer_events = .none;

    var wrap_style: layout.Style = .{};
    wrap_style.width = width;
    wrap_style.min_height = .{ .exact = min_h };
    wrap_style.height = .{ .exact = min_h };
    wrap_style.background_color = tokens.bg_subtle;
    wrap_style.corner_radius = layout.CornerRadius.all(8.0);
    wrap_style.position = .relative;

    const has_text = if (ctx.ui.getInputText(id)) |t| t.len > 0 else initial_text.len > 0;

    var children: std.ArrayList(*lib.Node(M)) = .empty;
    const input_node = if (comptime @typeInfo(@TypeOf(key_msg)) == .null)
        try ux.textInput(.{
            .id = id,
            .style = input_style,
            .font = font,
            .initial_text = initial_text,
            .on_text_input = text_changed_msg,
        })
    else
        try ux.textInput(.{
            .id = id,
            .style = input_style,
            .font = font,
            .initial_text = initial_text,
            .on_text_input = text_changed_msg,
            .on_key_down = key_msg,
        });
    try children.append(arena, input_node);

    if (!has_text and placeholder.len > 0) {
        try children.append(arena, try ux.text(.{
            .content = placeholder,
            .font = font,
            .style = ph_style,
        }));
    }

    return ux.div(.{
        .style = wrap_style,
        .children = try children.toOwnedSlice(arena),
    });
}

fn endRename(state: *PlayerState) void {
    state.renaming_id = 0;
    state.renaming_kind = .all;
    if (state.rename_seed.len > 0) {
        state.allocator.free(state.rename_seed);
        state.rename_seed = "";
    }
}

fn miniIconBtn(ctx: anytype, icon: IconId, msg: PlayerMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    var s: layout.Style = .{};
    s.width = .{ .exact = 30.0 };
    s.height = .{ .exact = 30.0 };
    s.direction = .Row;
    s.justify_content = .Center;
    s.align_items = .Center;
    s.background_color = tokens.bg_elevated;
    s.corner_radius = layout.CornerRadius.all(15.0);
    s.cursor = .pointer;
    s.hover_color = tokens.action_subtle;
    return ux.div(.{
        .style = s,
        .on_click = msg,
        .children = .{
            try iconChild(ctx, icon, 16.0, tokens.text_main),
        },
    });
}

fn songRow(ctx: anytype, song: *const state_mod.Song, index: usize) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const global = ctx.global;
    const playing = ctx.runtime.current_song_id == song.id;

    var row: layout.Style = .{};
    row.direction = .Row;
    row.align_items = .Center;
    row.gap = 16.0;
    row.padding = pad(28, 8);
    row.background_color = if (playing) tokens.action_subtle else .{ 0, 0, 0, 0 };
    row.cursor = .pointer;
    row.hover_color = tokens.bg_elevated;

    var idx_s: layout.Style = .{};
    idx_s.width = .{ .exact = 32.0 };
    idx_s.direction = .Row;
    idx_s.align_items = .Center;
    idx_s.justify_content = .Center;
    idx_s.pointer_events = .none;

    var idx_text_s: layout.Style = .{};
    idx_text_s.text_color = tokens.text_muted;
    idx_text_s.font_size = 12.0;
    idx_text_s.pointer_events = .none;

    const idx_text = try std.fmt.allocPrint(arena, "{d}", .{index});

    var title_s: layout.Style = .{};
    title_s.flex_grow = 1.0;
    title_s.text_color = if (playing) tokens.text_accent else tokens.text_main;
    title_s.font_size = 15.0;
    title_s.pointer_events = .none;

    var chips: std.ArrayList(*lib.Node(M)) = .empty;
    var shown: usize = 0;
    for (song.tag_ids) |tid| {
        if (shown >= 3) break;
        if (global.tagById(tid)) |t| {
            const c = state_mod.hslToRgb(t.hue, 0.5, 0.55);
            var chip: layout.Style = .{};
            chip.padding = pad(6, 2);
            chip.background_color = .{ c[0], c[1], c[2], 0.35 };
            chip.corner_radius = layout.CornerRadius.all(8.0);
            var chip_t: layout.Style = .{};
            chip_t.text_color = tokens.text_main;
            chip_t.font_size = 10.0;
            chip_t.pointer_events = .none;
            try chips.append(arena, try ux.div(.{
                .style = chip,
                .children = .{
                    try ux.text(.{ .content = t.name, .font = font, .style = chip_t }),
                },
            }));
            shown += 1;
        }
    }
    var chips_box: layout.Style = .{};
    chips_box.direction = .Row;
    chips_box.gap = 4.0;
    chips_box.width = .{ .exact = 200.0 };

    return ux.div(.{
        .style = row,
        .on_click = PlayerMessage{ .play_song = song.id },
        .on_context_menu = PlayerMessage{ .open_context_menu = song.id },
        .children = .{
            if (playing)
                try ux.div(.{
                    .style = idx_s,
                    .children = .{try iconChild(ctx, .play, 14.0, tokens.text_accent)},
                })
            else
                try ux.div(.{
                    .style = idx_s,
                    .children = .{try ux.text(.{ .content = idx_text, .font = font, .style = idx_text_s })},
                }),
            try ux.text(.{ .content = song.display_name, .font = font, .style = title_s }),
            try ux.div(.{ .style = chips_box, .children = try chips.toOwnedSlice(arena) }),
        },
    });
}

fn rowAction(ctx: anytype, icon: IconId, msg: PlayerMessage) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    var s: layout.Style = .{};
    s.width = .{ .exact = 32.0 };
    s.height = .{ .exact = 32.0 };
    s.direction = .Row;
    s.justify_content = .Center;
    s.align_items = .Center;
    s.background_color = tokens.bg_subtle;
    s.corner_radius = layout.CornerRadius.all(16.0);
    s.cursor = .pointer;
    s.hover_color = tokens.action_subtle;
    s.transition = .{
        .property = .{ .hover_color = true, .background_color = true },
        .duration_ms = 100,
        .timing = .ease_out,
    };
    return ux.div(.{
        .style = s,
        .on_click = msg,
        .children = .{
            try iconChild(ctx, icon, 18.0, tokens.text_main),
        },
    });
}

fn buildPlaybar(ctx: anytype, state: *const PlayerState) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const M = @TypeOf(ctx.*).Message;
    const ux = ctx.ux;
    const arena = ctx.ui.build_arena.allocator();
    const tokens = ctx.ui.active_theme.tokens;
    const font = ctx.runtime.font_data;
    const global = ctx.global;
    const rt = ctx.runtime;

    const current_song = if (rt.current_song_id) |sid| global.songById(sid) else null;
    const title = if (current_song) |s| s.display_name else "-";

    var swatch: layout.Style = .{};
    swatch.width = .{ .exact = 56.0 };
    swatch.height = .{ .exact = 56.0 };
    swatch.background_color = if (rt.current_song_id) |sid| state_mod.swatchColor(sid) else tokens.bg_elevated;
    swatch.corner_radius = layout.CornerRadius.all(4.0);

    var info_box: layout.Style = .{};
    info_box.direction = .Row;
    info_box.align_items = .Center;
    info_box.gap = 12.0;
    info_box.width = .{ .exact = 260.0 };
    info_box.padding = pad(0, 0);

    var title_s: layout.Style = .{};
    title_s.text_color = tokens.text_main;
    title_s.font_size = 13.0;

    var sub_s: layout.Style = .{};
    sub_s.text_color = tokens.text_muted;
    sub_s.font_size = 11.0;

    const left = try ux.div(.{
        .style = info_box,
        .children = .{
            try ux.div(.{ .style = swatch }),
            try ux.div(.{
                .style = blk: {
                    var s: layout.Style = .{};
                    s.direction = .Column;
                    s.gap = 2.0;
                    s.flex_grow = 1.0;
                    break :blk s;
                },
                .children = .{
                    try ux.text(.{ .content = title, .font = font, .style = title_s }),
                    try ux.text(.{ .content = "Local file", .font = font, .style = sub_s }),
                },
            }),
        },
    });

    const playing = rt.last_known_playing;
    const transport = try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.width = .Full;
            s.direction = .Row;
            s.gap = 12.0;
            s.justify_content = .Center;
            s.align_items = .Center;
            break :blk s;
        },
        .children = .{
            try transportBtn(ctx, Ids.prev_btn, .prev, PlayerMessage.prev_song, false),
            try transportBtn(ctx, Ids.play_btn, if (playing) .pause else .play, PlayerMessage.toggle_play, true),
            try transportBtn(ctx, Ids.next_btn, .next, PlayerMessage.next_song, false),
        },
    });

    const duration_or_one: f32 = if (rt.duration_seconds > 0.0) rt.duration_seconds else 1.0;
    const seek_norm = std.math.clamp(rt.cursor_seconds / duration_or_one, 0.0, 1.0);

    const seek_slider = try ctx.components.slider(.{
        .base_id = Ids.seek,
        .value = seek_norm,
        .on_change = struct {
            fn cb(v: f32, ud: ?*const anyopaque) M {
                const r: *const state_mod.AppRuntime = @ptrCast(@alignCast(ud.?));
                return .{ .player = .{ .seek = v * r.duration_seconds } };
            }
        }.cb,
        .userdata = @as(?*const anyopaque, @ptrCast(rt)),
    });

    var time_s: layout.Style = .{};
    time_s.text_color = tokens.text_muted;
    time_s.font_size = 10.0;
    time_s.width = .{ .exact = 36.0 };

    const seek_row = try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.width = .Full;
            s.direction = .Row;
            s.align_items = .Center;
            s.gap = 8.0;
            s.padding = pad(0, 4);
            break :blk s;
        },
        .children = .{
            try ux.text(.{
                .content = try formatTime(arena, rt.cursor_seconds),
                .font = font,
                .style = time_s,
            }),
            try ux.div(.{
                .style = blk: {
                    var s: layout.Style = .{};
                    s.flex_grow = 1.0;
                    break :blk s;
                },
                .children = .{seek_slider},
            }),
            try ux.text(.{
                .content = try formatTime(arena, rt.duration_seconds),
                .font = font,
                .style = time_s,
            }),
        },
    });

    const center = try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.direction = .Column;
            s.gap = 6.0;
            s.flex_grow = 1.0;
            s.padding = pad(20, 0);
            break :blk s;
        },
        .children = .{ transport, seek_row },
    });

    const VolCb = struct {
        fn cb(v: f32, _: ?*const anyopaque) M {
            return .{ .player = .{ .volume_change = v } };
        }
    };
    const vol_slider = try ctx.components.slider(.{
        .base_id = Ids.volume_slider,
        .value = std.math.clamp(global.playback.volume, 0.0, 1.0),
        .on_change = VolCb.cb,
    });

    const viz_preview = if (state.show_visualizer and global.visualizer_defaults.enabled and ctx.runtime.spectrum_initialized)
        try ctx.components.plot(.{
            .logic = .{
                .base_id = Ids.spec,
                .state = @constCast(&ctx.runtime.spectrum_state),
                .on_change = struct {
                    fn cb(_: comp.PlotMsg, _: ?*const anyopaque) M {
                        return .{ .player = .stop };
                    }
                }.cb,
            },
            .visuals = .{
                .style = blk: {
                    var s: layout.Style = .{};
                    s.width = .{ .exact = 110.0 };
                    s.height = .{ .exact = 40.0 };
                    s.corner_radius = layout.CornerRadius.all(4.0);
                    break :blk s;
                },
                .background_color = .{ 0, 0, 0, 0 },
                .bare = true,
                .enable_pan = false,
                .enable_zoom = false,
            },
        })
    else
        try ux.div(.{
            .style = blk: {
                var s: layout.Style = .{};
                s.width = .{ .exact = 110.0 };
                s.height = .{ .exact = 40.0 };
                break :blk s;
            },
        });

    const right = try ux.div(.{
        .style = blk: {
            var s: layout.Style = .{};
            s.width = .{ .exact = 320.0 };
            s.direction = .Row;
            s.align_items = .Center;
            s.justify_content = .End;
            s.gap = 10.0;
            break :blk s;
        },
        .children = .{
            viz_preview,
            try transportBtn(ctx, Ids.viz_btn, .spectrum, PlayerMessage.toggle_visualizer, false),
            try iconChild(ctx, .volume, 18.0, tokens.text_muted),
            try ux.div(.{
                .style = blk: {
                    var s: layout.Style = .{};
                    s.width = .{ .exact = 110.0 };
                    break :blk s;
                },
                .children = .{vol_slider},
            }),
        },
    });

    var bar: layout.Style = .{};
    bar.width = .Full;
    bar.height = .{ .exact = 100.0 };
    bar.direction = .Row;
    bar.align_items = .Center;
    bar.padding = pad(20, 12);
    bar.background_color = tokens.bg_surface;
    bar.border = layout.Border{
        .top = .{ .width = 1.0, .color = tokens.border_subtle },
        .bottom = .{ .width = 0, .color = tokens.border_subtle },
        .left = .{ .width = 0, .color = tokens.border_subtle },
        .right = .{ .width = 0, .color = tokens.border_subtle },
    };

    return ux.div(.{
        .id = Ids.playbar,
        .style = bar,
        .children = .{ left, center, right },
    });
}

fn transportBtn(
    ctx: anytype,
    id: lib.NodeId,
    icon: IconId,
    msg: PlayerMessage,
    primary: bool,
) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
    const ux = ctx.ux;
    const tokens = ctx.ui.active_theme.tokens;
    const dim: f32 = if (primary) 44.0 else 34.0;
    var s: layout.Style = .{};
    s.width = .{ .exact = dim };
    s.height = .{ .exact = dim };
    s.direction = .Row;
    s.justify_content = .Center;
    s.align_items = .Center;
    s.background_color = if (primary) tokens.accent_default else ghost(tokens.bg_elevated);
    s.transition = .{ .property = .{ .hover_color = true, .background_color = true }, .duration_ms = 100, .timing = .ease_out };
    s.corner_radius = layout.CornerRadius.all(dim / 2.0);
    s.cursor = .pointer;
    s.hover_color = if (primary) tokens.accent_hover else tokens.bg_elevated;
    const tint: [4]f32 = if (primary) tokens.action_text else tokens.text_main;
    const icon_dim: f32 = if (primary) 22.0 else 18.0;
    return ux.div(.{
        .id = id,
        .style = s,
        .on_click = msg,
        .children = .{
            try iconChild(ctx, icon, icon_dim, tint),
        },
    });
}

fn pad(h: f32, v: f32) layout.Spacing {
    return .{ .top = v, .bottom = v, .left = h, .right = h };
}

fn ghost(c: [4]f32) [4]f32 {
    return .{ c[0], c[1], c[2], 0.0 };
}

fn formatTime(arena: std.mem.Allocator, seconds: f32) ![]const u8 {
    const total = @max(0.0, seconds);
    const minutes: u32 = @intFromFloat(@divFloor(total, 60.0));
    const secs: u32 = @intFromFloat(@mod(total, 60.0));
    const buf = try arena.alloc(u8, 16);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, secs });
}

fn updatePlayer(ctx: anytype, state: *PlayerState, msg: PlayerMessage) lib.UpdateAction {
    const app = ctx.app;
    const global = ctx.global;
    switch (msg) {
        .set_view => |v| state.tree_view = v,
        .select_all => {
            state.selected_kind = .all;
            state.selected_id = 0;
        },
        .select_group => |gid| {
            state.selected_kind = .group;
            state.selected_id = gid;
        },
        .select_tag => |tid| {
            state.selected_kind = .tag;
            state.selected_id = tid;
        },
        .play_song => |sid| playSong(ctx, sid, true),
        .toggle_play => {
            if (ctx.runtime.playback_id) |pid| {
                if (app.isStreamPlaying(pid)) {
                    app.pauseStream(pid);
                    ctx.runtime.last_known_playing = false;
                } else {
                    app.resumeStream(pid);
                    ctx.runtime.last_known_playing = true;
                }
            }
        },
        .stop => {
            if (ctx.runtime.playback_id) |pid| app.stopSound(pid);
            ctx.runtime.playback_id = null;
            ctx.runtime.current_song_id = null;
            ctx.runtime.cursor_seconds = 0;
        },
        .next_song => stepSong(ctx, 1),
        .prev_song => stepSong(ctx, -1),
        .seek => |sec| {
            ctx.runtime.cursor_seconds = sec;
            if (ctx.runtime.playback_id) |pid| app.seekStream(pid, sec);
        },
        .create_group_quick => {
            const buf = std.fmt.allocPrint(global.allocator, "Playlist {d}", .{global.library.groups.len + 1}) catch return .none;
            defer global.allocator.free(buf);
            _ = global.createGroup(buf) catch {};
        },
        .create_tag_quick => {
            const buf = std.fmt.allocPrint(global.allocator, "Tag {d}", .{global.library.tags.len + 1}) catch return .none;
            defer global.allocator.free(buf);
            const hue = @mod(@as(f32, @floatFromInt(global.library.tags.len)) * 47.0 + 30.0, 360.0);
            _ = global.createTag(buf, hue) catch {};
        },
        .delete_group => |gid| {
            global.deleteGroup(gid);
            if (state.selected_kind == .group and state.selected_id == gid) {
                state.selected_kind = .all;
                state.selected_id = 0;
            }
        },
        .delete_tag => |tid| {
            global.deleteTag(tid);
            if (state.selected_kind == .tag and state.selected_id == tid) {
                state.selected_kind = .all;
                state.selected_id = 0;
            }
        },
        .delete_song => |sid| {
            if (ctx.runtime.current_song_id == sid) {
                if (ctx.runtime.playback_id) |pid| app.stopSound(pid);
                ctx.runtime.playback_id = null;
                ctx.runtime.current_song_id = null;
            }
            global.removeSong(sid);
        },
        .add_song_to_selected_group => |sid| {
            if (state.selected_kind == .group) {
                global.addSongToGroup(sid, state.selected_id) catch {};
            }
        },
        .toggle_song_first_tag => |sid| {
            if (global.library.tags.len > 0) {
                const tid = if (state.selected_kind == .tag) state.selected_id else global.library.tags[0].id;
                global.toggleSongTag(sid, tid) catch {};
            }
        },
        .toggle_visualizer => state.show_visualizer = !state.show_visualizer,
        .open_import_dialog => app.openFolderDialog(importPickedCb(@import("main.zig").AppMessage)),
        .import_picked => |maybe_path| {
            importFolderFromFile(ctx, maybe_path);
            if (maybe_path) |p| ctx.app.allocator.free(p);
        },
        .advanced_to_song => |a| {
            ctx.runtime.playback_id = a.new_pid;
            ctx.runtime.current_song_id = a.song;
            ctx.runtime.cursor_seconds = 0;
            ctx.runtime.duration_seconds = 0;
        },
        .tree_msg => |tm| handleTreeMsg(ctx, state, tm),
        .volume_change => |v| {
            global.playback.volume = v;
            if (ctx.runtime.playback_id) |pid| app.setSoundVolume(pid, v);
            global.markDirty();
        },
        .search_changed => {},
        .rename_changed => {},
        .rename_key => {
            switch (ctx.event_data) {
                .key => |k| if (k.action == 1) {
                    if (k.key == 257 or k.key == 335) {
                        if (app.ui.getInputText(Ids.rename_input)) |new_name| {
                            if (new_name.len > 0) {
                                switch (state.renaming_kind) {
                                    .group => global.renameGroup(state.renaming_id, new_name) catch {},
                                    .tag => global.renameTag(state.renaming_id, new_name) catch {},
                                    .all => {},
                                }
                            }
                        }
                        endRename(state);
                    } else if (k.key == 256) {
                        endRename(state);
                    }
                },
                else => {},
            }
        },
        .begin_rename => |b| {
            state.renaming_kind = b.kind;
            state.renaming_id = b.id;
            if (state.rename_seed.len > 0) state.allocator.free(state.rename_seed);
            state.rename_seed = state.allocator.dupe(u8, b.name) catch "";
            app.ui.requestFocus(Ids.rename_input);
        },
        .cancel_rename => endRename(state),
        .noop => {},
        .view_dropdown_toggle => |open| state.view_dropdown_open = open,
        .view_dropdown_select => |idx| {
            state.tree_view = if (idx == 0) .groups else .tags;
            state.view_dropdown_open = false;
        },
        .open_context_menu => |sid| {
            state.context_menu_song = sid;
            switch (ctx.event_data) {
                .mouse => |m| {
                    state.context_menu_x = m.x;
                    state.context_menu_y = m.y;
                },
                else => {},
            }
        },
        .close_context_menu => state.context_menu_song = 0,
        .ctx_assign_to_group => |a| {
            global.addSongToGroup(a.song, a.target) catch {};
            state.context_menu_song = 0;
        },
        .ctx_toggle_tag => |a| {
            global.toggleSongTag(a.song, a.target) catch {};
            state.context_menu_song = 0;
        },
    }
    return .rebuild;
}

fn handleTreeMsg(ctx: anytype, state: *PlayerState, tm: comp.TreeMessage([]const u8)) void {
    const global = ctx.global;
    switch (tm) {
        .click => |c| {
            const parsed = parseId(c.id);
            if (parsed.song) |sid| {
                playSong(ctx, sid, true);
                return;
            }
            switch (parsed.kind) {
                .all => {
                    state.selected_kind = .all;
                    state.selected_id = 0;
                    state.tree_state.toggleExpanded(c.id) catch {};
                },
                .group => {
                    if (parsed.tag_or_group) |gid| {
                        state.selected_kind = .group;
                        state.selected_id = gid;
                    }
                    state.tree_state.toggleExpanded(c.id) catch {};
                },
                .tag => {
                    if (parsed.tag_or_group) |tid| {
                        state.selected_kind = .tag;
                        state.selected_id = tid;
                    }
                    state.tree_state.toggleExpanded(c.id) catch {};
                },
            }
        },
        .toggle => |id| state.tree_state.toggleExpanded(id) catch {},
        .drag_start => |ds| {
            state.tree_state.dragged_id = ds.id;
            state.tree_state.drag_pos = ds.pos;
        },
        .drag_over => |d| {
            if (state.tree_state.dragged_id == null) return;
            state.tree_state.drop_target_id = d.target_id;
            state.tree_state.drop_target_pos = d.drop_pos;
            state.tree_state.drag_pos = d.drag_pos;
        },
        .drop => |d| {
            const dragged = state.tree_state.dragged_id;
            state.tree_state.dragged_id = null;
            state.tree_state.drag_pos = null;
            state.tree_state.drop_target_id = null;
            state.tree_state.drop_target_pos = null;
            const src_id = dragged orelse return;
            const src = parseId(src_id);
            const tgt = parseId(d.target_id);
            const song_id = src.song orelse return;
            switch (tgt.kind) {
                .group => if (tgt.tag_or_group) |gid| global.addSongToGroup(song_id, gid) catch {},
                .tag => if (tgt.tag_or_group) |tid| global.toggleSongTag(song_id, tid) catch {},
                .all => {},
            }
        },
        else => {},
    }
}

fn stepSong(ctx: anytype, dir: i32) void {
    const global = ctx.global;
    const state = &ctx.app_state.pages.player;
    const cur = ctx.runtime.current_song_id orelse return;

    var tmp = std.heap.ArenaAllocator.init(ctx.runtime.allocator);
    defer tmp.deinit();
    const search_q = ctx.app.ui.getInputText(Ids.search_input) orelse "";
    const visible = collectVisibleSongs(tmp.allocator(), state, global, search_q) catch return;
    if (visible.len == 0) return;

    var idx: usize = 0;
    var found = false;
    for (visible, 0..) |sid, i| {
        if (sid == cur) {
            idx = i;
            found = true;
            break;
        }
    }
    if (!found) return;
    const len: i64 = @intCast(visible.len);
    var ni: i64 = @as(i64, @intCast(idx)) + dir;
    if (ni < 0) ni = len - 1;
    if (ni >= len) ni = 0;
    playSong(ctx, visible[@intCast(ni)], true);
}

fn playSong(ctx: anytype, sid: state_mod.SongId, prefer_crossfade: bool) void {
    const app = ctx.app;
    const global = ctx.global;
    const song = global.songById(sid) orelse return;
    const path_z = ctx.runtime.allocator.dupeZ(u8, song.abs_path) catch return;
    defer ctx.runtime.allocator.free(path_z);

    const fade_ms = global.playback.crossfade_ms;
    if (prefer_crossfade and fade_ms > 0) {
        if (ctx.runtime.playback_id) |pid| {
            const new_pid = app.startCrossfade(pid, path_z, fade_ms) catch null;
            if (new_pid) |np| {
                ctx.runtime.playback_id = np;
                ctx.runtime.current_song_id = sid;
                ctx.runtime.cursor_seconds = 0;
                ctx.runtime.duration_seconds = 0;
                ctx.runtime.last_known_playing = true;
                queueNext(ctx, sid);
                return;
            }
        }
    }

    if (ctx.runtime.playback_id) |pid| app.stopSound(pid);
    if (app.playAudioStream(path_z)) |pid| {
        ctx.runtime.playback_id = pid;
        ctx.runtime.current_song_id = sid;
        ctx.runtime.cursor_seconds = 0;
        ctx.runtime.duration_seconds = 0;
        ctx.runtime.last_known_playing = true;
        app.setSoundVolume(pid, global.playback.volume);
        queueNext(ctx, sid);
    }
}

fn queueNext(ctx: anytype, sid: state_mod.SongId) void {
    const app = ctx.app;
    const global = ctx.global;
    if (!global.playback.gapless_in_group) return;
    const pid = ctx.runtime.playback_id orelse return;
    const next_sid = nextSongInActiveGroup(ctx, sid) orelse return;
    const next_song = global.songById(next_sid) orelse return;
    const path_z = ctx.runtime.allocator.dupeZ(u8, next_song.abs_path) catch return;
    defer ctx.runtime.allocator.free(path_z);
    app.enqueueAfter(pid, path_z) catch {};
}

fn nextSongInActiveGroup(ctx: anytype, current: state_mod.SongId) ?state_mod.SongId {
    const global = ctx.global;
    const state = &ctx.app_state.pages.player;
    var tmp = std.heap.ArenaAllocator.init(ctx.runtime.allocator);
    defer tmp.deinit();
    const search_q = ctx.app.ui.getInputText(Ids.search_input) orelse "";
    const visible = collectVisibleSongs(tmp.allocator(), state, global, search_q) catch return null;
    for (visible, 0..) |sid, i| {
        if (sid == current and i + 1 < visible.len) return visible[i + 1];
    }
    return null;
}

pub fn importPickedCb(comptime M: type) *const fn (?[]const u8) M {
    return struct {
        fn cb(p: ?[]const u8) M {
            return .{ .player = .{ .import_picked = p } };
        }
    }.cb;
}

fn importFolderFromFile(ctx: anytype, maybe_path: ?[]const u8) void {
    const dir = maybe_path orelse return;
    const global = ctx.global;
    global.setLastFolder(dir) catch return;

    scanDirRecursive(ctx, dir, 0) catch {};
}

fn scanDirRecursive(ctx: anytype, dir: []const u8, depth: u32) !void {
    if (depth > 6) return;
    const global = ctx.global;
    var d = std.Io.Dir.openDirAbsolute(ctx.app.io, dir, .{ .iterate = true }) catch return;
    defer d.close(ctx.app.io);
    var it = d.iterate();
    while (true) {
        const maybe = it.next(ctx.app.io) catch break;
        const entry = maybe orelse break;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const full = std.fs.path.join(ctx.runtime.allocator, &.{ dir, entry.name }) catch continue;
        defer ctx.runtime.allocator.free(full);
        switch (entry.kind) {
            .directory => scanDirRecursive(ctx, full, depth + 1) catch {},
            .file => {
                if (!isAudioExt(entry.name)) continue;
                _ = global.addSong(full, entry.name) catch {};
            },
            else => {},
        }
    }
}

fn isAudioExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp3", ".wav", ".flac", ".ogg", ".m4a" };
    for (exts) |ext| {
        if (name.len < ext.len) continue;
        const tail = name[name.len - ext.len ..];
        if (std.ascii.eqlIgnoreCase(tail, ext)) return true;
    }
    return false;
}
