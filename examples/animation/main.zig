const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const layout = lib.layout;
const Style = layout.Style;
const Spacing = layout.Spacing;
const Size = layout.Size;
const NodeId = lib.NodeId;
const UpdateAction = lib.UpdateAction;
const TransitionStyle = lib.TransitionStyle;
const TransitionProperty = lib.TransitionProperty;
const EasingFunction = lib.EasingFunction;
const AnimationEntry = lib.AnimationEntry;
const AnimatedValue = lib.AnimatedValue;
const AppMessage = u32;
const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;
const EventBinding = T.EventBinding;

const Id = lib.declareIds("examples.animation", .{
    "hover_color",
    "hover_scale",
    "hover_both",
    "toggle_color",
    "toggle_opacity",
    "toggle_radius",
    "spinner",
}){};

const Msg = struct {
    const hover_color_enter: u32 = 1;
    const hover_color_exit: u32 = 2;
    const hover_scale_enter: u32 = 3;
    const hover_scale_exit: u32 = 4;
    const hover_both_enter: u32 = 5;
    const hover_both_exit: u32 = 6;
    const toggle_color_click: u32 = 7;
    const toggle_opacity_click: u32 = 8;
    const toggle_radius_click: u32 = 9;
};

const AppState = struct {
    font_data: *FontData = undefined,
    hover_color: bool = false,
    hover_scale: bool = false,
    hover_both: bool = false,
    color_on: bool = false,
    opacity_on: bool = false,
    radius_on: bool = false,
};

const App = lib.Application(AppState, AppMessage);

