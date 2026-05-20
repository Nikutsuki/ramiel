//! Host-side reload coordinator: owns the live `.so` and performs the same-process swap.
const std = @import("std");
const abi = @import("abi.zig");
const dynlib = @import("dynlib.zig");
const snapshot = @import("snapshot.zig");

const RegisterFn = *const fn (*anyopaque) callconv(.c) void;
const AbiHashFn = *const fn () callconv(.c) u64;
const AbiVersionFn = *const fn () callconv(.c) u32;

const register_symbol = "ramiel_app_register";
const abi_hash_symbol = "ramiel_app_abi_hash";
const abi_version_symbol = "ramiel_app_abi_version";

pub fn Coordinator(comptime App: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        lib_path: [:0]const u8,
        lib: dynlib.Library,
        loaded_copy_path: ?[:0]const u8 = null,
        recorded_hash: u64,
        generation: u32 = 0,
        reload_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        relaunch_argv: ?[]const []const u8 = null,
        error_mutex: std.Io.Mutex = .init,
        error_text: ?[]u8 = null,
        error_version: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init(allocator: std.mem.Allocator, io: std.Io, lib_path: []const u8, app: *App) !Self {
            const path_z = try allocator.dupeZ(u8, lib_path);
            errdefer allocator.free(path_z);

            var self: Self = .{
                .allocator = allocator,
                .io = io,
                .lib_path = path_z,
                .lib = undefined,
                .recorded_hash = 0,
            };

            const copy_path = try self.copyToFreshGeneration();
            errdefer allocator.free(copy_path);

            const lib = try dynlib.Library.open(copy_path.ptr);
            errdefer lib.close();

            const version = (try lib.lookup(AbiVersionFn, abi_version_symbol))();
            if (version != abi.abi_version) {
                std.log.err("hotreload: .so abi_version {d} != host {d}; rebuild host", .{ version, abi.abi_version });
                return error.AbiVersionMismatch;
            }
            self.recorded_hash = (try lib.lookup(AbiHashFn, abi_hash_symbol))();

            const register = try lib.lookup(RegisterFn, register_symbol);
            register(@ptrCast(app));

            self.lib = lib;
            self.loaded_copy_path = copy_path;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.lib.close();
            if (self.loaded_copy_path) |p| {
                std.Io.Dir.deleteFileAbsolute(self.io, p) catch {};
                self.allocator.free(p);
            }
            if (self.error_text) |e| self.allocator.free(e);
            self.allocator.free(self.lib_path);
        }

        /// Set (or clear, with null) the last build error. Called from the watcher
        /// thread; the version bump lets the loop notice and refresh the overlay.
        pub fn setBuildError(self: *Self, text: ?[]const u8) void {
            self.error_mutex.lockUncancelable(self.io);
            if (self.error_text) |old| self.allocator.free(old);
            self.error_text = if (text) |t| (self.allocator.dupe(u8, t) catch null) else null;
            self.error_mutex.unlock(self.io);
            _ = self.error_version.fetchAdd(1, .release);
        }

        fn errorVersion(self: *Self) u32 {
            return self.error_version.load(.acquire);
        }

        fn copyError(self: *Self, allocator: std.mem.Allocator) ?[]u8 {
            self.error_mutex.lockUncancelable(self.io);
            defer self.error_mutex.unlock(self.io);
            const e = self.error_text orelse return null;
            return allocator.dupe(u8, e) catch null;
        }

        pub fn request(self: *Self) void {
            self.reload_requested.store(true, .release);
        }

        /// Argv (incl. argv0, minus `--restore`) used to relaunch the host on a
        /// schema change. Must outlive the coordinator. Without it, a schema edit
        /// keeps the current build instead of warm-restarting.
        pub fn setRelaunchArgv(self: *Self, argv: []const []const u8) void {
            self.relaunch_argv = argv;
        }

        fn pending(self: *Self) bool {
            return self.reload_requested.load(.acquire);
        }

        pub fn hook(self: *Self) App.ReloadHook {
            return .{
                .ctx = self,
                .pending_fn = pendingThunk,
                .perform_fn = performThunk,
                .request_fn = requestThunk,
                .error_version_fn = errorVersionThunk,
                .copy_error_fn = copyErrorThunk,
            };
        }

        fn pendingThunk(ctx: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.pending();
        }

        fn requestThunk(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.request();
        }

        fn errorVersionThunk(ctx: *anyopaque) u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.errorVersion();
        }

        fn copyErrorThunk(ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.copyError(allocator);
        }

        fn performThunk(ctx: *anyopaque, app: *App, needs_rebuild: *bool) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.perform(app, needs_rebuild);
        }

        fn copyToFreshGeneration(self: *Self) ![:0]const u8 {
            self.generation += 1;
            const dest = try std.fmt.allocPrintSentinel(
                self.allocator,
                "{s}.reload{d}",
                .{ self.lib_path, self.generation },
                0,
            );
            errdefer self.allocator.free(dest);
            try std.Io.Dir.copyFileAbsolute(self.lib_path, dest, self.io, .{ .replace = true });
            return dest;
        }

        fn perform(self: *Self, app: *App, needs_rebuild: *bool) !void {
            // A native dialog's callback points into the .so; defer rather than close
            // under it. reload_requested stays armed; the loop re-wakes when it closes.
            if (app.fileDialogPending()) {
                std.log.info("hotreload: file dialog open; deferring reload until it closes", .{});
                return;
            }
            self.reload_requested.store(false, .release);
            const t0 = std.Io.Clock.now(.awake, self.io);

            const new_copy = self.copyToFreshGeneration() catch |err| {
                std.log.err("hotreload: failed to copy new lib: {s}; keeping current", .{@errorName(err)});
                return;
            };
            var keep_copy = false;
            defer if (!keep_copy) {
                std.Io.Dir.deleteFileAbsolute(self.io, new_copy) catch {};
                self.allocator.free(new_copy);
            };

            const new_lib = dynlib.Library.open(new_copy.ptr) catch {
                std.log.err("hotreload: dlopen of new build failed; keeping current code", .{});
                return;
            };
            var keep_lib = false;
            defer if (!keep_lib) new_lib.close();

            const version = (new_lib.lookup(AbiVersionFn, abi_version_symbol) catch {
                std.log.err("hotreload: new lib missing {s}; keeping current", .{abi_version_symbol});
                return;
            })();
            const new_hash = (new_lib.lookup(AbiHashFn, abi_hash_symbol) catch {
                std.log.err("hotreload: new lib missing {s}; keeping current", .{abi_hash_symbol});
                return;
            })();

            if (version != abi.abi_version or new_hash != self.recorded_hash) {
                self.warmRestart(app);
                return;
            }

            const register = new_lib.lookup(RegisterFn, register_symbol) catch {
                std.log.err("hotreload: new lib missing {s}; keeping current", .{register_symbol});
                return;
            };

            drainQueues(app);

            app.tick_fn = null;
            app.tick_interval_s = null;
            app.ui.post_layout_hooks.clearRetainingCapacity();
            app.ui.interaction_registry.resetAllForReload();

            // Must free the tree (and its destroy_userdata/paint_fn into the old .so)
            // before dlclose. resetTreeDestructive leaves an empty placeholder root.
            _ = try app.ui.resetTreeDestructive();
            app.ui.animation_registry.clear();

            app.ui.interaction_registry.assertCleanForReload();
            std.debug.assert(app.ui.root.children.items.len == 0);
            std.debug.assert(app.ui.root.events.len == 0);

            self.lib.close();
            if (self.loaded_copy_path) |old| {
                std.Io.Dir.deleteFileAbsolute(self.io, old) catch {};
                self.allocator.free(old);
            }
            self.lib = new_lib;
            self.loaded_copy_path = new_copy;
            keep_lib = true;
            keep_copy = true;
            register(@ptrCast(app));

            try app.forceRemount();
            app.ui.requestLayout();
            app.ui.requestPaint();
            needs_rebuild.* = true;

            const elapsed_ms = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, self.io).nanoseconds - t0.nanoseconds)) / std.time.ns_per_ms;
            std.log.info("hotreload: same-process swap complete in {d:.1} ms (gen {d})", .{ elapsed_ms, self.generation });
        }

        fn warmRestart(self: *Self, app: *App) void {
            const relaunch = self.relaunch_argv orelse {
                std.log.warn("hotreload: schema changed but warm restart not configured; keeping current build", .{});
                return;
            };

            const StateT = @TypeOf(app.state);
            const json = snapshot.snapshotJsonAlloc(StateT, &app.state, self.allocator) catch |err| {
                std.log.err("hotreload: snapshot failed: {s}; keeping current build", .{@errorName(err)});
                return;
            };
            defer self.allocator.free(json);

            const tmp = std.fmt.allocPrint(self.allocator, "/tmp/ramiel-hotreload-{d}.json", .{std.c.getpid()}) catch return;
            defer self.allocator.free(tmp);
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = json }) catch |err| {
                std.log.err("hotreload: failed to write snapshot: {s}; keeping current build", .{@errorName(err)});
                return;
            };

            const argv = self.allocator.alloc([]const u8, relaunch.len + 2) catch return;
            defer self.allocator.free(argv);
            @memcpy(argv[0..relaunch.len], relaunch);
            argv[relaunch.len] = "--restore";
            argv[relaunch.len + 1] = tmp;

            std.log.info("hotreload: schema changed; warm-restarting host", .{});
            _ = std.process.spawn(self.io, .{ .argv = argv }) catch |err| {
                std.log.err("hotreload: relaunch spawn failed: {s}; keeping current build", .{@errorName(err)});
                return;
            };
            std.process.exit(0);
        }

        fn drainQueues(app: *App) void {
            app.cross_thread_mutex.lockUncancelable(app.io);
            for (app.cross_thread_queue.items) |msg| {
                app.ui.interaction_registry.message_queue.append(app.allocator, msg) catch {};
            }
            app.cross_thread_queue.clearRetainingCapacity();
            app.cross_thread_mutex.unlock(app.io);

            app.ui.interaction_registry.drainExternalMessages();

            for (app.ui.interaction_registry.message_queue.items) |msg| {
                _ = app.update_fn(app, msg);
            }
            app.ui.interaction_registry.message_queue.clearRetainingCapacity();
        }
    };
}
