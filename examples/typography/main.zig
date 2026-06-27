//! Typography showcase: font weights, italic, underline / strikethrough /
//! overline, every decoration shape, decoration colors, and a hover-triggered
//! decoration-color transition. Run with `nix develop --command zig build
//! run-typography`.
const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const FontWeight = lib.FontWeight;
const FontStyle = lib.FontStyle;
const tw = lib.tw;
const Color = lib.layout.Color;
const UpdateAction = lib.UpdateAction;

const AppMessage = union(enum) {
    toggle_palette: void,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const AppState = struct {
    font_data: *FontData = undefined,
    palette: u8 = 0,
};

const App = lib.Application(AppState, AppMessage);

const BG = Color.from(.{ 0.07, 0.08, 0.11, 1.0 });
const PANEL_BG = Color.from(.{ 0.12, 0.13, 0.18, 1.0 });
const TEXT_MAIN = Color.from(.{ 0.93, 0.95, 0.98, 1.0 });
const TEXT_DIM = Color.from(.{ 0.60, 0.64, 0.72, 1.0 });
const TEXT_ACCENT = Color.from(.{ 0.55, 0.78, 1.00, 1.0 });
const COL_ERROR = Color.from(.{ 0.95, 0.40, 0.46, 1.0 });
const COL_WARN = Color.from(.{ 0.96, 0.78, 0.36, 1.0 });
const COL_HINT = Color.from(.{ 0.58, 0.76, 0.96, 1.0 });
const COL_OK = Color.from(.{ 0.46, 0.86, 0.62, 1.0 });

fn label(
    ui: *AppUIContext,
    _: *FontData,
    content: []const u8,
    label_color: Color,
) !*AppNode {
    return ui.ux().text(.{
        .content = content,
        .style = tw.style(.{ tw.text_color_value(label_color), tw.text_sm }),
    });
}

fn row(ui: *AppUIContext, children: anytype) !*AppNode {
    return ui.ux().div(.{
        .style = tw.style(.{ tw.flex_row, tw.items_center, tw.gap_px(16) }),
        .children = children,
    });
}

fn section(ui: *AppUIContext, font: *FontData, title: []const u8, body: []const ?*AppNode) !*AppNode {
    _ = font;
    const header = try ui.ux().text(.{
        .content = title,
        .style = tw.style(.{
            tw.text_color_value(TEXT_ACCENT),
            tw.text_base,
            tw.font_semibold,
            tw.underline,
            tw.decoration_color_value(TEXT_ACCENT),
        }),
    });

    const stack = try ui.ux().div(.{
        .style = tw.style(.{ tw.flex_col, tw.gap_px(8), tw.w_full }),
        .children = body,
    });

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.flex_col,
            tw.gap_px(12),
            tw.bg_value(PANEL_BG),
            tw.rounded(10),
            tw.p_px(20),
            tw.w_full,
        }),
        .children = &.{ header, stack },
    });
}

fn weightLine(ui: *AppUIContext, font: *FontData, name: []const u8, w: FontWeight) !*AppNode {
    const lbl = try label(ui, font, name, TEXT_DIM);
    const sample = try ui.ux().text(.{
        .content = "The quick brown fox jumps over the lazy dog 0123",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.weight(w),
        }),
    });
    return row(ui, &.{ lbl, sample });
}

fn styleLine(ui: *AppUIContext, font: *FontData, name: []const u8, w: FontWeight, s: FontStyle) !*AppNode {
    const lbl = try label(ui, font, name, TEXT_DIM);
    const sample = try ui.ux().text(.{
        .content = "fn main() { print(\"hello, world\"); }",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.weight(w),
            tw.font_style_value(s),
        }),
    });
    return row(ui, &.{ lbl, sample });
}

fn shapeLine(
    ui: *AppUIContext,
    font: *FontData,
    name: []const u8,
    shape: lib.TextDecorationShape,
    deco_color: Color,
) !*AppNode {
    const lbl = try label(ui, font, name, TEXT_DIM);
    const sample = try ui.ux().text(.{
        .content = "decorated text underlined like this",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.underline,
            tw.decoration_shape(shape),
            tw.decoration_color_value(deco_color),
            tw.decoration_thickness(2.0),
        }),
    });
    return row(ui, &.{ lbl, sample });
}