const BG: [4]f32 = .{ 0.07, 0.08, 0.12, 1.0 };
const SURFACE: [4]f32 = .{ 0.13, 0.15, 0.22, 1.0 };
const ACCENT: [4]f32 = .{ 0.20, 0.55, 1.00, 1.0 };
const ACCENT_HOVER: [4]f32 = .{ 0.35, 0.70, 1.00, 1.0 };
const GREEN: [4]f32 = .{ 0.20, 0.80, 0.50, 1.0 };
const ORANGE: [4]f32 = .{ 1.00, 0.55, 0.15, 1.0 };
const TEXT: [4]f32 = .{ 0.88, 0.90, 0.96, 1.0 };
const DIM: [4]f32 = .{ 0.50, 0.55, 0.68, 1.0 };
const CARD_W: f32 = 160;
const CARD_H: f32 = 80;

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const font = state.font_data;

    const sectionLabel = struct {
        fn make(u: *AppUIContext, f: *FontData, text: []const u8) !*AppNode {
            return u.ux().text(.{
                .style = .{ .text_color = DIM },
                .content = text,
                .font = f,
            });
        }
    }.make;

    const card = struct {
        fn make(
            u: *AppUIContext,
            f: *FontData,
            id: ?NodeId,
            bg: [4]f32,
            label: []const u8,
            radius: f32,
            scale: f32,
            opacity: f32,
            transition: TransitionStyle,
            hover_enter: ?u32,
            hover_exit: ?u32,
            click: ?u32,
        ) !*AppNode {
            return u.ux().div(.{
                .id = id,
                .style = .{
                    .width = .{ .exact = CARD_W },
                    .height = .{ .exact = CARD_H },
                    .direction = .Column,
                    .align_items = .Center,
                    .justify_content = .Center,
                    .background_color = bg,
                    .corner_radius = layout.CornerRadius.all(radius),
                    .opacity = opacity,
                    .transform = .{ .scale = scale },
                    .transition = transition,
                },
                .children = &.{
                    try u.ux().text(.{
                        .style = .{ .text_color = TEXT, .pointer_events = .none },
                        .content = label,
                        .font = f,
                    }),
                },
                .events = blk: {
                    const arena = u.build_arena.allocator();
                    var buf = try arena.alloc(EventBinding, 3);
                    var n: usize = 0;
                    if (hover_enter) |m| {
                        buf[n] = .{ .event = .hover_enter, .msg = m };
                        n += 1;
                    }
                    if (hover_exit) |m| {
                        buf[n] = .{ .event = .hover_exit, .msg = m };
                        n += 1;
                    }
                    if (click) |m| {
                        buf[n] = .{ .event = .click, .msg = m };
                        n += 1;
                    }
                    break :blk buf[0..n];
                },
            });
        }
    }.make;

    const card_hover_color = try card(
        ui,
        font,
        Id.hover_color,
        if (state.hover_color) ACCENT_HOVER else ACCENT,
        "Color",
        8.0,
        1.0,
        1.0,
        .{
            .property = TransitionProperty.colors,
            .duration_ms = 200,
            .timing = .ease_out,
        },
        Msg.hover_color_enter,
        Msg.hover_color_exit,
        null,
    );

    const card_hover_scale = try card(
        ui,
        font,
        Id.hover_scale,
        ACCENT,
        "Scale",
        8.0,
        if (state.hover_scale) 1.08 else 1.0,
        1.0,
        .{
            .property = TransitionProperty.transform_only,
            .duration_ms = 200,
            .timing = .ease_out,
        },
        Msg.hover_scale_enter,
        Msg.hover_scale_exit,
        null,
    );

    const card_hover_both = try card(
        ui,
        font,
        Id.hover_both,
        if (state.hover_both) GREEN else ACCENT,
        "Both",
        8.0,
        if (state.hover_both) 1.08 else 1.0,
        1.0,
        TransitionStyle.forAll(200),
        Msg.hover_both_enter,
        Msg.hover_both_exit,
        null,
    );

    const hover_row = try ui.ux().div(.{
        .style = .{
            .direction = .Row,
            .gap = 16,
            .align_items = .Center,
        },
        .children = &.{ card_hover_color, card_hover_scale, card_hover_both },
    });

    const card_toggle_color = try card(
        ui,
        font,
        Id.toggle_color,
        if (state.color_on) ORANGE else SURFACE,
        if (state.color_on) "On" else "Off",
        8.0,
        1.0,
        1.0,
        TransitionStyle.forColors(300),
        null,
        null,
        Msg.toggle_color_click,
    );

    const card_toggle_opacity = try card(
        ui,
        font,
        Id.toggle_opacity,
        ACCENT,
        if (state.opacity_on) "Shown" else "Dim",
        8.0,
        1.0,
        if (state.opacity_on) 1.0 else 0.25,
        TransitionStyle.forOpacity(300),
        null,
        null,
        Msg.toggle_opacity_click,
    );

    const card_toggle_radius = try card(
        ui,
        font,
        Id.toggle_radius,
        ACCENT,
        if (state.radius_on) "Circle" else "Square",
        if (state.radius_on) CARD_H / 2.0 else 4.0,
        1.0,
        1.0,
        .{
            .property = .{ .corner_radius = true },
            .duration_ms = 400,
            .timing = .ease_in_out,
        },
        null,
        null,
        Msg.toggle_radius_click,
    );

    const toggle_row = try ui.ux().div(.{
        .style = .{
            .direction = .Row,
            .gap = 16,
            .align_items = .Center,
        },
        .children = &.{ card_toggle_color, card_toggle_opacity, card_toggle_radius },
    });

    const spinner = try ui.ux().div(.{
        .id = Id.spinner,
        .style = .{
            .width = .{ .exact = 48 },
            .height = .{ .exact = 48 },
            .background_color = ACCENT,
            .corner_radius = layout.CornerRadius{ .top_left = 4, .top_right = 16, .bottom_right = 4, .bottom_left = 16 },
            .transform = .{ .rotate = 0.0 },
        },
    });

    const spinner_label = try ui.ux().text(.{
        .style = .{ .text_color = DIM },
        .content = "looping rotate",
        .font = font,
    });

    const continuous_row = try ui.ux().div(.{
        .style = .{
            .direction = .Row,
            .gap = 16,
            .align_items = .Center,
        },
        .children = &.{ spinner, spinner_label },
    });

    const title = try ui.ux().text(.{
        .style = .{ .text_color = TEXT },
        .content = "animation demo",
        .font = font,
    });

    const subtitle = try ui.ux().text(.{
        .style = .{ .text_color = DIM },
        .content = "Transitions are driven by reconciliation - no per-frame rebuilds needed.",
        .font = font,
    });

    const hover_label = try sectionLabel(ui, font, "Hover Transitions");
    const toggle_label = try sectionLabel(ui, font, "Click Toggles");
    const continuous_label = try sectionLabel(ui, font, "Continuous Animation");

    return ui.ux().div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .direction = .Column,
            .align_items = .Start,
            .justify_content = .Center,
            .gap = 12,
            .padding = Spacing{ .left = 60, .right = 60, .top = 0, .bottom = 0 },
            .background_color = BG,
        },
        .children = &.{
            title,
            subtitle,
            try ui.ux().div(.{ .style = .{ .height = .{ .exact = 8 } } }), // spacer
            hover_label,
            hover_row,
            try ui.ux().div(.{ .style = .{ .height = .{ .exact = 4 } } }), // spacer
            toggle_label,
            toggle_row,
            try ui.ux().div(.{ .style = .{ .height = .{ .exact = 4 } } }), // spacer
            continuous_label,
            continuous_row,
        },
    });
}

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    const state = &app.state;
    switch (msg.id) {
        Msg.hover_color_enter => {
            state.hover_color = true;
            return .rebuild;
        },
        Msg.hover_color_exit => {
            state.hover_color = false;
            return .rebuild;
        },
        Msg.hover_scale_enter => {
            state.hover_scale = true;
            return .rebuild;
        },
        Msg.hover_scale_exit => {
            state.hover_scale = false;
            return .rebuild;
        },
        Msg.hover_both_enter => {
            state.hover_both = true;
            return .rebuild;
        },
        Msg.hover_both_exit => {
            state.hover_both = false;
            return .rebuild;
        },
        Msg.toggle_color_click => {
            state.color_on = !state.color_on;
            return .rebuild;
        },
        Msg.toggle_opacity_click => {
            state.opacity_on = !state.opacity_on;
            return .rebuild;
        },
        Msg.toggle_radius_click => {
            state.radius_on = !state.radius_on;
            return .rebuild;
        },
        else => return .none,
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var app = try App.init(
        rt.allocator(),
        io,
        .{ .title = "animation demo" },
        AppState{},
        update,
    );
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    try app.setRootBuilder(build);
    try app.mountRoot();

    try app.registerAnimation(.{
        .node_id = Id.spinner,
        .value = .{ .rotate = .{ .from = 0.0, .to = std.math.tau } },
        .start_time = 0.0, // looping from t=0, so current_time % duration is correct
        .duration = 2.0,
        .delay = 0.0,
        .timing = .ease_in_out,
        .looping = true,
    });

    try app.run();
}
