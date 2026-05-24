const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const tw = lib.tw;
const Msg = u32;
const T = lib.For(Msg);
const UI = T.UIContext;
const Node = T.Node;

const SIZE: u32 = 512;
const SIZE_F: f32 = 512;
const CYCLE_TICKS: u64 = 180;

const BG: [4]f32 = .{ 0.04, 0.04, 0.06, 1.0 };
const FG: [4]f32 = .{ 0.85, 0.88, 0.96, 1.0 };

const Effect = struct { name: []const u8, glsl: []const u8 };

const effects = [_]Effect{
    .{ .name = "Original", .glsl = @embedFile("shaders/original.comp") },
    .{ .name = "Grayscale", .glsl = @embedFile("shaders/grayscale.comp") },
    .{ .name = "Invert", .glsl = @embedFile("shaders/invert.comp") },
    .{ .name = "Ripple (animated)", .glsl = @embedFile("shaders/ripple.comp") },
    .{ .name = "Edge detect", .glsl = @embedFile("shaders/edge.comp") },
    .{ .name = "Chromatic (animated)", .glsl = @embedFile("shaders/chromatic.comp") },
};

const State = struct {
    font: ?*lib.FontData = null,
    canvas: ?*lib.Canvas = null,
    pixels: []u8 = &.{},
    effect: usize = 0,
    ticks: u64 = 0,
};

const App = lib.Application(State, Msg);

fn toByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0);
}

fn genInputImage(allocator: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    for (0..h) |y| {
        for (0..w) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(w));
            const fy = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(h));
            const cx = fx - 0.5;
            const cy = fy - 0.5;
            const r = @sqrt(cx * cx + cy * cy);
            const ring = 0.5 + 0.5 * @sin(r * 42.0);
            const checker: f32 = if ((x / 32 + y / 32) % 2 == 0) 1.0 else 0.55;
            const i = (y * w + x) * 4;
            pixels[i + 0] = toByte(ring * checker);
            pixels[i + 1] = toByte(fx * checker);
            pixels[i + 2] = toByte((1.0 - fy) * checker);
            pixels[i + 3] = 255;
        }
    }
    return pixels;
}

fn rebuildCanvas(app: *App) !void {
    if (app.state.canvas) |old| app.destroyCanvas(old);
    app.state.canvas = null;
    app.state.canvas = try app.createComputeCanvas(SIZE, SIZE, effects[app.state.effect].glsl, .{
        .pixels = app.state.pixels,
        .width = SIZE,
        .height = SIZE,
    });
}

fn build(ui: *UI, state: *const State) anyerror!*Node {
    const ux = ui.ux();
    return ux.div(.{
        .class = .{ tw.w_full, tw.h_full, tw.flex_col, tw.items_center, tw.justify_center, tw.bg_value(BG) },
        .children = &.{
            try ux.text(.{ .class = .{ tw.text_lg, tw.text_color_value(FG) }, .content = effects[state.effect].name, .font = state.font }),
            if (state.canvas) |canvas|
                try ux.canvas(.{ .class = .{ tw.w(SIZE_F), tw.h(SIZE_F), tw.rounded(12) }, .target = canvas })
            else
                try ux.div(.{ .class = .{ tw.w(SIZE_F), tw.h(SIZE_F) } }),
        },
    });
}

fn update(app: *App, msg: lib.InteractionMessage(Msg)) lib.UpdateAction {
    _ = app;
    _ = msg;
    return .none;
}

fn tick(app: *App) lib.UpdateAction {
    app.state.ticks += 1;
    if (app.state.ticks % CYCLE_TICKS != 0) return .repaint;
    app.state.effect = (app.state.effect + 1) % effects.len;
    rebuildCanvas(app) catch return .repaint;
    return .rebuild;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var app = try App.init(allocator, io, .{ .title = "shader effects" }, .{}, update);
    defer app.deinit();

    app.state.font = try app.loadDefaultFontFamily("JetBrains Mono", lib.assets.jetbrainsMonoSources(), 32);
    app.state.pixels = try genInputImage(allocator, SIZE, SIZE);
    defer allocator.free(app.state.pixels);

    try rebuildCanvas(&app);

    app.setTickFn(tick, 1.0 / 60.0);
    try app.setRootBuilder(build);
    try app.run();
}
