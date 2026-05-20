//! Standalone (non-hot-reload) build, sharing types/logic with the host/lib split.
const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");
const types = @import("app_types.zig");
const logic = @import("logic.zig");

const App = types.App;
const AppState = types.AppState;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();

    var app = try App.init(
        rt.allocator(),
        io,
        .{ .title = "pointer capture demo" },
        AppState{},
        logic.update,
    );
    defer app.deinit();

    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);

    try app.setRootBuilder(logic.build);
    try app.run();
}
