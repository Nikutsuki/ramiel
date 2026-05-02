const std = @import("std");
const core = @import("core.zig");
const filters = @import("filters.zig");

pub const FilterWorkerPool = struct {
    allocator: std.mem.Allocator,
    app: *core.App,
    io: std.Io = std.Options.debug_io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    shutdown: bool = false,
    has_job: bool = false,
    is_busy: bool = false,
    result_ready: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    filter: ?filters.FilterKind = null,
    param_count: usize = 0,
    params: [64]f32 = [_]f32{0.0} ** 64,
    has_mask: bool = false,
    has_aux: bool = false,
    completed_filter: ?filters.FilterKind = null,
    input: std.ArrayList(u8) = .empty,
    mask: std.ArrayList(u8) = .empty,
    aux: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, app: *core.App) !*FilterWorkerPool {
        const self = try allocator.create(FilterWorkerPool);
        self.* = .{ .allocator = allocator, .app = app };
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        return self;
    }

    pub fn deinit(self: *FilterWorkerPool) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);

        if (self.thread) |thread| thread.join();
        self.input.deinit(self.allocator);
        self.mask.deinit(self.allocator);
        self.aux.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn submit(
        self: *FilterWorkerPool,
        input_pixels: []const u8,
        mask: ?[]const u8,
        aux: ?[]const u8,
        width: u32,
        height: u32,
        filter: filters.FilterKind,
        parameters: []const f32,
    ) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_busy or self.has_job or self.result_ready) return false;
        try self.input.resize(self.allocator, input_pixels.len);
        @memcpy(self.input.items, input_pixels);
        try self.output.resize(self.allocator, input_pixels.len);
        if (mask) |m| {
            self.has_mask = true;
            try self.mask.resize(self.allocator, m.len);
            @memcpy(self.mask.items, m);
        } else {
            self.has_mask = false;
        }
        if (aux) |a| {
            self.has_aux = true;
            try self.aux.resize(self.allocator, a.len);
            @memcpy(self.aux.items, a);
        } else {
            self.has_aux = false;
        }

        self.width = width;
        self.height = height;
        self.filter = filter;
        self.param_count = @min(parameters.len, self.params.len);
        @memset(self.params[0..], 0.0);
        if (self.param_count > 0) {
            @memcpy(self.params[0..self.param_count], parameters[0..self.param_count]);
        }
        self.result_ready = false;
        self.completed_filter = null;
        self.is_busy = true;
        self.has_job = true;
        self.cond.signal(self.io);
        return true;
    }

    pub fn copyCompletedInto(self: *FilterWorkerPool, dst: []u8, completed_kind: *?filters.FilterKind) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.result_ready) return false;
        if (dst.len != self.output.items.len) return false;

        @memcpy(dst, self.output.items);
        self.result_ready = false;
        completed_kind.* = self.completed_filter;
        self.completed_filter = null;
        return true;
    }

    fn workerLoop(self: *FilterWorkerPool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.has_job and !self.shutdown) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }

            const width = self.width;
            const height = self.height;
            const maybe_filter = self.filter;
            const local_param_count = self.param_count;
            var local_params: [64]f32 = [_]f32{0.0} ** 64;
            if (local_param_count > 0) {
                @memcpy(local_params[0..local_param_count], self.params[0..local_param_count]);
            }
            const maybe_mask: ?[]const u8 = if (self.has_mask) self.mask.items else null;
            const maybe_aux: ?[]const u8 = if (self.has_aux) self.aux.items else null;
            self.has_job = false;
            self.mutex.unlock(self.io);

            const filter = maybe_filter orelse {
                self.mutex.lockUncancelable(self.io);
                self.is_busy = false;
                self.mutex.unlock(self.io);
                continue;
            };

            executeFilterWorker(
                self.input.items,
                maybe_mask,
                maybe_aux,
                self.output.items,
                width,
                height,
                filter,
                local_params[0..local_param_count],
            );

            self.mutex.lockUncancelable(self.io);
            self.is_busy = false;
            self.result_ready = true;
            self.completed_filter = filter;
            self.mutex.unlock(self.io);
            self.app.postMessageId(.{ .filter_done = {} });
        }
    }
};

fn executeFilterWorker(
    input_pixels: []const u8,
    mask: ?[]const u8,
    aux: ?[]const u8,
    output_buffer: []u8,
    width: u32,
    height: u32,
    filter: filters.FilterKind,
    parameters: []const f32,
) void {
    const fn_ptr = filters.getFilter(filter);
    const ctx = filters.FilterContext{
        .width = width,
        .height = height,
        .input = input_pixels,
        .mask = mask,
        .aux = aux,
        .output = output_buffer,
        .parameters = parameters,
    };
    fn_ptr(ctx);
}

