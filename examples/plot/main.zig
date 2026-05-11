//! Plot showcase: scrollable column with one panel per SeriesKind.

const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");

const FontData = lib.FontData;
const layout = lib.layout;
const tw = lib.tw;
const Style = layout.Style;
const Spacing = layout.Spacing;
const UpdateAction = lib.UpdateAction;
const comp = lib.components;
const PlotState = comp.PlotState;
const PlotSeries = comp.PlotSeries;
const PlotMsg = comp.PlotMsg;

const AppMessage = union(enum) {
    line_plot: PlotMsg,
    scatter_plot: PlotMsg,
    bar_plot: PlotMsg,
    mixed_plot: PlotMsg,
    stress_plot: PlotMsg,
    stream_plot: PlotMsg,
};

const T = lib.For(AppMessage);
const AppUIContext = T.UIContext;
const AppNode = T.Node;
const AppInteractionMessage = T.InteractionMessage;

const NodeIds = lib.declareIds("examples.plot", .{
    "line_plot",
    "scatter_plot",
    "bar_plot",
    "mixed_plot",
    "stress_plot",
    "stream_plot",
}){};

const SMALL_SAMPLES: usize = 1024 * 1024;
const SCATTER_SAMPLES: usize = 256 * 1024;
const BAR_SAMPLES: usize = 48 * 1024;
const STRESS_SAMPLES: usize = 1024 * 1024 * 64;
const STREAM_CAPACITY: usize = 6000; // 10 seconds at 60 Hz

const AppState = struct {
    font_data: *FontData = undefined,

    line_xs: []f64 = &.{},
    line_ys: []f64 = &.{},
    line_series: [1]PlotSeries = undefined,
    line_state: PlotState = undefined,

    scatter_xs: []f64 = &.{},
    scatter_ys: []f64 = &.{},
    scatter_series: [1]PlotSeries = undefined,
    scatter_state: PlotState = undefined,

    bar_xs: []f64 = &.{},
    bar_ys: []f64 = &.{},
    bar_series: [1]PlotSeries = undefined,
    bar_state: PlotState = undefined,

    mixed_xs: []f64 = &.{},
    mixed_sin: []f64 = &.{},
    mixed_cos: []f64 = &.{},
    mixed_series: [2]PlotSeries = undefined,
    mixed_state: PlotState = undefined,

    stress_xs: []f64 = &.{},
    stress_ys: []f64 = &.{},
    stress_series: [1]PlotSeries = undefined,
    stress_state: PlotState = undefined,

    stream_xs: []f64 = &.{},
    stream_ys: []f64 = &.{},
    stream_len: usize = 0,
    stream_series: [1]PlotSeries = undefined,
    stream_state: PlotState = undefined,

    start_time: f64 = 0,
};

const App = lib.Application(AppState, AppMessage);

