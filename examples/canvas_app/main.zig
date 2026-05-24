const std = @import("std");
const lib = @import("ramiel");

const core = @import("core.zig");
const worker_pool = @import("worker.zig");
const updater = @import("update.zig");
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
        try core.Managed.initState(allocator),
        core.Managed.update,
    );
    defer app.deinit();
    defer core.Managed.deinitState(&app.state);
    const state = &app.state.pages.canvas;

    var prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(init.io, std.Io.Clock.awake).toMilliseconds()));
    const rand = prng.random();
    const random_theme = lib.Theme.initRandom(rand, true);
    app.updateTheme(random_theme);

    state.editor = EditorState.init(allocator);
    defer state.editor.deinit();

    _ = try app.loadDefaultFontFamily("JetBrains Mono", lib.assets.jetbrainsMonoSources(), 32);
    state.runtime.font_data = try app.loadFont("Minecraft", .{ .path = "examples/canvas_app/ui/fonts/Minecraft.ttf" }, 32);

    const worker = try worker_pool.FilterWorkerPool.init(allocator, &app);
    defer worker.deinit();
    state.runtime.worker = @ptrCast(worker);

    const initial_buffer = try core.PixelBuffer.initBlank(allocator, 640, 420);
    const initial_base = try initial_buffer.clone();
    const initial_preview = try initial_buffer.clone();
    const picker_buf = try core.PixelBuffer.initBlank(allocator, 200, 200);
    state.runtime.base_canvas = try app.createCanvasFromBuffer(initial_buffer);
    errdefer if (state.runtime.base_canvas) |canvas| app.destroyCanvas(canvas);
    const preview_canvas_buf = try initial_preview.clone();
    state.runtime.preview_canvas = try app.createCanvasFromBuffer(preview_canvas_buf);
    errdefer if (state.runtime.preview_canvas) |canvas| app.destroyCanvas(canvas);
    state.runtime.color_picker_canvas = try app.createCanvasFromBuffer(picker_buf);
    errdefer if (state.runtime.color_picker_canvas) |canvas| app.destroyCanvas(canvas);
    if (state.runtime.color_picker_canvas) |picker_canvas| {
        lib.components.updateColorPickerPlaneTexture(picker_canvas, 0.0);
    }
    state.editor.setBaseBuffer(initial_base);
    state.editor.setPreviewBuffer(initial_preview);

    app.setShortcutHandler(core.AppState, state, updater.appShortcutHandler);

    try app.setRootBuilder(core.Managed.build);
    try app.run();
}
