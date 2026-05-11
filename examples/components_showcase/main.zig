const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const UpdateAction = lib.UpdateAction;
const layout = lib.layout;
const tw = lib.tw;

const AppMessage = union(enum) {
    checkbox_group_change: struct { index: usize, checked: bool },
    graphics_mode_select: GraphicsMode,
    slider_change: f32,
    dropdown_toggle: bool,
    dropdown_select: usize,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const feature_count = 3;
const GraphicsMode = enum { performance, balanced, quality };
const graphics_modes = std.enums.values(GraphicsMode);
const graphics_mode_labels = [_][]const u8{ "Performance", "Balanced", "High Quality" };
const dropdown_options = [_][]const u8{ "Windowed", "Borderless", "Fullscreen" };

const NodeIds = lib.declareIds("examples.components_showcase", .{
    "feature_checkboxes",
    "graphics_radios",
    "quality_slider",
    "display_dropdown",
}){};

const Dispatch = struct {
    fn graphicsMode(i: usize, _: ?*const anyopaque) AppMessage {
        return .{ .graphics_mode_select = graphics_modes[i] };
    }

    fn featureToggle(i: usize, c: bool) AppMessage {
        return .{ .checkbox_group_change = .{ .index = i, .checked = c } };
    }
};

const AppState = struct {
    font_data: *FontData = undefined,
    feature_toggles: [feature_count]bool = .{ false, true, false },
    graphics_mode: GraphicsMode = .balanced,
    slider_value: f32 = 0.35,
    dropdown_open: bool = false,
    dropdown_selected: usize = 1,
};

const App = lib.Application(AppState, AppMessage);

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const font = state.font_data;
    const components = ui.components();

    const feature_labels = [_][]const u8{ "Layers", "Shadows", "Bloom" };
    const checkbox_group_node = try components.checkboxGroup(.{
        .logic = .{
            .base_id = NodeIds.feature_checkboxes,
            .checked = state.feature_toggles[0..],
            .on_toggle = Dispatch.featureToggle,
        },
        .visuals = .{
            .options = &feature_labels,
            .font = font,
            .direction = .Column,
            .gap = 10.0,
            .style = tw.style(.{ tw.mt(2.5) }),
            .item_style = .{},
            .box = .{
                .style = .{
                    .border = layout.Border.all(1.0, .{ 0.28, 0.33, 0.44, 1.0 }),
                    .transition = layout.TransitionStyle.forColors(150),
                },
            },
            .label_style = .{
                .text_color = .{ 0.86, 0.9, 0.96, 1.0 },
            },
        },
    });

    const radio_group_node = try components.radioGroup(.{
        .logic = .{
            .base_id = NodeIds.graphics_radios,
            .active_index = @intFromEnum(state.graphics_mode),
            .on_change = Dispatch.graphicsMode,
        },
        .visuals = .{
            .options = &graphics_mode_labels,
            .font = font,
            .direction = .Column,
            .gap = 12.0,
            .style = tw.style(.{ tw.mt(3.5) }),
            .item_style = .{},
            .ring = .{
                .style = .{
                    .transition = layout.TransitionStyle.forColors(120),
                },
            },
        },
    });

    const slider_value_text = try std.fmt.allocPrint(
        ui.build_arena.allocator(),
        "Slider value: {d:.3}",
        .{state.slider_value},
    );

    const slider_node = try components.slider(.{
        .base_id = NodeIds.quality_slider,
        .value = state.slider_value,
        .on_change = lib.bindTag(AppMessage, f32, .slider_change),
        .track = .{ .style = tw.style(.{
            tw.w_full,
            tw.h(12.0),
            tw.mt(2.5),
            tw.bg("#2e3345ff"),
            tw.rounded(6.0),
        }) },
        .fill = .{ .style = tw.style(.{
            tw.bg("#4cb8ffff"),
            tw.transition_colors(80),
        }) },
        .handle = .{ .style = tw.style(.{
            tw.w(22.0),
            tw.h(22.0),
            tw.bg("#f2f7ffff"),
            tw.border(1.0,  "#b8ccf0ff"),
        }) },
    });

    const dropdown_node = try components.dropdown(.{
        .base_id = NodeIds.display_dropdown,
        .is_open = state.dropdown_open,
        .active_index = state.dropdown_selected,
        .options = &dropdown_options,
        .on_toggle = lib.bindTag(AppMessage, bool, .dropdown_toggle),
        .on_select = lib.bindTag(AppMessage, usize, .dropdown_select),
        .font = font,
        .trigger = .{ .style = tw.style(.{
            tw.w_full,
            tw.px(2.5),
            tw.py(2.0),
            tw.mt(3.5),
            tw.bg("#292e3dff"),
            tw.rounded(6.0),
            tw.border(1.0,  "#475470ff"),
        }) },
        .menu = .{ .style = tw.style(.{
            tw.bg("#1c2130ff"),
            tw.rounded(8.0),
            tw.border(1.0,  "#475470ff"),
            tw.p(1.0),
            tw.gap(0.5),
        }) },
        .item = .{ .style = tw.style(.{
            tw.px(2.5),
            tw.py(1.75),
            tw.rounded(4.0),
        }) },
    });

    return try ui.ux().div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .direction = .Column,
            .align_items = .Center,
            .justify_content = .Center,
            .background_color = .{ 0.07, 0.08, 0.11, 1.0 },
        },
        .children = &.{
            try ui.ux().div(.{
                .style = .{
                    .width = .{ .exact = 520.0 },
                    .direction = .Column,
                    .padding = layout.Spacing.all(18.0),
                    .background_color = .{ 0.11, 0.13, 0.19, 1.0 },
                    .corner_radius = layout.CornerRadius.all(10.0),
                    .gap = 4.0,
                },
                .children = &.{
                    try ui.ux().text(.{
                        .content = "components showcase",
                        .font = font,
                        .style = .{ .text_color = .{ 0.93, 0.96, 1.0, 1.0 } },
                    }),
                    try ui.ux().text(.{
                        .content = "Checkbox group, radio group, and slider (atomic primitives composed in-library)",
                        .font = font,
                        .style = .{ .text_color = .{ 0.66, 0.72, 0.84, 1.0 } },
                    }),
                    checkbox_group_node,
                    radio_group_node,
                    try ui.ux().text(.{
                        .content = slider_value_text,
                        .font = font,
                        .style = .{
                            .margin = .{ .top = 12.0 },
                            .text_color = .{ 0.8, 0.86, 0.96, 1.0 },
                        },
                    }),
                    slider_node,
                    try ui.ux().text(.{
                        .content = "Display mode dropdown (portal + click-away backdrop)",
                        .font = font,
                        .style = .{
                            .margin = .{ .top = 14.0 },
                            .text_color = .{ 0.8, 0.86, 0.96, 1.0 },
                        },
                    }),
                    dropdown_node,
                },
            }),
        },
    });
}

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    const state = &app.state;
    switch (msg.id) {
        .checkbox_group_change => |ch| {
            if (ch.index < state.feature_toggles.len) {
                state.feature_toggles[ch.index] = ch.checked;
                return .rebuild;
            }
            return .none;
        },
        .graphics_mode_select => |mode| {
            state.graphics_mode = mode;
            return .rebuild;
        },
        .slider_change => |new_value| {
            state.slider_value = std.math.clamp(new_value, 0.0, 1.0);
            return .rebuild;
        },
        .dropdown_toggle => |open| {
            state.dropdown_open = open;
            return .rebuild;
        },
        .dropdown_select => |idx| {
            if (idx < dropdown_options.len) {
                state.dropdown_selected = idx;
            }
            state.dropdown_open = false;
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
        .{ .title = "components showcase" },
        AppState{},
        update,
    );
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    try app.setRootBuilder(build);
    try app.run();
}