fn initBuffers(state: *AppState, allocator: std.mem.Allocator) !void {
    state.line_xs = try allocator.alloc(f64, SMALL_SAMPLES);
    state.line_ys = try allocator.alloc(f64, SMALL_SAMPLES);
    {
        var i: usize = 0;
        while (i < SMALL_SAMPLES) : (i += 1) {
            const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SMALL_SAMPLES - 1));
            state.line_xs[i] = -std.math.tau + t * (2.0 * std.math.tau);
            state.line_ys[i] = @sin(state.line_xs[i]);
        }
    }
    state.line_series = .{
        .{ .xs = state.line_xs, .ys = state.line_ys, .color = .{ 0.4, 0.8, 1.0, 1.0 }, .line_width = 2.0, .label = "sin(x)" },
    };
    state.line_state.setSeries(&state.line_series);

    state.scatter_xs = try allocator.alloc(f64, SCATTER_SAMPLES);
    state.scatter_ys = try allocator.alloc(f64, SCATTER_SAMPLES);
    {
        var rng = std.Random.DefaultPrng.init(0xC0FFEE);
        const r = rng.random();
        var i: usize = 0;
        while (i < SCATTER_SAMPLES) : (i += 1) {
            const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SCATTER_SAMPLES - 1));
            const x = -std.math.tau + t * (2.0 * std.math.tau);
            state.scatter_xs[i] = x;
            const noise = (r.float(f64) - 0.5) * 0.6;
            state.scatter_ys[i] = @sin(x) + noise;
        }
    }
    state.scatter_series = .{
        .{
            .xs = state.scatter_xs,
            .ys = state.scatter_ys,
            .color = .{ 1.0, 0.55, 0.4, 0.85 },
            .point_size = 5.0,
            .kind = .scatter,
            .label = "noisy sin(x)",
        },
    };
    state.scatter_state.setSeries(&state.scatter_series);

    state.bar_xs = try allocator.alloc(f64, BAR_SAMPLES);
    state.bar_ys = try allocator.alloc(f64, BAR_SAMPLES);
    {
        var i: usize = 0;
        while (i < BAR_SAMPLES) : (i += 1) {
            const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(BAR_SAMPLES - 1));
            const x = t * 2.0 * std.math.tau;
            state.bar_xs[i] = x;
            state.bar_ys[i] = @abs(@sin(x)) * 0.8 + 0.2;
        }
    }
    state.bar_series = .{
        .{
            .xs = state.bar_xs,
            .ys = state.bar_ys,
            .color = .{ 0.6, 0.85, 0.5, 1.0 },
            .kind = .bar,
            .bar_baseline = 0.0,
            .label = "|sin(x)|",
        },
    };
    state.bar_state.setSeries(&state.bar_series);

    state.mixed_xs = try allocator.alloc(f64, SMALL_SAMPLES);
    state.mixed_sin = try allocator.alloc(f64, SMALL_SAMPLES);
    state.mixed_cos = try allocator.alloc(f64, SMALL_SAMPLES);
    {
        var i: usize = 0;
        while (i < SMALL_SAMPLES) : (i += 1) {
            const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SMALL_SAMPLES - 1));
            const x = -std.math.tau + t * (2.0 * std.math.tau);
            state.mixed_xs[i] = x;
            state.mixed_sin[i] = @sin(x);
            state.mixed_cos[i] = @cos(x);
        }
    }
    state.mixed_series = .{
        .{ .xs = state.mixed_xs, .ys = state.mixed_sin, .color = .{ 0.4, 0.8, 1.0, 1.0 }, .line_width = 1.5, .label = "sin(x)" },
        .{ .xs = state.mixed_xs, .ys = state.mixed_cos, .color = .{ 1.0, 0.55, 0.4, 0.9 }, .point_size = 4.0, .kind = .scatter, .label = "cos(x) scatter" },
    };
    state.mixed_state.setSeries(&state.mixed_series);

    state.stress_xs = try allocator.alloc(f64, STRESS_SAMPLES);
    state.stress_ys = try allocator.alloc(f64, STRESS_SAMPLES);
    {
        var i: usize = 0;
        while (i < STRESS_SAMPLES) : (i += 1) {
            const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(STRESS_SAMPLES - 1));
            const x = -std.math.tau + t * (2.0 * std.math.tau);
            state.stress_xs[i] = x;
            state.stress_ys[i] = @sin(x) * (0.6 + 0.4 * @sin(x * 17.0));
        }
    }
    state.stress_series = .{
        .{ .xs = state.stress_xs, .ys = state.stress_ys, .color = .{ 0.85, 0.7, 1.0, 1.0 }, .line_width = 1.5, .label = "modulated sin" },
    };
    state.stress_state.setSeries(&state.stress_series);

    state.stream_xs = try allocator.alloc(f64, STREAM_CAPACITY);
    state.stream_ys = try allocator.alloc(f64, STREAM_CAPACITY);
    @memset(state.stream_xs, 0);
    @memset(state.stream_ys, 0);
}

fn deinitBuffers(state: *AppState, allocator: std.mem.Allocator) void {
    state.line_state.deinit();
    state.scatter_state.deinit();
    state.bar_state.deinit();
    state.mixed_state.deinit();
    state.stress_state.deinit();
    state.stream_state.deinit();

    allocator.free(state.line_xs);
    allocator.free(state.line_ys);
    allocator.free(state.scatter_xs);
    allocator.free(state.scatter_ys);
    allocator.free(state.bar_xs);
    allocator.free(state.bar_ys);
    allocator.free(state.mixed_xs);
    allocator.free(state.mixed_sin);
    allocator.free(state.mixed_cos);
    allocator.free(state.stress_xs);
    allocator.free(state.stress_ys);
    allocator.free(state.stream_xs);
    allocator.free(state.stream_ys);
}

