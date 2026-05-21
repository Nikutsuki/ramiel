//! Hot-reload host. `zig build run-managed -Dhot-reload=true` runs this.
const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");
const types = @import("app_types.zig");

const App = types.App;
const State = types.State;
const Message = types.Message;

fn initialState(allocator: std.mem.Allocator) !State {
    return try types.Managed.initState(allocator);
}

fn deinitState(state: *State) void {
    types.Managed.deinitState(state);
}

fn afterInit(app: *App, _: std.mem.Allocator) !void {
    app.state.runtime.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 20);
}

pub fn main(init: std.process.Init) !void {
    try lib.hotreload.runHost(App, State, Message, init, .{
        .title = "managed hot reload demo",
        .default_exe_name = "managed-host",
        .initial_state_fn = initialState,
        .deinit_state_fn = deinitState,
        .after_init_fn = afterInit,
    });
}
