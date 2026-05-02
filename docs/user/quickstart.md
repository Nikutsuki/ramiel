# Quickstart

Minimal retained-mode app.

## Prerequisites

- Zig 0.16.0-dev
- Build deps via `build.zig.zon`

## Minimal app

```zig
const std = @import("std");
const lib = @import("ramiel");

const AppMessage = enum(u32) {
    button_click,
};

const AppState = struct {
    count: usize = 0,
    font: ?*lib.FontData = null,
};

const T = lib.For(AppMessage);
const App = lib.Application(AppState, AppMessage);

fn build(ui: *T.UIContext, state: *const AppState) anyerror!*T.Node {
    const font = state.font orelse return error.FontNotLoaded;

    return ui.div(.{
        .style = .{
            .width = .screen,
            .height = .screen,
            .justify_content = .Center,
            .align_items = .Center,
            .background_color = .{ 0.08, 0.09, 0.12, 1.0 },
        },
        .children = &.{
            try ui.button(.{
                .style = .{
                    .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 },
                    .background_color = .{ 0.2, 0.45, 0.8, 1.0 },
                    .hover_color = .{ 0.28, 0.55, 0.9, 1.0 },
                },
                .label = "click me",
                .font = font,
                .on_click_msg = .button_click,
            }),
        },
    });
}

fn update(_: *App, msg: T.InteractionMessage) lib.UpdateAction {
    if (msg.id) |id| switch (id) {
        .button_click => return .rebuild,
    }
    return .none;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var app = try App.init(
        rt.allocator(),
        io,
        .{ .title = "quickstart" },
        .{},
        update,
    );
    defer app.deinit();

    app.state.font = try app.loadFont(
        "JetBrains Mono",
        .{ .memory = lib.assets.getFontData(.jetbrains_mono) },
        16,
    );

    try app.setRootBuilder(build);
    try app.run();
}
```

## What's happening

`App.init` wires window, renderer, UI context, reducer. `setRootBuilder` mounts the first retained tree. `run` blocks on events until window closes. Reducer return value (`UpdateAction`) drives the next phase: `.none`, `.repaint`, `.relayout`, `.rebuild`.

`lib.Runtime` is `DebugAllocator` in Debug, `smp_allocator` in Release. Don't hand-roll a GPA — see `examples/box_sizing/main.zig`.

`lib.For(MessageT)` bundles `UIContext`, `Node`, `InteractionMessage`, etc. Use it instead of repeating type parameters.

## Next

- `docs/user/app-lifecycle.md`
- `docs/user/styling-and-layout.md`
- `docs/user/runtime-helpers.md`
