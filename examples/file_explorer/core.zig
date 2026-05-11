const std = @import("std");
const lib = @import("ramiel");

pub const UIContext = lib.UIContext;
pub const Node = lib.Node;
pub const InteractionMessage = lib.InteractionMessage;
pub const FontData = lib.FontData;
pub const Application = lib.Application;
pub const NodeId = lib.NodeId;
pub const UpdateAction = lib.UpdateAction;
pub const Color = lib.Color;
pub const components = lib.components;
pub const Style = lib.Style;
pub const layout = lib.layout;
pub const tw = lib.tw;

const comp = lib.components;

pub const GridClick = struct {
    path: []const u8,
    is_dir: bool,
};

pub const AppMessage = union(enum) {
    tree_msg: comp.TreeMessage([]const u8),
    tick: void,

    navigate_to: []const u8,
    navigate_back: void,
    navigate_forward: void,
    navigate_up: void,
    refresh: void,

    grid_click: GridClick,

    new_folder: void,
    delete_selected: void,

    begin_path_edit: void,
    submit_path_edit: void,
    cancel_path_edit: void,
    path_input_event: void,

    search_letter: u21,
};

pub const NodeIds = lib.declareIds("examples.file_explorer", .{
    "path_input",
    "grid_root",
    "grid_entry",
    "sidebar_tree",
}){};

const T = lib.For(AppMessage);
pub const AppUIContext = T.UIContext;
pub const AppInteractionMessage = T.InteractionMessage;
pub const AppNode = T.Node;

pub const AppAssets = enum {
    file_open,
    folder,
};

