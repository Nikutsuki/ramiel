//! Reusable hot-reload host runner.
//!
//! The host owns the window/GPU/Application while build/update live in a
//! swappable dynamic library. Examples should only provide app-specific state
//! initialization and optional post-init wiring.
const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const UpdateAction = @import("../ui/context.zig").UpdateAction;
const InteractionMessage = @import("../ui/types.zig").InteractionMessage;
const coordinator_mod = @import("coordinator.zig");
const watcher_mod = @import("watcher.zig");
const snapshot = @import("snapshot.zig");

pub fn Options(comptime App: type, comptime State: type) type {
    return struct {
        title: [:0]const u8,
        default_exe_name: [:0]const u8,
        initial_state_fn: *const fn (std.mem.Allocator) anyerror!State,
        deinit_state_fn: ?*const fn (*State) void = null,
        after_init_fn: ?*const fn (*App, std.mem.Allocator) anyerror!void = null,
        ready_message: ?[]const u8 = null,
    };
}

pub fn runHost(
    comptime App: type,
    comptime State: type,
    comptime Message: type,
    init: std.process.Init,
    options: Options(App, State),
) !void {
    const io = init.io;

    var rt = Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    const exe_path = arg_it.next() orelse options.default_exe_name;

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
        .{ .title = options.title },
        try options.initial_state_fn(allocator),
        Placeholder(App, Message).update,
    );
    defer app.deinit();
    defer if (options.deinit_state_fn) |f| f(&app.state);

    if (options.after_init_fn) |f| try f(&app, allocator);
    app.wireResolvers();

    if (restore_path) |rp| {
        if (std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, rp, allocator, .limited(1 << 20))) |bytes| {
            defer allocator.free(bytes);
            snapshot.restoreFromJson(State, &app.state, allocator, bytes) catch |err| {
                std.log.warn("host: snapshot restore failed: {s}", .{@errorName(err)});
            };
            std.Io.Dir.cwd().deleteFile(io, rp) catch {};
        } else |err| {
            std.log.warn("host: could not read snapshot {s}: {s}", .{ rp, @errorName(err) });
        }
    }

    var coordinator = try coordinator_mod.Coordinator(App).init(allocator, io, resolved_lib_path, &app);
    defer coordinator.deinit();

    var relaunch: std.ArrayList([]const u8) = .empty;
    defer relaunch.deinit(allocator);
    try relaunch.appendSlice(allocator, &.{ exe_path, "--lib", resolved_lib_path });
    for (watch_dirs.items) |d| try relaunch.appendSlice(allocator, &.{ "--watch", d });
    if (build_target) |t| try relaunch.appendSlice(allocator, &.{ "--build-target", t });
    coordinator.setRelaunchArgv(relaunch.items);

    var hook = coordinator.hook();
    app.setReloadHook(&hook);

    const Watcher = watcher_mod.Watcher(App);
    var watcher: ?*Watcher = null;
    defer if (watcher) |w| w.deinit();
    if (watch_dirs.items.len > 0 and build_target != null) {
        watcher = try Watcher.init(allocator, io, &coordinator, &app, watch_dirs.items, build_target.?);
        try watcher.?.start();
        std.log.info("host: watching {d} dir(s); edit + save reloads. F5 forces a reload.", .{watch_dirs.items.len});
    } else if (options.ready_message) |msg| {
        std.log.info("{s}", .{msg});
    }

    try app.run();
}

fn Placeholder(comptime App: type, comptime Message: type) type {
    return struct {
        fn update(_: *App, _: InteractionMessage(Message)) UpdateAction {
            return .none;
        }
    };
}