fn diagnosticLine(
    ui: *AppUIContext,
    font: *FontData,
    severity: []const u8,
    code: []const u8,
    shape: lib.TextDecorationShape,
    deco_color: Color,
) !*AppNode {
    _ = font;
    const sev = try ui.ux().text(.{
        .content = severity,
        .style = tw.style(.{
            tw.text_color_value(deco_color),
            tw.text_sm,
            tw.font_semibold,
            tw.w(72),
        }),
    });
    const snippet = try ui.ux().text(.{
        .content = code,
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.underline,
            tw.decoration_shape(shape),
            tw.decoration_color_value(deco_color),
            tw.decoration_thickness(2.0),
        }),
    });
    return row(ui, &.{ sev, snippet });
}

fn hoverPanel(ui: *AppUIContext, font: *FontData, palette: u8) !*AppNode {
    const colors_a: [3]Color = .{ COL_ERROR, COL_WARN, COL_HINT };
    const colors_b: [3]Color = .{ COL_OK, TEXT_ACCENT, COL_WARN };
    const palette_colors = if (palette == 0) colors_a else colors_b;
    const palette_name = if (palette == 0) "palette: red / amber / blue" else "palette: green / blue / amber";

    _ = font;
    const samples = try ui.build_arena.allocator().alloc(?*AppNode, 3);
    samples[0] = try ui.ux().text(.{
        .content = "error: undeclared identifier `foo`",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.underline,
            tw.decoration_wavy,
            tw.decoration_color_value(palette_colors[0]),
            tw.decoration_thickness(2.0),
            tw.transition_decoration_colors(350),
        }),
    });
    samples[1] = try ui.ux().text(.{
        .content = "warning: unused variable `bar`",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.underline,
            tw.decoration_dashed,
            tw.decoration_color_value(palette_colors[1]),
            tw.decoration_thickness(2.0),
            tw.transition_decoration_colors(350),
        }),
    });
    samples[2] = try ui.ux().text(.{
        .content = "hint: prefer `const` over `var` when not mutated",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_base,
            tw.underline,
            tw.decoration_dotted,
            tw.decoration_color_value(palette_colors[2]),
            tw.decoration_thickness(2.0),
            tw.transition_decoration_colors(350),
        }),
    });

    const palette_label = try ui.ux().text(.{
        .content = palette_name,
        .style = tw.style(.{ tw.text_color_value(TEXT_DIM), tw.text_sm, tw.italic }),
    });

    const stack = try ui.ux().div(.{
        .style = tw.style(.{ tw.flex_col, tw.gap_px(8), tw.w_full }),
        .children = samples,
    });

    const button = try ui.ux().button(.{
        .label = "Click to swap palette (transitions decoration_color)",
        .style = tw.style(.{ tw.rounded(6) }),
        .events = &.{.{ .event = .click, .msg = .{ .toggle_palette = {} } }},
    });

    return ui.ux().div(.{
        .style = tw.style(.{ tw.flex_col, tw.gap_px(12), tw.w_full }),
        .children = &.{ stack, palette_label, button },
    });
}

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const font = state.font_data;

    const weights_section = try section(ui, font, "font weights (real faces; bold/italic ship as separate TTFs)", &.{
        try weightLine(ui, font, ".thin       (100)", .thin),
        try weightLine(ui, font, ".extra_light(200)", .extra_light),
        try weightLine(ui, font, ".light      (300)", .light),
        try weightLine(ui, font, ".normal     (400)", .normal),
        try weightLine(ui, font, ".medium     (500)", .medium),
        try weightLine(ui, font, ".semibold   (600)", .semibold),
        try weightLine(ui, font, ".bold       (700)", .bold),
        try weightLine(ui, font, ".extra_bold (800)", .extra_bold),
        try weightLine(ui, font, ".black      (900)", .black),
    });

    const styles_section = try section(ui, font, "italic axis (real italic faces; closestVariant picks the right cell)", &.{
        try styleLine(ui, font, "regular        ", .normal, .normal),
        try styleLine(ui, font, "italic         ", .normal, .italic),
        try styleLine(ui, font, "bold           ", .bold, .normal),
        try styleLine(ui, font, "bold italic    ", .bold, .italic),
    });

    const shapes_section = try section(ui, font, "decoration shapes (solid + double via addRect; the rest via EFFECT_DECORATION_LINE)", &.{
        try shapeLine(ui, font, "solid  ", .solid, TEXT_ACCENT),
        try shapeLine(ui, font, "double ", .double, TEXT_ACCENT),
        try shapeLine(ui, font, "wavy   ", .wavy, COL_ERROR),
        try shapeLine(ui, font, "dotted ", .dotted, COL_HINT),
        try shapeLine(ui, font, "dashed ", .dashed, COL_WARN),
    });

    const lines_section = try section(ui, font, "line axes (underline / line_through / overline, plus combinations)", &.{
        try row(ui, &.{
            try label(ui, font, "underline      ", TEXT_DIM),
            try ui.ux().text(.{
                .content = "an ordinary underline",
                .style = tw.style(.{ tw.text_color_value(TEXT_MAIN), tw.text_base, tw.underline }),
            }),
        }),
        try row(ui, &.{
            try label(ui, font, "line_through   ", TEXT_DIM),
            try ui.ux().text(.{
                .content = "deprecated, do not use",
                .style = tw.style(.{ tw.text_color_value(TEXT_MAIN), tw.text_base, tw.line_through, tw.decoration_color_value(COL_ERROR) }),
            }),
        }),
        try row(ui, &.{
            try label(ui, font, "overline       ", TEXT_DIM),
            try ui.ux().text(.{
                .content = "header-style overline",
                .style = tw.style(.{ tw.text_color_value(TEXT_MAIN), tw.text_base, tw.overline, tw.decoration_color_value(COL_OK) }),
            }),
        }),
        try row(ui, &.{
            try label(ui, font, "all three      ", TEXT_DIM),
            try ui.ux().text(.{
                .content = "every line bit set on one node",
                .style = tw.style(.{
                    tw.text_color_value(TEXT_MAIN),
                    tw.text_base,
                    tw.underline,
                    tw.line_through,
                    tw.overline,
                    tw.decoration_color_value(TEXT_ACCENT),
                    tw.decoration_thickness(2.0),
                }),
            }),
        }),
    });

    const diagnostics_section = try section(ui, font, "LSP-style diagnostics (the forcing consumer for this feature)", &.{
        try diagnosticLine(ui, font, "error", "let x = foo();", .wavy, COL_ERROR),
        try diagnosticLine(ui, font, "warning", "let y = unused_var;", .wavy, COL_WARN),
        try diagnosticLine(ui, font, "hint", "let z: i32 = 5; // could be inferred", .dotted, COL_HINT),
        try diagnosticLine(ui, font, "ok", "let w = explicit_type();", .dashed, COL_OK),
    });

    const hover_section = try section(ui, font, "decoration_color transitions (uses TransitionProperty.text_decoration_color)", &.{
        try hoverPanel(ui, font, state.palette),
    });

    const title = try ui.ux().text(.{
        .content = "Ramiel typography showcase",
        .style = tw.style(.{
            tw.text_color_value(TEXT_MAIN),
            tw.text_3xl,
            tw.font_extrabold,
        }),
    });

    const subtitle = try ui.ux().text(.{
        .content = "weights, italic, underline, strikethrough, overline, shapes, colors, transitions",
        .style = tw.style(.{
            tw.text_color_value(TEXT_DIM),
            tw.text_base,
            tw.italic,
        }),
    });

    return ui.ux().div(.{
        .style = tw.style(.{
            tw.w_full,
            tw.h_full,
            tw.bg_value(BG),
            tw.flex_col,
            tw.gap_px(20),
            tw.p_px(28),
            tw.overflow_y_scroll,
        }),
        .children = &.{
            title,
            subtitle,
            weights_section,
            styles_section,
            shapes_section,
            lines_section,
            diagnostics_section,
            hover_section,
        },
    });
}

fn updateWithState(app: *App, msg: AppInteractionMessage) UpdateAction {
    switch (msg.id) {
        .toggle_palette => {
            app.state.palette ^= 1;
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
        .{ .title = "Ramiel: typography showcase" },
        AppState{},
        updateWithState,
    );
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFontFamily("JetBrains Mono", lib.assets.jetbrainsMonoSources(), 18);

    try app.setRootBuilder(build);
    try app.run();
}
