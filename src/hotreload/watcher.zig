//! Source watcher: polls watched dirs' .zig mtimes, rebuilds, arms the coordinator.
//! mtime polling (not inotify) so it ports to Windows unchanged; the build is incremental.
const std = @import("std");
const coordinator_mod = @import("coordinator.zig");

pub fn Watcher(comptime App: type) type {
    return struct {
        const Self = @This();
        const Coordinator = coordinator_mod.Coordinator(App);

        allocator: std.mem.Allocator,
        io: std.Io,
        coordinator: *Coordinator,
        app: *App,
        dirs: [][]const u8,
        build_argv: [][]const u8,
        poll_interval_ms: i64 = 200,
        debounce_ms: i64 = 150,
        stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        task: ?std.Io.Future(void) = null,
        last_mtime_ns: i96 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            coordinator: *Coordinator,
            app: *App,
            dirs: []const []const u8,
            build_target: []const u8,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const dir_dupes = try allocator.alloc([]const u8, dirs.len);
            errdefer allocator.free(dir_dupes);
            var filled: usize = 0;
            errdefer for (dir_dupes[0..filled]) |d| allocator.free(d);
            for (dirs, 0..) |d, i| {
                dir_dupes[i] = try allocator.dupe(u8, d);
                filled = i + 1;
            }

            const argv = try allocator.alloc([]const u8, 6);
            errdefer allocator.free(argv);
            argv[0] = "zig";
            argv[1] = "build";
            argv[2] = try allocator.dupe(u8, build_target);
            argv[3] = "-Dhot-reload";
            argv[4] = "--color";
            argv[5] = "off";

            self.* = .{
                .allocator = allocator,
                .io = io,
                .coordinator = coordinator,
                .app = app,
                .dirs = dir_dupes,
                .build_argv = argv,
            };
            self.last_mtime_ns = self.scanMaxMtime();
            return self;
        }

        pub fn start(self: *Self) !void {
            self.task = try self.io.concurrent(runEntry, .{self});
        }

        fn runEntry(self: *Self) void {
            self.run();
        }

        pub fn deinit(self: *Self) void {
            self.stop_flag.store(true, .release);
            if (self.task) |*t| {
                t.cancel(self.io);
                _ = t.await(self.io);
                self.task = null;
            }
            for (self.dirs) |d| self.allocator.free(d);
            self.allocator.free(self.dirs);
            self.allocator.free(self.build_argv[2]);
            self.allocator.free(self.build_argv);
            self.allocator.destroy(self);
        }

        fn run(self: *Self) void {
            while (!self.stop_flag.load(.acquire)) {
                std.Io.sleep(self.io, .fromMilliseconds(self.poll_interval_ms), .awake) catch return;
                if (self.stop_flag.load(.acquire)) return;

                const m = self.scanMaxMtime();
                if (m <= self.last_mtime_ns) continue;

                std.Io.sleep(self.io, .fromMilliseconds(self.debounce_ms), .awake) catch return;
                const m2 = self.scanMaxMtime();
                self.last_mtime_ns = m2;
                if (m2 != m) continue;

                self.rebuild();
            }
        }

        fn scanMaxMtime(self: *Self) i96 {
            var max: i96 = self.last_mtime_ns;
            for (self.dirs) |d| {
                var dir = std.Io.Dir.cwd().openDir(self.io, d, .{ .iterate = true }) catch continue;
                defer dir.close(self.io);
                var walker = dir.walk(self.allocator) catch continue;
                defer walker.deinit();
                while (walker.next(self.io) catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                    const st = entry.dir.statFile(self.io, entry.basename, .{}) catch continue;
                    if (st.mtime.nanoseconds > max) max = st.mtime.nanoseconds;
                }
            }
            return max;
        }

        fn rebuild(self: *Self) void {
            std.log.info("hotreload: change detected, rebuilding ({s})...", .{self.build_argv[2]});
            const result = std.process.run(self.allocator, self.io, .{ .argv = self.build_argv }) catch |err| {
                std.log.err("hotreload: failed to run build: {s}", .{@errorName(err)});
                return;
            };
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            const ok = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok) {
                self.coordinator.setBuildError(null);
                self.coordinator.request();
                self.app.postEmptyEvent();
                std.log.info("hotreload: rebuild ok; reload armed", .{});
            } else {
                std.log.err("hotreload: build failed; keeping current code\n{s}", .{result.stderr});
                self.coordinator.setBuildError(result.stderr);
                self.app.postEmptyEvent();
            }
        }
    };
}
