const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const DEFAULT_DLL_NAME = if (@sizeOf(usize) == 8) "Everything64.dll" else "Everything32.dll";
const RELATIVE_BUNDLED_DLL_PATH = std.fmt.comptimePrint("examples/overlay/thirdparty/Everything-SDK/dll/{s}", .{DEFAULT_DLL_NAME});
const RELATIVE_LOCAL_DLL_PATH = std.fmt.comptimePrint("thirdparty/Everything-SDK/dll/{s}", .{DEFAULT_DLL_NAME});

pub const SearchResult = struct {
    filename: []u8,
    full_path: []u8,
    is_folder: bool,
};

pub const ReadyCallback = *const fn (ctx: ?*anyopaque) void;

pub const InitOptions = struct {
    max_results: u32 = 200,
    dll_name: ?[]const u8 = null,
    on_results_ready: ?ReadyCallback = null,
    on_results_ready_ctx: ?*anyopaque = null,
};

pub const SearchSubsystem = struct {
    const Self = @This();

    owner_allocator: std.mem.Allocator,
    worker_allocator: std.mem.Allocator = std.heap.smp_allocator,
    io: std.Io = std.Options.debug_io,

    dll_handle: *anyopaque,
    api: Api,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    worker_thread: std.Thread = undefined,

    pending_query: std.ArrayList(u8) = .empty,
    shutdown_flag: bool = false,

    arenas: [2]std.heap.ArenaAllocator,
    active_arena_index: usize = 0,

    latest_results: []SearchResult = &.{},
    latest_total_hits: usize = 0,

    max_results: u32,
    on_results_ready: ?ReadyCallback = null,
    on_results_ready_ctx: ?*anyopaque = null,

    pub fn init(owner_allocator: std.mem.Allocator, options: InitOptions) !*Self {
        if (comptime !is_windows) {
            return error.UnsupportedPlatform;
        } else {
            const dll_handle = loadEverythingDll(options.dll_name) orelse return error.DllLoadFailed;
            errdefer _ = kernel32.FreeLibrary(dll_handle);

            const api = try Api.load(dll_handle);

            const self = try owner_allocator.create(Self);
            self.* = .{
                .owner_allocator = owner_allocator,
                .dll_handle = dll_handle,
                .api = api,
                .arenas = .{
                    std.heap.ArenaAllocator.init(std.heap.smp_allocator),
                    std.heap.ArenaAllocator.init(std.heap.smp_allocator),
                },
                .max_results = @max(options.max_results, 1),
                .on_results_ready = options.on_results_ready,
                .on_results_ready_ctx = options.on_results_ready_ctx,
            };

            self.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});
            return self;
        }
    }

    fn loadEverythingDll(explicit: ?[]const u8) ?*anyopaque {
        if (explicit) |path| {
            if (tryLoadLibrary(path)) |handle| return handle;
        }

        const candidates = [_][]const u8{
            RELATIVE_BUNDLED_DLL_PATH,
            RELATIVE_LOCAL_DLL_PATH,
            DEFAULT_DLL_NAME,
        };

        for (candidates) |path| {
            if (tryLoadLibrary(path)) |handle| return handle;
        }

        return null;
    }

    fn tryLoadLibrary(path: []const u8) ?*anyopaque {
        const path_utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, path) catch return null;
        defer std.heap.smp_allocator.free(path_utf16);

        return kernel32.LoadLibraryW(path_utf16.ptr);
    }

    pub fn deinit(self: *Self) void {
        if (comptime !is_windows) {
            return;
        } else {
            self.mutex.lockUncancelable(self.io);
            self.shutdown_flag = true;
            self.mutex.unlock(self.io);

            self.cond.signal(self.io);
            self.worker_thread.join();

            self.pending_query.deinit(self.worker_allocator);
            self.arenas[0].deinit();
            self.arenas[1].deinit();
            _ = kernel32.FreeLibrary(self.dll_handle);
            self.owner_allocator.destroy(self);
        }
    }

    pub fn setReadyCallback(self: *Self, cb: ?ReadyCallback, ctx: ?*anyopaque) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.on_results_ready = cb;
        self.on_results_ready_ctx = ctx;
    }

    pub fn submitQuery(self: *Self, query: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.pending_query.clearRetainingCapacity();
        try self.pending_query.appendSlice(self.worker_allocator, query);
        self.cond.signal(self.io);
    }

    pub fn copyLatestResults(self: *Self, allocator: std.mem.Allocator, max_items: usize) ![]SearchResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const count = @min(self.latest_results.len, max_items);
        if (count == 0) return &.{};

        var out = try allocator.alloc(SearchResult, count);
        var copied: usize = 0;
        errdefer {
            for (out[0..copied]) |item| {
                allocator.free(item.filename);
                allocator.free(item.full_path);
            }
            allocator.free(out);
        }

        while (copied < count) : (copied += 1) {
            const src = self.latest_results[copied];
            out[copied] = .{
                .filename = try allocator.dupe(u8, src.filename),
                .full_path = try allocator.dupe(u8, src.full_path),
                .is_folder = src.is_folder,
            };
        }

        return out;
    }

    pub fn latestTotalHits(self: *Self) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.latest_total_hits;
    }

    fn workerLoop(self: *Self) void {
        var local_query = std.ArrayList(u8).empty;
        defer local_query.deinit(self.worker_allocator);

        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.pending_query.items.len == 0 and !self.shutdown_flag) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }

            if (self.shutdown_flag) {
                self.mutex.unlock(self.io);
                return;
            }

            local_query.clearRetainingCapacity();
            local_query.appendSlice(self.worker_allocator, self.pending_query.items) catch {
                self.pending_query.clearRetainingCapacity();
                self.mutex.unlock(self.io);
                continue;
            };
            self.pending_query.clearRetainingCapacity();
            self.mutex.unlock(self.io);

            self.executeQuery(local_query.items) catch |err| {
                std.log.err("Everything query failed: {s}", .{@errorName(err)});
                self.publishEmptyResults();
            };
        }
    }

    fn executeQuery(self: *Self, query_utf8: []const u8) !void {
        const build_index: usize = if (self.active_arena_index == 0) 1 else 0;
        _ = self.arenas[build_index].reset(.retain_capacity);
        const alloc = self.arenas[build_index].allocator();

        const query_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, query_utf8);

        self.api.set_max(self.max_results);
        self.api.set_search_w(query_utf16.ptr);

        if (self.api.query_w(1) == 0) {
            const last_err = self.api.get_last_error();
            std.log.err("Everything_QueryW failed with code {d}", .{last_err});
            return error.QueryFailed;
        }

        const total_hits: usize = @intCast(self.api.get_num_results());
        const display_count: usize = @min(total_hits, @as(usize, self.max_results));

        var results = std.ArrayList(SearchResult).empty;

        for (0..display_count) |i| {
            const file_name_ptr = self.api.get_result_file_name_w(@intCast(i));
            const dir_path_ptr = self.api.get_result_path_w(@intCast(i));
            const is_folder = self.api.is_folder_result(@intCast(i)) != 0;

            const filename_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(file_name_ptr));
            const dir_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(dir_path_ptr));
            const full_path_utf8 = try joinPathUtf8(alloc, dir_utf8, filename_utf8);

            try results.append(alloc, .{
                .filename = filename_utf8,
                .full_path = full_path_utf8,
                .is_folder = is_folder,
            });
        }

        self.mutex.lockUncancelable(self.io);
        self.latest_results = results.items;
        self.latest_total_hits = total_hits;
        self.active_arena_index = build_index;
        const cb = self.on_results_ready;
        const cb_ctx = self.on_results_ready_ctx;
        self.mutex.unlock(self.io);

        if (cb) |f| {
            f(cb_ctx);
        }
    }

    fn publishEmptyResults(self: *Self) void {
        const build_index: usize = if (self.active_arena_index == 0) 1 else 0;
        _ = self.arenas[build_index].reset(.retain_capacity);

        self.mutex.lockUncancelable(self.io);
        self.latest_results = &.{};
        self.latest_total_hits = 0;
        self.active_arena_index = build_index;
        const cb = self.on_results_ready;
        const cb_ctx = self.on_results_ready_ctx;
        self.mutex.unlock(self.io);

        if (cb) |f| {
            f(cb_ctx);
        }
    }
};

