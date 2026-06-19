const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const tw = lib.tw;
const Msg = u32;
const T = lib.For(Msg);
const UI = T.UIContext;
const Node = T.Node;

const W: u32 = 1280;
const H: u32 = 720;

const State = struct {
    font: ?*lib.FontData = null,
    background: ?*lib.Canvas = null,
};

const App = lib.Application(State, Msg);

const swirl_glsl = @embedFile("shaders/swirl.frag");

fn build(ui: *UI, state: *const State) anyerror!*Node {
    const ux = ui.ux();
    const bg = state.background orelse return ux.divAny(.{ .class = .{ tw.w_full, tw.h_full } });
    return ux.canvasAny(.{
        .class = .{ tw.w_full, tw.h_full, tw.flex_col, tw.items_center, tw.justify_center },
        .target = bg,
        .children = &.{
            try ux.textAny(.{
                .class = .{ tw.text_lg, tw.text_color_value(lib.layout.Color.from(.{ 1.0, 1.0, 1.0, 1.0 })) },
                .content = "fragment shader background",
                .font = state.font,
            }),
        },
    });
}

fn update(app: *App, msg: lib.InteractionMessage(Msg)) lib.UpdateAction {
    _ = app;
    _ = msg;
    return .none;
}

fn tick(app: *App) lib.UpdateAction {
    const fb = app.getFramebufferSize();
    if (app.state.background) |bg| {
        if (fb.width > 0 and fb.height > 0) {
            app.resizeShaderCanvas(bg, @intCast(fb.width), @intCast(fb.height)) catch {};
        }
    }
    return .repaint;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var app = try App.init(allocator, io, .{ .title = "shader background", .width = W, .height = H }, .{}, update);
    defer app.deinit();

    app.state.font = try app.loadDefaultFontFamily("JetBrains Mono", lib.assets.jetbrainsMonoSources(), 32);
    app.state.background = try app.createShaderCanvas(W, H, swirl_glsl, null);

    app.setTickFn(tick, 1.0 / 60.0);
    try app.setRootBuilder(build);
    try app.run();
}
