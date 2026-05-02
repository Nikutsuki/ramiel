const std = @import("std");
const lib = @import("ramiel");
const core = @import("core.zig");

const filesystem = @import("filesystem/root.zig");

fn handleDrop(
    state: *core.AppState,
    target_id: []const u8,
    drop_pos: lib.components.tree.DropPosition,
) !void {
    const comp = lib.components;
    const dragged_id = state.tree_state.dragged_id orelse return;

    var drag_paths = std.ArrayList([]u8).empty;
    defer {
        for (drag_paths.items) |p| state.allocator.free(p);
        drag_paths.deinit(state.allocator);
    }

    if (state.tree_state.isSelected(dragged_id)) {
        var collected = std.ArrayList([]const u8).empty;
        defer collected.deinit(state.allocator);
        comp.tree.collectTopLevelSelectedIds(
            core.FsNode,
            state.allocator,
            state.root_node.children.items,
            &state.tree_state.selected_ids,
            &collected,
        ) catch {};
        for (collected.items) |id| {
            const dup = try state.allocator.dupe(u8, id);
            try drag_paths.append(state.allocator, dup);
        }
    }
    if (drag_paths.items.len == 0) {
        const dup = try state.allocator.dupe(u8, dragged_id);
        try drag_paths.append(state.allocator, dup);
    }

    const target_dir = if (drop_pos == .before or drop_pos == .after)
        std.fs.path.dirname(target_id) orelse target_id
    else
        target_id;
    const target_dir_dup = try state.allocator.dupe(u8, target_dir);
    defer state.allocator.free(target_dir_dup);

    var any_moved = false;
    for (drag_paths.items) |src| {
        const file_name = std.fs.path.basename(src);
        const dest = std.fs.path.join(state.allocator, &.{ target_dir_dup, file_name }) catch continue;
        defer state.allocator.free(dest);

        if (std.mem.eql(u8, src, dest)) {
            state.setStatus("'{s}' already in '{s}'", .{ file_name, target_dir_dup });
            continue;
        }
        if (std.mem.startsWith(u8, target_dir_dup, src)) {
            state.setStatus("Cannot move '{s}' into itself", .{file_name});
            continue;
        }
        if (!std.fs.path.isAbsolute(src) or !std.fs.path.isAbsolute(dest)) continue;

        std.Io.Dir.renameAbsolute(src, dest, state.io) catch |err| {
            std.log.err("Move failed for {s} -> {s}: {s}", .{ src, dest, @errorName(err) });
            state.setStatus("Move failed: {s}", .{@errorName(err)});
            continue;
        };
        any_moved = true;
    }

    if (any_moved) {
        try state.refreshSidebar();
    }
}

pub fn tick(app: *core.App) lib.UpdateAction {
    const ui = &app.ui;
    const state = &app.state;
    const comp = lib.components;
    if (ui.scrollChangedThisFrame()) {
        const tree_root_id = comp.deriveChildId(100, "root");
        if (ui.getById(tree_root_id)) |node| {
            state.sidebar_scroll_x = node.scroll_x;
            state.sidebar_scroll_y = node.scroll_y;
        }
    }
    return .none;
}