const PANEL_HEIGHT: f32 = 480.0;

fn plotPanel(
    ui: *AppUIContext,
    title: []const u8,
    subtitle: []const u8,
    plot_node: *AppNode,
    state: *const AppState,
) !*AppNode {
    const plot_wrap = try ui.ux().div(.{
        .style = .{ .width = .Full, .flex_grow = 1.0 },
        .children = &.{plot_node},
    });

    return ui.ux().div(.{
        .style = .{
            .direction = .Column,
            .gap = 4,
            .width = .Full,
            .height = .{ .exact = PANEL_HEIGHT },
        },
        .children = &.{
            try ui.ux().text(.{ .content = title, .font = state.font_data, .style = .{ .text_color = .{ 1, 1, 1, 1 }, .font_size = 14 } }),
            try ui.ux().text(.{ .content = subtitle, .font = state.font_data, .style = .{ .text_color = .{ 0.6, 0.65, 0.75, 1 }, .font_size = 11 } }),
            plot_wrap,
        },
    });
}

fn build(ui: *AppUIContext, state: *const AppState) anyerror!*AppNode {
    const components = ui.components();

    const ms: *AppState = @constCast(state);

    const plot_style = tw.style(.{ tw.bg("#1a1c24ff"), tw.rounded(6) });
    const axis_label_style: layout.Style = .{ .font_size = 11, .text_color = .{ 0.7, 0.75, 0.85, 1.0 } };
    const desc_base: comp.PlotDescriptor = .{
        .style = plot_style,
        .axis_font = state.font_data,
        .axis_label_style = axis_label_style,
        .zoom_modifier = .ctrl,
    };

    const line_plot = try components.plot(.{ .logic = .{ .base_id = NodeIds.line_plot, .state = &ms.line_state, .on_change = lib.bindTag(AppMessage, PlotMsg, .line_plot) }, .visuals = desc_base });
    const scatter_plot = try components.plot(.{ .logic = .{ .base_id = NodeIds.scatter_plot, .state = &ms.scatter_state, .on_change = lib.bindTag(AppMessage, PlotMsg, .scatter_plot) }, .visuals = desc_base });
    const bar_plot = try components.plot(.{ .logic = .{ .base_id = NodeIds.bar_plot, .state = &ms.bar_state, .on_change = lib.bindTag(AppMessage, PlotMsg, .bar_plot) }, .visuals = desc_base });
    const mixed_plot = try components.plot(.{ .logic = .{ .base_id = NodeIds.mixed_plot, .state = &ms.mixed_state, .on_change = lib.bindTag(AppMessage, PlotMsg, .mixed_plot) }, .visuals = desc_base });
    const stress_plot = try components.plot(.{ .logic = .{ .base_id = NodeIds.stress_plot, .state = &ms.stress_state, .on_change = lib.bindTag(AppMessage, PlotMsg, .stress_plot) }, .visuals = desc_base });
    const stream_plot = try components.plot(.{ .logic = .{ .base_id = NodeIds.stream_plot, .state = &ms.stream_state, .on_change = lib.bindTag(AppMessage, PlotMsg, .stream_plot) }, .visuals = desc_base });

    const panels = try ui.build_arena.allocator().dupe(?*AppNode, &.{
        try plotPanel(ui, "1. Line", "kind = .line - connected polyline. 1024 samples.", line_plot, state),
        try plotPanel(ui, "2. Scatter", "kind = .scatter - point cloud. 256 noisy samples.", scatter_plot, state),
        try plotPanel(ui, "3. Bar", "kind = .bar - filled rect per sample, anchored at bar_baseline = 0.", bar_plot, state),
        try plotPanel(ui, "4. Mixed", "Multiple kinds on one axis. sin(x) line + cos(x) scatter.", mixed_plot, state),
        try plotPanel(ui, "5. Stress", "4M samples. LOD pyramid kicks in - vertex output bounded by pixel width.", stress_plot, state),
        try plotPanel(ui, "6. Streaming bar", "Rolling 10-second window, fed every frame. Press R to reattach follow-mode.", stream_plot, state),
    });

    return try ui.ux().div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .direction = .Column,
            .gap = 16,
            .padding = Spacing.all(16),
            .background_color = .{ 0.05, 0.06, 0.08, 1.0 },
            .overflow_y = .scroll,
            .scrollbar_width = 10,
            .scrollbar_min_height = 32,
            .scrollbar_color = .{ 0.4, 0.45, 0.55, 0.6 },
            .scrollbar_radius = 5,
        },
        .children = panels,
    });
}

