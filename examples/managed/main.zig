//! Standalone (non-hot-reload) build of the ManagedApp demo.
const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");
const types = @import("app_types.zig");

const RunSpec = struct {
    pub const window: lib.AppBackendConfig = .{ .title = "managed demo" };
    pub const default_font: lib.FontSpec = .{
        .name = "JetBrains Mono",
        .source = .{ .memory = lib.assets.getFontData(.jetbrains_mono) },
        .family = lib.assets.jetbrainsMonoSources(),
        .base_resolution = 20,
    };

    pub fn setup(ctx: anytype) !void {
        ctx.app.state.runtime.font_data = ctx.app.requireFont("JetBrains Mono");
    }
};

pub fn main(init: std.process.Init) !void {
    try types.Managed.run(init, RunSpec);
}
