const std = @import("std");

pub const RestClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    token: []const u8,
    io: std.Io,

    pub const RequestOptions = struct {
        method: std.http.Method = .GET,
        payload: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, token: []const u8) !RestClient {
        return .{
            .allocator = allocator,
            .client = .{
                .allocator = allocator,
                .io = io,
            },
            .token = token,
            .io = io,
        };
    }

    pub fn deinit(self: *RestClient) void {
        self.client.deinit();
    }

    pub fn request(
        self: *RestClient,
        allocator: std.mem.Allocator,
        comptime T: type,
        path: []const u8,
        options: RequestOptions,
    ) !std.json.Parsed(T) {
        if (T == void) {
            @compileError("Use requestNoContent for endpoints that return no JSON body.");
        }

        var url_buffer = std.ArrayList(u8).empty;
        defer url_buffer.deinit(allocator);

        try url_buffer.appendSlice(allocator, "https://discord.com/api/v10");
        if (path[0] != '/') try url_buffer.append(allocator, '/');
        try url_buffer.appendSlice(allocator, path);

        var body_buffer: std.Io.Writer.Allocating = .init(allocator);
        defer body_buffer.deinit();

        const res = try self.client.fetch(.{
            .location = .{ .url = url_buffer.items },
            .method = options.method,
            .headers = .{
                .authorization = .{ .override = self.token },
                .user_agent = .{ .override = "Ramiel Discord Client (Zig 0.16.0)" },
                .content_type = if (options.payload != null) .{ .override = "application/json" } else .default,
            },
            .payload = options.payload,
            .response_writer = &body_buffer.writer,
        });

        if (!isSuccessStatus(res.status)) {
            std.debug.print("Discord API Error: {d}\nBody: {s}\n", .{ @intFromEnum(res.status), body_buffer.written() });
            return error.DiscordApiError;
        }

        const body = body_buffer.written();
        if (body.len == 0) {
            return error.EmptyDiscordResponse;
        }

        return std.json.parseFromSlice(T, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn requestNoContent(
        self: *RestClient,
        allocator: std.mem.Allocator,
        path: []const u8,
        options: RequestOptions,
    ) !void {
        var url_buffer = std.ArrayList(u8).empty;
        defer url_buffer.deinit(allocator);

        try url_buffer.appendSlice(allocator, "https://discord.com/api/v10");
        if (path[0] != '/') try url_buffer.append(allocator, '/');
        try url_buffer.appendSlice(allocator, path);

        var body_buffer: std.Io.Writer.Allocating = .init(allocator);
        defer body_buffer.deinit();

        const res = try self.client.fetch(.{
            .location = .{ .url = url_buffer.items },
            .method = options.method,
            .headers = .{
                .authorization = .{ .override = self.token },
                .user_agent = .{ .override = "Ramiel Discord Client (Zig 0.16.0)" },
                .content_type = if (options.payload != null) .{ .override = "application/json" } else .default,
            },
            .payload = options.payload,
            .response_writer = &body_buffer.writer,
        });

        if (!isSuccessStatus(res.status)) {
            std.debug.print("Discord API Error: {d}\nBody: {s}\n", .{ @intFromEnum(res.status), body_buffer.written() });
            return error.DiscordApiError;
        }
    }

    fn isSuccessStatus(status: std.http.Status) bool {
        return status == .ok or status == .created or status == .no_content;
    }
};
