const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const tw = lib.tw;
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
        .style = tw.style(.{
            tw.box_border,
            tw.w(PANEL_WIDTH),
            tw.flex_col,
            tw.p_px(PADDING),
            tw.bg_value(PANEL_BG),
            tw.rounded(8),
            tw.gap_px(12),
        }),
        .children = &.{
            try ui.ux().div(.{
                .style = tw.style(.{
                    tw.w_full,
                    tw.h(6),
                    tw.bg_value(INNER_COLOR),
                    tw.rounded(3),
                }),
            }),
            try ui.ux().text(.{ .content = bb_label, .font = font, .style = tw.style(.{tw.text_color_value(LABEL_COLOR)}) }),
            try ui.ux().text(.{
                .content = "The blue bar fills\nthe content area\n(outer − padding).",
                .font = font,
                .style = tw.style(.{tw.text_color_value(DIM_COLOR)}),
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
        .style = tw.style(.{
            tw.box_content,
            tw.w(PANEL_WIDTH),
            tw.flex_col,
            tw.p_px(PADDING),
            tw.bg_value(PANEL_BG),
            tw.rounded(8),
            tw.gap_px(12),
        }),
        .children = &.{
            try ui.ux().div(.{
                .style = tw.style(.{
                    tw.w_full,
                    tw.h(6),
                    tw.bg_value(INNER_COLOR),
                    tw.rounded(3),
                }),
            }),
            try ui.ux().text(.{ .content = cb_label, .font = font, .style = tw.style(.{tw.text_color_value(LABEL_COLOR)}) }),
            try ui.ux().text(.{
                .content = "The stated 300 px is\nthe content, not the\nouter box.",
                .font = font,
                .style = tw.style(.{tw.text_color_value(DIM_COLOR)}),
            }),
        },
    });

    const title = try ui.ux().text(.{
        .content = "box-sizing demo",
        .font = font,
        .style = tw.style(.{tw.text_color_value(.{ 1.0, 1.0, 1.0, 1.0 })}),
    });

    const subtitle = try ui.ux().text(.{
        .content = "Both panels use width = 300 px and padding = 20 px.\nborder_box: outer stays at 300 px.  content_box: outer grows to 340 px.",
        .font = font,
        .style = tw.style(.{tw.text_color_value(DIM_COLOR)}),
    });

    const panels_row = try ui.ux().div(.{
        .style = tw.style(.{ tw.flex_row, tw.gap_px(32), tw.items_start }),
        .children = &.{ border_box_panel, content_box_panel },
    });

    return try ui.ux().div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.flex_col,
            tw.items_center,
            tw.justify_center,
            tw.gap_px(24),
            tw.bg_value(.{ 0.09, 0.10, 0.14, 1.0 }),
        }),
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