pub fn bundledDllHintPath() []const u8 {
    return RELATIVE_BUNDLED_DLL_PATH;
}

pub fn freeResultSlice(allocator: std.mem.Allocator, results: []SearchResult) void {
    if (results.len == 0) return;

    for (results) |item| {
        allocator.free(item.filename);
        allocator.free(item.full_path);
    }
    allocator.free(results);
}

fn joinPathUtf8(allocator: std.mem.Allocator, dir: []const u8, file: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, file);
    if (file.len == 0) return allocator.dupe(u8, dir);

    const last = dir[dir.len - 1];
    if (last == '\\' or last == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, file });
    }
    return std.fmt.allocPrint(allocator, "{s}\\{s}", .{ dir, file });
}

const Api = struct {
    set_search_w: *const fn (query: [*:0]const u16) callconv(.c) void,
    query_w: *const fn (wait: c_int) callconv(.c) c_int,
    set_max: *const fn (max_results: u32) callconv(.c) void,
    get_num_results: *const fn () callconv(.c) u32,
    get_result_file_name_w: *const fn (index: u32) callconv(.c) [*:0]const u16,
    get_result_path_w: *const fn (index: u32) callconv(.c) [*:0]const u16,
    is_folder_result: *const fn (index: u32) callconv(.c) c_int,
    get_last_error: *const fn () callconv(.c) u32,

    fn load(dll_handle: *anyopaque) !Api {
        return .{
            .set_search_w = try lookupRequired(dll_handle, *const fn ([*:0]const u16) callconv(.c) void, "Everything_SetSearchW"),
            .query_w = try lookupRequired(dll_handle, *const fn (c_int) callconv(.c) c_int, "Everything_QueryW"),
            .set_max = try lookupRequired(dll_handle, *const fn (u32) callconv(.c) void, "Everything_SetMax"),
            .get_num_results = try lookupRequired(dll_handle, *const fn () callconv(.c) u32, "Everything_GetNumResults"),
            .get_result_file_name_w = try lookupRequired(dll_handle, *const fn (u32) callconv(.c) [*:0]const u16, "Everything_GetResultFileNameW"),
            .get_result_path_w = try lookupRequired(dll_handle, *const fn (u32) callconv(.c) [*:0]const u16, "Everything_GetResultPathW"),
            .is_folder_result = try lookupRequired(dll_handle, *const fn (u32) callconv(.c) c_int, "Everything_IsFolderResult"),
            .get_last_error = try lookupRequired(dll_handle, *const fn () callconv(.c) u32, "Everything_GetLastError"),
        };
    }
};

