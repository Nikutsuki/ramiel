const std = @import("std");
const lib = @import("ramiel");

const core = @import("core.zig");
const update = @import("update.zig");
const root = @import("ui/root.zig");

const filesystem = @import("filesystem/root.zig");

const asset_manifest = std.EnumArray(core.AppAssets, lib.assets.StaticAsset).init(.{
    .file_open = .{
        .name = "file_open.svg",
        .payload = .{ .icon_svg = .{ .bytes = @embedFile("ui/icons/file_open.svg"), .width = 24, .height = 24, .scale = 2 } },
    },
    .folder = .{
        .name = "folder.svg",
        .payload = .{ .icon_svg = .{ .bytes = @embedFile("ui/icons/folder.svg"), .width = 24, .height = 24, .scale = 2 } },
    },
});

fn letterShortcut(
    state: *core.AppState,
    ir: *lib.For(core.AppMessage).InteractionRegistry,
    key: i32,
    action: i32,
    _: *const lib.WindowContext,
) bool {
    if (action != 1) return false;
    if (state.editing_path) return false;

    if (key >= 65 and key <= 90) {
        const codepoint: u21 = @intCast(key + 32);
        ir.postExternalMessage(.{ .id = .{ .search_letter = codepoint } });
        return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    const io = init.io;

    var state = try core.AppState.init(allocator, io);
    errdefer state.deinit();

    try filesystem.loadDirectoryContents(state.fs_allocator, io, &state.root_node);
    try state.loadCurrentDir();

    var app = try core.App.init(
        allocator,
        io,
        .{ .title = "File Explorer" },
        state,
        update.update,
    );
    defer app.state.deinit();
    defer app.deinit();
    app.tick_fn = update.tick;

    const theme = lib.Theme.fromOklch(.{ .l = 0.68, .c = 0.18, .h = 235.0 }, .dark);
    app.updateTheme(theme);

    try app.loadStaticAssets(core.AppAssets, asset_manifest);

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 14);

    app.setShortcutHandler(core.AppState, &app.state, letterShortcut);

    try app.setRootBuilder(root.build);

    try app.run();
}