fn update(app: *App, msg: AppInteractionMessage) UpdateAction {
    const state = &app.state;
    switch (msg.id) {
        .line_plot => |pm| comp.applyPlotMsg(&state.line_state, pm),
        .scatter_plot => |pm| comp.applyPlotMsg(&state.scatter_state, pm),
        .bar_plot => |pm| comp.applyPlotMsg(&state.bar_state, pm),
        .mixed_plot => |pm| comp.applyPlotMsg(&state.mixed_state, pm),
        .stress_plot => |pm| comp.applyPlotMsg(&state.stress_state, pm),
        .stream_plot => |pm| comp.applyPlotMsg(&state.stream_state, pm),
    }
    return .rebuild;
}

fn tick(app: *App) UpdateAction {
    const state = &app.state;
    const now = lib.glfw.getTime();
    if (state.start_time == 0) state.start_time = now;
    const elapsed = now - state.start_time;

    if (state.stream_len == STREAM_CAPACITY) {
        var i: usize = 1;
        while (i < STREAM_CAPACITY) : (i += 1) {
            state.stream_xs[i - 1] = state.stream_xs[i];
            state.stream_ys[i - 1] = state.stream_ys[i];
        }
        state.stream_len -= 1;
    }
    state.stream_xs[state.stream_len] = elapsed;
    state.stream_ys[state.stream_len] = @sin(elapsed * 2.0) + 0.3 * @sin(elapsed * 7.3);
    state.stream_len += 1;

    state.stream_series[0] = .{
        .xs = state.stream_xs[0..state.stream_len],
        .ys = state.stream_ys[0..state.stream_len],
        .color = .{ 0.6, 1.0, 0.5, 1.0 },
        .kind = .bar,
        .bar_baseline = 0.0,
    };
    state.stream_state.setSeries(&state.stream_series);

    lib.glfw.postEmptyEvent();
    return .rebuild;
}

fn resetShortcut(
    state: *AppState,
    ir: *@import("ramiel").For(AppMessage).InteractionRegistry,
    key: i32,
    action: i32,
    _: *const lib.WindowContext,
) bool {
    if (key != lib.glfw.KeyR or action != lib.glfw.Press) return false;
    state.line_state.setAxisModes(.auto, .auto);
    state.scatter_state.setAxisModes(.auto, .auto);
    state.bar_state.setAxisModes(.auto, .auto);
    state.mixed_state.setAxisModes(.auto, .auto);
    state.stress_state.setAxisModes(.auto, .auto);
    state.stream_state.setAxisModes(.{ .follow = 10.0 }, .fixed);
    ir.rebuild_requested = true;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var initial_state = AppState{};
    initial_state.line_state = PlotState.init(rt.allocator());
    initial_state.scatter_state = PlotState.init(rt.allocator());
    initial_state.bar_state = PlotState.init(rt.allocator());
    initial_state.mixed_state = PlotState.init(rt.allocator());
    initial_state.stress_state = PlotState.init(rt.allocator());
    initial_state.stream_state = PlotState.init(rt.allocator());

    var app = try App.init(
        rt.allocator(),
        io,
        .{ .title = "Plot showcase" },
        initial_state,
        update,
    );
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont(
        "JetBrains Mono",
        .{ .memory = lib.assets.getFontData(.jetbrains_mono) },
        32,
    );

    try initBuffers(&app.state, rt.allocator());
    defer deinitBuffers(&app.state, rt.allocator());

    app.state.stream_state.x_mode = .{ .follow = 10.0 };
    app.state.stream_state.setYRange(-1.5, 1.5);

    app.tick_fn = tick;
    app.setShortcutHandler(AppState, &app.state, resetShortcut);

    try app.setRootBuilder(build);
    try app.run();
}
