const std = @import("std");
const lib = @import("ramiel");

const tw = lib.tw;
const comp = lib.components;

const AppMessage = union(enum) {
    tree_msg: comp.TreeMessage([]const u8),
    tick: void,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const App = lib.Application(AppState, AppMessage);

const NodeIds = lib.declareIds("examples.tree", .{
    "tree",
}){};

const TreeItemData = struct {
    id: []const u8,
    label: []const u8,
    is_group: bool = false,
    children: std.ArrayList(TreeItemData) = std.ArrayList(TreeItemData).empty,

    fn deinit(self: *TreeItemData, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

const AppState = struct {
    allocator: std.mem.Allocator,
    font_data: *lib.FontData = undefined,
    root_items: std.ArrayList(TreeItemData),
    tree_state: comp.tree.TreeState([]const u8),

    pub fn init(allocator: std.mem.Allocator) AppState {
        var root_items = std.ArrayList(TreeItemData).empty;

        var folder1 = TreeItemData{ .id = "folder1", .label = "Documents", .is_group = true, .children = std.ArrayList(TreeItemData).empty };
        folder1.children.append(allocator, .{ .id = "file1", .label = "Resume.pdf" }) catch unreachable;
        folder1.children.append(allocator, .{ .id = "file2", .label = "Budget.xlsx" }) catch unreachable;

        var folder2 = TreeItemData{ .id = "folder2", .label = "Pictures", .is_group = true, .children = std.ArrayList(TreeItemData).empty };
        folder2.children.append(allocator, .{ .id = "img1", .label = "Vacation.jpg" }) catch unreachable;

        root_items.append(allocator, folder1) catch unreachable;
        root_items.append(allocator, folder2) catch unreachable;
        root_items.append(allocator, .{ .id = "file3", .label = "Notes.txt" }) catch unreachable;

        var tree_state = comp.tree.TreeState([]const u8).init(allocator);
        tree_state.setExpanded("folder1", true) catch unreachable;

        return .{
            .allocator = allocator,
            .root_items = root_items,
            .tree_state = tree_state,
        };
    }

    pub fn deinit(self: *AppState) void {
        for (self.root_items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.root_items.deinit(self.allocator);
        self.tree_state.deinit();
    }
};

fn build(ctx: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const components = ctx.components();

    const tree_node = try components.treeFromSource(.{
        .state = &state.tree_state,
        .root_items = state.root_items.items,
        .logic = comp.TreeSourceLogic(AppMessage){
            .base_id = NodeIds.tree,
            .build_row_content = buildRowContent,
            .wrap_message = struct {
                fn wrap(msg: comp.TreeMessage([]const u8)) AppMessage {
                    return .{ .tree_msg = msg };
                }
            }.wrap,
            .userdata = @as(?*const anyopaque, @ptrCast(@constCast(state))),
        },
        .visuals = comp.TreeDescriptor{
            .style = tw.style(.{ tw.w_full, tw.h_full, tw.p(2) }),
            .row_style = tw.style(.{ tw.px(2), tw.py(1), tw.pl(1.5), tw.rounded(4.0) }),
            .active_row_color = .{ 0.17, 0.45, 0.95, 0.22 },
            .hover_row_color = .{ 0.3, 0.4, 0.55, 0.14 },
        },
    });

    return tree_node;
}

fn buildRowContent(ctx: *AppUIContext, item: comp.TreeItem, userdata: ?*const anyopaque) anyerror!*AppNode {
    const state: *const AppState = @ptrCast(@alignCast(userdata.?));

    const label = findLabel(state.root_items.items, item.id) orelse "Unknown";

    return ctx.ux().text(.{
        .id = null,
        .content = label,
        .font = state.font_data,
        .style = .{
            .pointer_events = .none,
            .text_color = if (item.is_selected)
                @as([4]f32, .{ 1.0, 1.0, 1.0, 1.0 })
            else
                @as([4]f32, .{ 0.92, 0.95, 0.98, 1.0 }),
        },
    });
}

fn findLabel(items: []const TreeItemData, id: []const u8) ?[]const u8 {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, id)) return item.label;
        if (item.is_group) {
            if (findLabel(item.children.items, id)) |l| return l;
        }
    }
    return null;
}

fn update(app: *App, msg: T.InteractionMessage) lib.UpdateAction {
    const state = &app.state;
    switch (msg.id) {
        .tree_msg => |t_msg| {
            switch (t_msg) {
                .drop => |d| {
                    _ = comp.tree.applyDropMessage(
                        TreeItemData,
                        state.allocator,
                        &state.tree_state,
                        &state.root_items,
                        d.target_id,
                        d.drop_pos,
                        .{},
                    ) catch |err| {
                        std.log.err("Move failed: {s}", .{@errorName(err)});
                    };
                },
                else => {},
            }

            comp.tree.update([]const u8, TreeItemData, &state.tree_state, state.root_items.items, t_msg) catch {};

            return .rebuild;
        },
        .tick => {
            comp.tree.update([]const u8, TreeItemData, &state.tree_state, state.root_items.items, .{
                .tick = app.ui.isDragging(),
            }) catch {};
            return .rebuild;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    const io = init.io;

    var app = try App.init(
        allocator,
        io,
        .{ .title = "Tree Component Demo" },
        AppState.init(allocator),
        update,
    );
    defer app.state.deinit();
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 14);

    try app.setRootBuilder(build);

    try app.run();
}
