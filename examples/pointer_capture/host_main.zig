//! Hot-reload host. `zig build run-pointer-capture -Dhot-reload=true` runs this.
const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");
const types = @import("app_types.zig");

const App = types.App;
const AppState = types.AppState;
const AppMessage = types.AppMessage;

fn initialState(_: std.mem.Allocator) !AppState {
    return .{};
}

fn afterInit(app: *App, _: std.mem.Allocator) !void {
    app.state.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);
}

pub fn main(init: std.process.Init) !void {
    try lib.hotreload.runHost(App, AppState, AppMessage, init, .{
        .title = "pointer capture demo (hot reload)",
        .default_exe_name = "pointer_capture-host",
        .initial_state_fn = initialState,
        .after_init_fn = afterInit,
        .ready_message = "host: ready. Edit examples/pointer_capture/logic.zig, rebuild the hot target, press F5 to reload.",
    });
}
