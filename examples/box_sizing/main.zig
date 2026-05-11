const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const layout = lib.layout;
const Style = layout.Style;
const Spacing = layout.Spacing;
const Size = layout.Size;
const BoxSizing = lib.BoxSizing;
const UpdateAction = lib.UpdateAction;
const AppMessage = u32;
const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const AppState = struct {
    font_data: *FontData = undefined,
};

const App = lib.Application(AppState, AppMessage);

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const font = state.font_data;

    const PANEL_WIDTH: f32 = 300;
    const PADDING: f32 = 20;
    const PANEL_BG: [4]f32 = .{ 0.18, 0.20, 0.28, 1.0 };
    const INNER_COLOR: [4]f32 = .{ 0.25, 0.55, 0.90, 1.0 };
    const LABEL_COLOR: [4]f32 = .{ 0.85, 0.90, 1.00, 1.0 };
    const DIM_COLOR: [4]f32 = .{ 0.60, 0.65, 0.78, 1.0 };

    const bb_outer_w: f32 = PANEL_WIDTH;
    const bb_content_w: f32 = bb_outer_w - PADDING * 2;

    const bb_label = try std.fmt.allocPrint(
        ui.build_arena.allocator(),
        "border_box (default)\nouter  = {d:.0} px\npadding = {d:.0} px each\ncontent = {d:.0} px",
        .{ bb_outer_w, PADDING, bb_content_w },
    );

    const border_box_panel = try ui.ux().div(.{
        .style = .{
            .box_sizing = .border_box,
            .width = .{ .exact = PANEL_WIDTH },
            .direction = .Column,
            .padding = Spacing.all(PADDING),
            .background_color = PANEL_BG,
            .corner_radius = layout.CornerRadius.all(8),
            .gap = 12,
        },
        .children = &.{
            try ui.ux().div(.{
                .style = .{
                    .width = .Full,
                    .height = .{ .exact = 6 },
                    .background_color = INNER_COLOR,
                    .corner_radius = layout.CornerRadius.all(3),
                },
            }),
            try ui.ux().text(.{ .content = bb_label, .font = font, .style = .{ .text_color = LABEL_COLOR } }),
            try ui.ux().text(.{
                .content = "The blue bar fills\nthe content area\n(outer − padding).",
                .font = font,
                .style = .{ .text_color = DIM_COLOR },
            }),
        },
    });

    const cb_content_w: f32 = PANEL_WIDTH;
    const cb_outer_w: f32 = cb_content_w + PADDING * 2;

    const cb_label = try std.fmt.allocPrint(
        ui.build_arena.allocator(),
        "content_box\nouter  = {d:.0} px\npadding = {d:.0} px each\ncontent = {d:.0} px",
        .{ cb_outer_w, PADDING, cb_content_w },
    );

    const content_box_panel = try ui.ux().div(.{
        .style = .{
            .box_sizing = .content_box,
            .width = .{ .exact = PANEL_WIDTH },
            .direction = .Column,
            .padding = Spacing.all(PADDING),
            .background_color = PANEL_BG,
            .corner_radius = layout.CornerRadius.all(8),
            .gap = 12,
        },
        .children = &.{
            try ui.ux().div(.{
                .style = .{
                    .width = .Full,
                    .height = .{ .exact = 6 },
                    .background_color = INNER_COLOR,
                    .corner_radius = layout.CornerRadius.all(3),
                },
            }),
            try ui.ux().text(.{ .content = cb_label, .font = font, .style = .{ .text_color = LABEL_COLOR } }),
            try ui.ux().text(.{
                .content = "The stated 300 px is\nthe content, not the\nouter box.",
                .font = font,
                .style = .{ .text_color = DIM_COLOR },
            }),
        },
    });

    const title = try ui.ux().text(.{
        .content = "box-sizing demo",
        .font = font,
        .style = .{
            .text_color = .{ 1.0, 1.0, 1.0, 1.0 },
        },
    });

    const subtitle = try ui.ux().text(.{
        .content = "Both panels use width = 300 px and padding = 20 px.\nborder_box: outer stays at 300 px.  content_box: outer grows to 340 px.",
        .font = font,
        .style = .{
            .text_color = DIM_COLOR,
        },
    });

    const panels_row = try ui.ux().div(.{
        .style = .{
            .direction = .Row,
            .gap = 32,
            .align_items = .Start,
        },
        .children = &.{ border_box_panel, content_box_panel },
    });

    return try ui.ux().div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .direction = .Column,
            .align_items = .Center,
            .justify_content = .Center,
            .gap = 24,
            .background_color = .{ 0.09, 0.10, 0.14, 1.0 },
        },
        .children = &.{ title, subtitle, panels_row },
    });
}

fn update(_: *App, _: AppInteractionMessage) UpdateAction {
    return .none;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var app = try App.init(rt.allocator(), io, .{ .title = "box-sizing demo" }, AppState{}, update);
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    try app.setRootBuilder(build);
    try app.run();
}
