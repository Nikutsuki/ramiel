const std = @import("std");
const lib = @import("ramiel");

const core = @import("core.zig");
const worker_pool = @import("worker.zig");
const updater = @import("update.zig");
const ui_root = @import("ui/root.zig");
const EditorState = @import("editor_state.zig").EditorState;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var app = try core.App.init(
        allocator,
        io,
        .{ .title = "canvas app" },
        .{},
        updater.update,
    );
    defer app.deinit();
    var prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(init.io, std.Io.Clock.awake).toMilliseconds()));
    const rand = prng.random();
    const random_theme = lib.Theme.initRandom(rand, true);
    app.updateTheme(random_theme);

    app.state.editor = EditorState.init(allocator);
    defer app.state.editor.deinit();

    _ = try app.loadFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);
    app.state.font_data = try app.loadFont("Minecraft", .{ .path = "examples/canvas_app/ui/fonts/Minecraft.ttf" }, 32);

    const worker = try worker_pool.FilterWorkerPool.init(allocator, &app);
    defer worker.deinit();
    app.state.worker = @ptrCast(worker);

    const initial_buffer = try core.PixelBuffer.initBlank(allocator, 640, 420);
    const initial_base = try initial_buffer.clone();
    const initial_preview = try initial_buffer.clone();
    const picker_buf = try core.PixelBuffer.initBlank(allocator, 200, 200);
    app.state.base_canvas = try app.createCanvasFromBuffer(initial_buffer);
    errdefer if (app.state.base_canvas) |canvas| app.destroyCanvas(canvas);
    const preview_canvas_buf = try initial_preview.clone();
    app.state.preview_canvas = try app.createCanvasFromBuffer(preview_canvas_buf);
    errdefer if (app.state.preview_canvas) |canvas| app.destroyCanvas(canvas);
    app.state.color_picker_canvas = try app.createCanvasFromBuffer(picker_buf);
    errdefer if (app.state.color_picker_canvas) |canvas| app.destroyCanvas(canvas);
    if (app.state.color_picker_canvas) |picker_canvas| {
        lib.components.updateColorPickerPlaneTexture(picker_canvas, 0.0);
    }
    app.state.editor.setBaseBuffer(initial_base);
    app.state.editor.setPreviewBuffer(initial_preview);

    app.setShortcutHandler(core.AppState, &app.state, updater.appShortcutHandler);

    try app.setRootBuilder(ui_root.build);
    try app.run();
}
