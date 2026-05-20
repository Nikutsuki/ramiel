//! Hot-reload host for the ManagedApp demo.
const std = @import("std");
pub const tracy_impl = @import("tracy_impl");
const lib = @import("ramiel");
const types = @import("app_types.zig");

const App = types.App;

fn placeholderUpdate(_: *App, _: lib.InteractionMessage(types.Message)) lib.UpdateAction {
    return .none;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    const exe_path = arg_it.next() orelse "managed-host";

    var lib_path: ?[]const u8 = null;
    var build_target: ?[]const u8 = null;
    var restore_path: ?[]const u8 = null;
    var watch_dirs: std.ArrayList([]const u8) = .empty;
    defer watch_dirs.deinit(allocator);
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--lib")) {
            lib_path = arg_it.next() orelse return error.MissingLibPath;
        } else if (std.mem.eql(u8, arg, "--watch")) {
            try watch_dirs.append(allocator, arg_it.next() orelse return error.MissingWatchDir);
        } else if (std.mem.eql(u8, arg, "--build-target")) {
            build_target = arg_it.next() orelse return error.MissingBuildTarget;
        } else if (std.mem.eql(u8, arg, "--restore")) {
            restore_path = arg_it.next() orelse return error.MissingRestorePath;
        }
    }
    const resolved_lib_path = lib_path orelse {
        std.log.err("host: --lib <path> is required", .{});
        return error.MissingLibPath;
    };

    var app = try App.init(
        allocator,
        io,
        .{ .title = "managed hot reload demo" },
        try types.Managed.initState(allocator),
        placeholderUpdate,
    );
    defer app.deinit();
    defer types.Managed.deinitState(&app.state);

    app.state.runtime.font_data = try app.loadDefaultFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 20);
    app.wireResolvers();

    if (restore_path) |rp| {
        if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, rp, allocator, .limited(1 << 20))) |bytes| {
            defer allocator.free(bytes);
            lib.hotreload.snapshot.restoreFromJson(types.State, &app.state, allocator, bytes) catch |err| {
                std.log.warn("host: snapshot restore failed: {s}", .{@errorName(err)});
            };
            std.Io.Dir.cwd().deleteFile(io, rp) catch {};
        } else |err| {
            std.log.warn("host: could not read snapshot {s}: {s}", .{ rp, @errorName(err) });
        }
    }

    var coordinator = try lib.hotreload.Coordinator(App).init(allocator, io, resolved_lib_path, &app);
    defer coordinator.deinit();

    var relaunch: std.ArrayList([]const u8) = .empty;
    defer relaunch.deinit(allocator);
    try relaunch.appendSlice(allocator, &.{ exe_path, "--lib", resolved_lib_path });
    for (watch_dirs.items) |d| try relaunch.appendSlice(allocator, &.{ "--watch", d });
    if (build_target) |t| try relaunch.appendSlice(allocator, &.{ "--build-target", t });
    coordinator.setRelaunchArgv(relaunch.items);

    var hook = coordinator.hook();
    app.setReloadHook(&hook);

    const Watcher = lib.hotreload.Watcher(App);
    var watcher: ?*Watcher = null;
    defer if (watcher) |w| w.deinit();
    if (watch_dirs.items.len > 0 and build_target != null) {
        watcher = try Watcher.init(allocator, io, &coordinator, &app, watch_dirs.items, build_target.?);
        try watcher.?.start();
        std.log.info("host: watching {d} dir(s); edit + save reloads. F5 forces a reload.", .{watch_dirs.items.len});
    }

    try app.run();
}