pub fn update(app: *core.App, msg: core.AppInteractionMessage) lib.UpdateAction {
    const allocator = app.allocator;
    const ui = &app.ui;
    const state = &app.state;
    const comp = lib.components;

    switch (msg.id) {
        .tree_msg => |t_msg| {
            switch (t_msg) {
                .toggle => |path| {
                    if (!state.tree_state.isExpanded(path)) {
                        if (filesystem.findFsNode(&state.root_node, path)) |node| {
                            if (node.is_group and !node.is_loaded) {
                                filesystem.loadDirectoryContents(state.fs_allocator, state.io, node) catch |err| {
                                    std.log.err("Failed to read directory {s}: {s}", .{ path, @errorName(err) });
                                };
                            }
                        }
                    }
                },
                .click => |c| {
                    if (filesystem.findFsNode(&state.root_node, c.id)) |node| {
                        if (node.is_group) {
                            if (!node.is_loaded) {
                                filesystem.loadDirectoryContents(state.fs_allocator, state.io, node) catch |err| {
                                    std.log.err("Failed to read directory {s}: {s}", .{ c.id, @errorName(err) });
                                };
                            }
                            state.navigateTo(node.id) catch |err| {
                                state.setStatus("Navigate failed: {s}", .{@errorName(err)});
                            };
                        }
                    }
                },
                .drop => |d| {
                    handleDrop(state, d.target_id, d.drop_pos) catch |err| {
                        std.log.err("Drop handler failed: {s}", .{@errorName(err)});
                    };
                    state.loadCurrentDir() catch {};
                },
                .drag_start, .drag_over, .tick => {},
            }

            comp.tree.update([]const u8, core.FsNode, &state.tree_state, state.root_node.children.items, t_msg) catch {};
            return .rebuild;
        },
        .tick => {
            comp.tree.update([]const u8, core.FsNode, &state.tree_state, state.root_node.children.items, .{
                .tick = ui.isDragging(),
            }) catch {};
            return .rebuild;
        },
        .navigate_to => |path| {
            state.navigateTo(path) catch |err| {
                state.setStatus("Navigate failed: {s}", .{@errorName(err)});
            };
            return .rebuild;
        },
        .navigate_back => {
            state.goBack() catch |err| {
                state.setStatus("Back failed: {s}", .{@errorName(err)});
            };
            return .rebuild;
        },
        .navigate_forward => {
            state.goForward() catch |err| {
                state.setStatus("Forward failed: {s}", .{@errorName(err)});
            };
            return .rebuild;
        },
        .navigate_up => {
            state.goUp() catch |err| {
                state.setStatus("Up failed: {s}", .{@errorName(err)});
            };
            return .rebuild;
        },
        .refresh => {
            state.refresh() catch |err| {
                state.setStatus("Refresh failed: {s}", .{@errorName(err)});
            };
            return .rebuild;
        },
        .new_folder => {
            const arena_alloc = state.dir_allocator;
            const new_path = filesystem.pickNewFolderName(arena_alloc, state.current_path, state.current_entries.items) catch |err| {
                state.setStatus("New folder failed: {s}", .{@errorName(err)});
                return .rebuild;
            };
            std.Io.Dir.createDirAbsolute(state.io, new_path, .default_dir) catch |err| {
                state.setStatus("Create dir failed: {s}", .{@errorName(err)});
                return .rebuild;
            };
            state.refresh() catch {};
            return .rebuild;
        },
        .delete_selected => {
            const target = state.selected_path orelse {
                state.setStatus("Nothing selected", .{});
                return .rebuild;
            };
            const owned = allocator.dupe(u8, target) catch return .rebuild;
            defer allocator.free(owned);

            filesystem.deleteAbsolute(state.io, owned) catch |err| {
                state.setStatus("Delete failed: {s}", .{@errorName(err)});
                return .rebuild;
            };
            state.refresh() catch {};
            return .rebuild;
        },
        .begin_path_edit => {
            state.editing_path = true;
            ui.requestFocus(core.NodeIds.path_input);
            return .rebuild;
        },
        .cancel_path_edit => {
            state.editing_path = false;
            return .rebuild;
        },
        .submit_path_edit => {
            const buf = ui.getInputText(core.NodeIds.path_input) orelse return .none;
            const trimmed = std.mem.trim(u8, buf, " \t\r\n\"'");
            if (trimmed.len == 0) {
                state.editing_path = false;
                return .rebuild;
            }
            const copy = allocator.dupe(u8, trimmed) catch return .rebuild;
            defer allocator.free(copy);
            state.editing_path = false;
            state.navigateTo(copy) catch |err| {
                state.setStatus("Cannot open '{s}': {s}", .{ copy, @errorName(err) });
            };
            return .rebuild;
        },
        .path_input_event => {
            if (msg.data == .key and msg.data.key.action == 1) {
                if (msg.data.key.key == 257 or msg.data.key.key == 335) {
                    return update(app, .{ .id = .{ .submit_path_edit = {} } });
                }
                if (msg.data.key.key == 256) {
                    state.editing_path = false;
                    return .rebuild;
                }
            }
            return .none;
        },
        .search_letter => |letter| {
            state.jumpToLetter(letter);
            return .rebuild;
        },
        .grid_click => |gc| {
            const already_selected = if (state.selected_path) |cur|
                std.mem.eql(u8, cur, gc.path)
            else
                false;

            if (already_selected) {
                if (gc.is_dir) {
                    state.navigateTo(gc.path) catch |err| {
                        state.setStatus("Open failed: {s}", .{@errorName(err)});
                    };
                } else {
                    state.selected_path = null;
                }
            } else {
                state.selected_path = gc.path;
            }
            return .rebuild;
        },
    }
    return .none;
}
