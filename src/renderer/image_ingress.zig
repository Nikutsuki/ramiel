const std = @import("std");
const TextureRegistry = @import("vulkan/texture_registry.zig").TextureRegistry;

pub const ImageIngressBudget = struct {
    max_inflight_requests: usize = 512,
    max_inflight_bytes: usize = 1024 * 1024 * 1024,
    max_pending_upload_bytes: usize = TextureRegistry.DEFAULT_DYNAMIC_BUDGET_BYTES,
};

pub const ImageIngress = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    budget: ImageIngressBudget,

    request_mutex: std.Io.Mutex = .init,
    in_flight: std.StringHashMap(void),
    in_flight_bytes: usize = 0,

    task_group: std.Io.Group = .init,
    http_client: std.http.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        budget: ImageIngressBudget,
    ) ImageIngress {
        var http_client = std.http.Client{
            .allocator = allocator,
            .io = io,
        };

        http_client.ca_bundle.rescan(allocator, io, std.Io.Timestamp.now(io, .awake)) catch {};

        return .{
            .allocator = allocator,
            .io = io,
            .budget = budget,
            .in_flight = std.StringHashMap(void).init(allocator),
            .http_client = http_client,
        };
    }

    pub fn deinit(self: *ImageIngress) void {
        self.task_group.cancel(self.io);
        self.http_client.deinit();

        var req_it = self.in_flight.iterator();
        while (req_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.in_flight.deinit();
    }

    pub fn loadImageFromDiskAsync(
        self: *ImageIngress,
        texture_registry: *TextureRegistry,
        name: []const u8,
        path: []const u8,
        target_width: u32,
        target_height: u32,
    ) !void {
        const state = texture_registry.getImageState(name);
        if (state == .ready or state == .decoding) return;

        const in_flight_key = (try self.beginRequest(name, 0)) orelse return;
        errdefer self.finishRequest(in_flight_key, 0);

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        self.task_group.concurrent(
            self.io,
            loadDiskImageTask,
            .{
                self,
                texture_registry,
                in_flight_key,
                name_copy,
                path_copy,
                target_width,
                target_height,
            },
        ) catch self.task_group.async(
            self.io,
            loadDiskImageTask,
            .{
                self,
                texture_registry,
                in_flight_key,
                name_copy,
                path_copy,
                target_width,
                target_height,
            },
        );
    }

    pub fn loadImageFromUrlAsync(
        self: *ImageIngress,
        texture_registry: *TextureRegistry,
        name: []const u8,
        url: []const u8,
        target_width: u32,
        target_height: u32,
    ) !void {
        const state = texture_registry.getImageState(name);
        if (state == .ready or state == .decoding) return;

        const in_flight_key = (try self.beginRequest(name, 0)) orelse return;
        errdefer self.finishRequest(in_flight_key, 0);

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);

        _ = self.task_group.concurrent(self.io, loadUrlImageTask, .{
            self,
            texture_registry,
            in_flight_key,
            name_copy,
            url_copy,
            target_width,
            target_height,
        }) catch self.task_group.async(self.io, loadUrlImageTask, .{
            self,
            texture_registry,
            in_flight_key,
            name_copy,
            url_copy,
            target_width,
            target_height,
        });
    }

    fn loadDiskImageTask(
        self: *ImageIngress,
        texture_registry: *TextureRegistry,
        in_flight_key: []const u8,
        name: []u8,
        path: []u8,
        target_width: u32,
        target_height: u32,
    ) void {
        defer self.allocator.free(name);
        defer self.allocator.free(path);
        var accounted_bytes: usize = 0;
        const bytes = std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            self.io,
            path,
            self.allocator,
            .unlimited,
        ) catch |err| {
            std.log.warn(
                "image_ingress: disk read failed name='{s}' path='{s}' err={s}",
                .{ name, path, @errorName(err) },
            );
            texture_registry.markImageMissing(name) catch {};
            self.finishRequest(in_flight_key, 0);
            return;
        };
        defer self.allocator.free(bytes);
        accounted_bytes = bytes.len;

        texture_registry.pushImageDataWithHint(
            name,
            bytes,
            target_width,
            target_height,
        ) catch |err| {
            std.log.warn(
                "image_ingress: push disk data failed name='{s}' path='{s}' err={s}",
                .{ name, path, @errorName(err) },
            );
            texture_registry.markImageMissing(name) catch {};
        };
        self.finishRequest(in_flight_key, accounted_bytes);
    }

    fn loadUrlImageTask(
        self: *ImageIngress,
        texture_registry: *TextureRegistry,
        in_flight_key: []const u8,
        name: []u8,
        url: []u8,
        target_width: u32,
        target_height: u32,
    ) void {
        defer self.allocator.free(name);
        defer self.allocator.free(url);

        var body_buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buffer.deinit();

        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body_buffer.writer,
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "Discord/2.0 (Ramiel)" },
            },
        }) catch |err| {
            std.log.warn(
                "image_ingress: HTTP fetch failed name='{s}' url='{s}' err={s}",
                .{ name, url, @errorName(err) },
            );
            texture_registry.markImageMissing(name) catch {};
            self.finishRequest(in_flight_key, 0);
            return;
        };

        if (fetch_result.status != .ok) {
            std.log.warn(
                "image_ingress: HTTP status not ok name='{s}' url='{s}' status={d}",
                .{ name, url, @intFromEnum(fetch_result.status) },
            );
            texture_registry.markImageMissing(name) catch {};
            self.finishRequest(in_flight_key, 0);
            return;
        }

        const bytes = body_buffer.written();
        if (bytes.len == 0) {
            std.log.warn(
                "image_ingress: HTTP body empty name='{s}' url='{s}'",
                .{ name, url },
            );
            texture_registry.markImageMissing(name) catch {};
            self.finishRequest(in_flight_key, 0);
            return;
        }

        texture_registry.pushImageDataWithHint(
            name,
            bytes,
            target_width,
            target_height,
        ) catch |err| {
            std.log.warn(
                "image_ingress: push url data failed name='{s}' url='{s}' err={s}",
                .{ name, url, @errorName(err) },
            );
            texture_registry.markImageMissing(name) catch {};
        };
        self.finishRequest(in_flight_key, bytes.len);
    }

    fn beginRequest(self: *ImageIngress, name: []const u8, estimated_bytes: usize) !?[]const u8 {
        self.request_mutex.lockUncancelable(self.io);
        defer self.request_mutex.unlock(self.io);

        if (self.in_flight.count() >= self.budget.max_inflight_requests) {
            std.log.warn(
                "image_ingress: in-flight request cap reached name='{s}' count={d}/{d}",
                .{ name, self.in_flight.count(), self.budget.max_inflight_requests },
            );
            return error.TooManyPendingImageRequests;
        }
        if (self.budget.max_inflight_bytes > 0 and self.in_flight_bytes + estimated_bytes > self.budget.max_inflight_bytes) {
            std.log.warn(
                "image_ingress: byte backpressure name='{s}' in_flight={d} requested={d} cap={d}",
                .{ name, self.in_flight_bytes, estimated_bytes, self.budget.max_inflight_bytes },
            );
            return error.ImageIngressBackpressure;
        }

        if (self.in_flight.contains(name)) return null;

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.in_flight.put(key, {});
        self.in_flight_bytes += estimated_bytes;
        return key;
    }

    fn finishRequest(self: *ImageIngress, in_flight_key: []const u8, accounted_bytes: usize) void {
        self.request_mutex.lockUncancelable(self.io);
        defer self.request_mutex.unlock(self.io);
        _ = self.in_flight.remove(in_flight_key);
        self.allocator.free(in_flight_key);
        self.in_flight_bytes -|= accounted_bytes;
    }
};