pub const FsNode = struct {
    id: []const u8,
    name: []const u8,
    is_group: bool,
    is_loaded: bool = false,
    children: std.ArrayList(FsNode),

    pub fn deinit(self: *FsNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

pub const FsEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    fs_arena: *std.heap.ArenaAllocator,
    fs_allocator: std.mem.Allocator,
    tree_state: comp.tree.TreeState([]const u8),
    root_node: FsNode,

    dir_arena: *std.heap.ArenaAllocator,
    dir_allocator: std.mem.Allocator,
    current_path: []const u8, // owned by allocator; stable across reloads
    current_entries: std.ArrayList(FsEntry),
    selected_path: ?[]const u8 = null, // borrowed from dir_arena

    back_stack: std.ArrayList([]const u8),
    forward_stack: std.ArrayList([]const u8),

    status: []u8 = &.{},

    sidebar_scroll_x: f32 = 0.0,
    sidebar_scroll_y: f32 = 0.0,

    editing_path: bool = false,

    font_data: *FontData = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        const fs_arena = try allocator.create(std.heap.ArenaAllocator);
        fs_arena.* = std.heap.ArenaAllocator.init(allocator);
        const fs_alloc = fs_arena.allocator();

        const dir_arena = try allocator.create(std.heap.ArenaAllocator);
        dir_arena.* = std.heap.ArenaAllocator.init(allocator);
        const dir_alloc = dir_arena.allocator();

        const tree_state = comp.tree.TreeState([]const u8).init(allocator);

        const cwd_path = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", fs_alloc);

        const root_node = FsNode{
            .id = cwd_path,
            .name = try fs_alloc.dupe(u8, "Root"),
            .is_group = true,
            .is_loaded = false,
            .children = std.ArrayList(FsNode).empty,
        };

        const owned_current_path = try allocator.dupe(u8, cwd_path);

        return AppState{
            .allocator = allocator,
            .io = io,
            .fs_arena = fs_arena,
            .fs_allocator = fs_alloc,
            .tree_state = tree_state,
            .root_node = root_node,
            .dir_arena = dir_arena,
            .dir_allocator = dir_alloc,
            .current_path = owned_current_path,
            .current_entries = std.ArrayList(FsEntry).empty,
            .back_stack = std.ArrayList([]const u8).empty,
            .forward_stack = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.tree_state.deinit();
        self.root_node.deinit(self.fs_allocator);
        self.fs_arena.deinit();
        self.allocator.destroy(self.fs_arena);

        self.dir_arena.deinit();
        self.allocator.destroy(self.dir_arena);
        self.current_entries.deinit(self.allocator);

        for (self.back_stack.items) |p| self.allocator.free(p);
        self.back_stack.deinit(self.allocator);
        for (self.forward_stack.items) |p| self.allocator.free(p);
        self.forward_stack.deinit(self.allocator);

        self.allocator.free(self.current_path);
        if (self.status.len > 0) self.allocator.free(self.status);
    }

    pub fn setStatus(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        if (self.status.len > 0) self.allocator.free(self.status);
        self.status = std.fmt.allocPrint(self.allocator, fmt, args) catch &.{};
    }

    pub fn clearStatus(self: *AppState) void {
        if (self.status.len > 0) {
            self.allocator.free(self.status);
            self.status = &.{};
        }
    }

    pub fn loadCurrentDir(self: *AppState) !void {
        _ = self.dir_arena.reset(.retain_capacity);
        self.current_entries.clearRetainingCapacity();
        self.selected_path = null;

        var dir = std.Io.Dir.openDirAbsolute(self.io, self.current_path, .{ .iterate = true }) catch |err| {
            self.setStatus("Cannot open '{s}': {s}", .{ self.current_path, @errorName(err) });
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const name_dup = try self.dir_allocator.dupe(u8, entry.name);
            const path_dup = try std.fs.path.join(self.dir_allocator, &.{ self.current_path, name_dup });
            try self.current_entries.append(self.allocator, .{
                .name = name_dup,
                .path = path_dup,
                .is_dir = entry.kind == .directory,
            });
        }

        std.mem.sort(FsEntry, self.current_entries.items, {}, struct {
            fn lt(_: void, a: FsEntry, b: FsEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt);

        self.clearStatus();
    }

    pub fn navigateTo(self: *AppState, target: []const u8) !void {
        if (std.mem.eql(u8, target, self.current_path)) return;
        const owned = try self.allocator.dupe(u8, target);
        errdefer self.allocator.free(owned);

        try self.back_stack.append(self.allocator, self.current_path);
        self.current_path = owned;

        for (self.forward_stack.items) |p| self.allocator.free(p);
        self.forward_stack.clearRetainingCapacity();

        try self.loadCurrentDir();
        self.syncSidebar(self.current_path) catch {};
    }

    pub fn goBack(self: *AppState) !void {
        if (self.back_stack.items.len == 0) return;
        const prev = self.back_stack.pop() orelse return;
        try self.forward_stack.append(self.allocator, self.current_path);
        self.current_path = prev;
        try self.loadCurrentDir();
        self.syncSidebar(self.current_path) catch {};
    }

    pub fn goForward(self: *AppState) !void {
        if (self.forward_stack.items.len == 0) return;
        const next_path = self.forward_stack.pop() orelse return;
        try self.back_stack.append(self.allocator, self.current_path);
        self.current_path = next_path;
        try self.loadCurrentDir();
        self.syncSidebar(self.current_path) catch {};
    }

    pub fn goUp(self: *AppState) !void {
        const parent = std.fs.path.dirname(self.current_path) orelse return;
        if (std.mem.eql(u8, parent, self.current_path)) return;
        try self.navigateTo(parent);
    }

    pub fn refresh(self: *AppState) !void {
        try self.loadCurrentDir();
    }

    pub fn refreshSidebar(self: *AppState) !void {
        const filesystem = @import("filesystem/root.zig");

        var expanded_snapshot = std.ArrayList([]u8).empty;
        defer {
            for (expanded_snapshot.items) |p| self.allocator.free(p);
            expanded_snapshot.deinit(self.allocator);
        }
        var it = self.tree_state.expanded_ids.iterator();
        while (it.next()) |entry| {
            const dup = try self.allocator.dupe(u8, entry.key_ptr.*);
            try expanded_snapshot.append(self.allocator, dup);
        }

        self.tree_state.clearExpanded();
        self.tree_state.clearSelection();
        self.tree_state.dragged_id = null;
        self.tree_state.drag_pos = null;
        self.tree_state.drop_target_id = null;
        self.tree_state.drop_target_pos = null;

        const root_path_dup = try self.allocator.dupe(u8, self.root_node.id);
        defer self.allocator.free(root_path_dup);

        _ = self.fs_arena.reset(.retain_capacity);
        self.root_node = .{
            .id = try self.fs_allocator.dupe(u8, root_path_dup),
            .name = try self.fs_allocator.dupe(u8, "Root"),
            .is_group = true,
            .is_loaded = false,
            .children = std.ArrayList(FsNode).empty,
        };
        try filesystem.loadDirectoryContents(self.fs_allocator, self.io, &self.root_node);

        for (expanded_snapshot.items) |p| {
            self.syncSidebar(p) catch {};
        }
    }

    pub fn syncSidebar(self: *AppState, target: []const u8) !void {
        const filesystem = @import("filesystem/root.zig");
        const root_path = self.root_node.id;
        if (!std.mem.startsWith(u8, target, root_path)) return;

        var i = root_path.len;
        var node: *FsNode = &self.root_node;
        while (true) {
            if (node.is_group and !node.is_loaded) {
                filesystem.loadDirectoryContents(self.fs_allocator, self.io, node) catch {};
            }

            while (i < target.len and (target[i] == '/' or target[i] == '\\')) : (i += 1) {}
            if (i >= target.len) break;

            const seg_start = i;
            while (i < target.len and target[i] != '/' and target[i] != '\\') : (i += 1) {}
            if (seg_start == i) break;

            const prefix = target[0..i];
            const child = blk: {
                for (node.children.items) |*c| {
                    if (std.mem.eql(u8, c.id, prefix)) break :blk c;
                }
                break :blk null;
            };
            if (child) |c| {
                try self.tree_state.setExpanded(prefix, true);
                node = c;
            } else break;
        }

        try self.tree_state.selectOnly(target);
    }

    pub fn jumpToLetter(self: *AppState, letter: u21) void {
        if (letter > 127) return;
        const target = std.ascii.toLower(@intCast(letter));
        for (self.current_entries.items) |e| {
            if (e.name.len == 0) continue;
            if (std.ascii.toLower(e.name[0]) == target) {
                self.selected_path = e.path;
                return;
            }
        }
    }
};

pub const App = lib.Application(AppState, AppMessage);
