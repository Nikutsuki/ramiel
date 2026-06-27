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
                .style = tw.style(.{
                    tw.border_value(1.0, layout.Color.from(.{ 0.28, 0.33, 0.44, 1.0 })),
                    tw.transition_colors(150),
                }),
            },
            .label_style = tw.style(.{tw.text_color_value(layout.Color.from(.{ 0.86, 0.9, 0.96, 1.0 }))}),
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
                .style = tw.style(.{tw.transition_colors(120)}),
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
        .style = tw.style(.{
            tw.size_screen,
            tw.flex_col,
            tw.items_center,
            tw.justify_center,
            tw.bg_value(layout.Color.from(.{ 0.07, 0.08, 0.11, 1.0 })),
        }),
        .children = &.{
            try ui.ux().div(.{
                .style = tw.style(.{
                    tw.w(520.0),
                    tw.flex_col,
                    tw.p_px(18.0),
                    tw.bg_value(layout.Color.from(.{ 0.11, 0.13, 0.19, 1.0 })),
                    tw.rounded(10.0),
                    tw.gap_px(4.0),
                }),
                .children = &.{
                    try ui.ux().text(.{
                        .content = "components showcase",
                        .font = font,
                        .style = tw.style(.{tw.text_color_value(layout.Color.from(.{ 0.93, 0.96, 1.0, 1.0 }))}),
                    }),
                    try ui.ux().text(.{
                        .content = "Checkbox group, radio group, and slider (atomic primitives composed in-library)",
                        .font = font,
                        .style = tw.style(.{tw.text_color_value(layout.Color.from(.{ 0.66, 0.72, 0.84, 1.0 }))}),
                    }),
                    try ui.ux().text(.{
                        .content = "Color emoji via font fallback: hi 😀 🎉 🚀 ❤️ 🔥",
                        .font = font,
                        .style = tw.style(.{tw.text_color_value(layout.Color.from(.{ 0.93, 0.96, 1.0, 1.0 }))}),
                    }),
                    checkbox_group_node,
                    radio_group_node,
                    try ui.ux().text(.{
                        .content = slider_value_text,
                        .font = font,
                        .style = tw.style(.{
                            tw.mt_px(12.0),
                            tw.text_color_value(layout.Color.from(.{ 0.8, 0.86, 0.96, 1.0 })),
                        }),
                    }),
                    slider_node,
                    try ui.ux().text(.{
                        .content = "Display mode dropdown (portal + click-away backdrop)",
                        .font = font,
                        .style = tw.style(.{
                            tw.mt_px(14.0),
                            tw.text_color_value(layout.Color.from(.{ 0.8, 0.86, 0.96, 1.0 })),
                        }),
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

fn runCapture(io: std.Io, argv: []const []const u8, buf: []u8) ?[]const u8 {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var mutable_child = child;

    var read_buf: [1024]u8 = undefined;
    var reader = mutable_child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(std.heap.page_allocator, .limited(buf.len)) catch {
        _ = mutable_child.wait(io) catch {};
        return null;
    };
    defer std.heap.page_allocator.free(out);
    _ = mutable_child.wait(io) catch {};

    if (out.len == 0) return null;
    const n = @min(out.len, buf.len);
    @memcpy(buf[0..n], out[0..n]);
    return buf[0..n];
}

fn loadEmojiFallback(app: *App, io: std.Io) void {
    var out_buf: [1024]u8 = undefined;
    const found = runCapture(io, &.{ "fc-match", "-f", "%{file}", "Noto Color Emoji" }, &out_buf) orelse return;
    const path = std.mem.trim(u8, found, " \t\r\n");
    if (path.len == 0 or path.len >= 1023) return;

    var path_buf: [1024]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path.len :0];

    _ = app.loadFont("emoji", .{ .path = path_z }, 109) catch return;
    app.setDefaultFallbackChain(&.{"emoji"}) catch {};
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

    app.state.font_data = try app.loadDefaultFontFamily("JetBrains Mono", lib.assets.jetbrainsMonoSources(), 32);
    loadEmojiFallback(&app, io);

    try app.setRootBuilder(build);
    try app.run();
}