fn lookupRequired(dll_handle: *anyopaque, comptime T: type, name: [:0]const u8) !T {
    const proc = kernel32.GetProcAddress(dll_handle, name.ptr) orelse {
        std.log.err("Missing Everything symbol: {s}", .{name});
        return error.MissingSymbol;
    };

    return @as(T, @ptrCast(proc));
}

const kernel32 = struct {
    extern "kernel32" fn LoadLibraryW(file_name: [*:0]const u16) callconv(.c) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.c) c_int;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, proc_name: [*:0]const u8) callconv(.c) ?*anyopaque;
};

const shell32 = struct {
    extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        operation: ?[*:0]const u16,
        file: [*:0]const u16,
        parameters: ?[*:0]const u16,
        directory: ?[*:0]const u16,
        show_cmd: c_int,
    ) callconv(.c) ?*anyopaque;
};

const OPEN_VERB = std.unicode.utf8ToUtf16LeStringLiteral("open");
const SW_SHOWNORMAL: c_int = 1;

pub fn openPath(path: []const u8) !void {
    if (comptime !is_windows) {
        return error.UnsupportedPlatform;
    } else {
        const path_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, path);
        defer std.heap.smp_allocator.free(path_utf16);

        const result = shell32.ShellExecuteW(null, OPEN_VERB, path_utf16.ptr, null, null, SW_SHOWNORMAL) orelse {
            return error.OpenFileFailed;
        };

        if (@intFromPtr(result) <= 32) {
            return error.OpenFileFailed;
        }
    }
}
