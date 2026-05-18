const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const tw = lib.tw;
const UpdateAction = lib.UpdateAction;

const AppMessage = enum(u8) {
    slider_drag,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const AppState = struct {
    font_data: *FontData = undefined,
    slider_value: f32 = 0.5,
};

const App = lib.Application(AppState, AppMessage);

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const font = state.font_data;

    const track_width: f32 = 420.0;
    const handle_diameter: f32 = 26.0;
    const max_handle_x: f32 = track_width - handle_diameter;
    const handle_x = std.math.clamp(state.slider_value, 0.0, 1.0) * max_handle_x;
    const value_text = try std.fmt.allocPrint(
        ui.build_arena.allocator(),
        "value = {d:.3} (drag handle outside track bounds)",
        .{state.slider_value},
    );

    const handle = try ui.ux().div(.{
        .style = tw.style(.{
            tw.absolute,
            .{ .left = handle_x, .top = -5.0 },
            tw.square(handle_diameter),
            tw.bg_value(.{ 0.30, 0.70, 1.0, 1.0 }),
            tw.rounded(handle_diameter / 2.0),
            tw.cursor_pointer,
        }),
        .events = &.{
            .{ .event = .drag, .msg = .slider_drag },
        },
    });

    const track = try ui.ux().div(.{
        .style = tw.style(.{
            tw.relative,
            tw.w(track_width),
            tw.h(16.0),
            tw.bg_value(.{ 0.20, 0.22, 0.30, 1.0 }),
            tw.rounded(8.0),
        }),
        .children = &.{handle},
    });

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.flex_col,
            tw.justify_center,
            tw.items_center,
            tw.gap_px(16.0),
            tw.bg_value(.{ 0.08, 0.09, 0.12, 1.0 }),
        }),
        .children = &.{
            try ui.ux().text(.{
                .content = "pointer capture demo",
                .font = font,
                .style = tw.style(.{tw.text_color_value(.{ 0.92, 0.95, 1.0, 1.0 })}),
            }),
            try ui.ux().text(.{
                .content = value_text,
                .font = font,
                .style = tw.style(.{tw.text_color_value(.{ 0.70, 0.76, 0.88, 1.0 })}),
            }),
            track,
        },
    });
}

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    switch (msg.id) {
        .slider_drag => {
            if (msg.data != .drag) return .none;
            const track_width: f32 = 420.0;
            const handle_diameter: f32 = 26.0;
            const max_handle_x: f32 = track_width - handle_diameter;
            if (max_handle_x <= 0.0) return .none;

            const value_per_px = 1.0 / max_handle_x;
            app.state.slider_value = std.math.clamp(
                app.state.slider_value + msg.data.drag.dx * value_per_px,
                0.0,
                1.0,
            );
            return .rebuild;
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var app = try App.init(
        rt.allocator(),
        io,
        .{ .title = "pointer capture demo" },
        AppState{},
        update,
    );
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    try app.setRootBuilder(build);
    try app.run();
}
