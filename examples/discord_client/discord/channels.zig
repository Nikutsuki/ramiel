const std = @import("std");
const models = @import("models.zig");
const rest = @import("rest.zig");

pub const ChannelClient = struct {
    rest_client: *rest.RestClient,

    pub const FetchMessagesOptions = struct {
        limit: ?u8 = 50,
        before: ?[]const u8 = null,
        after: ?[]const u8 = null,
        around: ?[]const u8 = null,
    };

    pub fn init(rest_client: *rest.RestClient) ChannelClient {
        return .{ .rest_client = rest_client };
    }

    pub fn fetchMessages(
        self: *ChannelClient,
        allocator: std.mem.Allocator,
        channel_id: []const u8,
        options: FetchMessagesOptions,
    ) !std.json.Parsed([]models.Message) {
        const limit = options.limit orelse 50;
        var path = try std.fmt.allocPrint(allocator, "/channels/{s}/messages?limit={d}", .{ channel_id, limit });
        defer allocator.free(path);

        if (options.before) |before_id| {
            const next = try std.fmt.allocPrint(allocator, "{s}&before={s}", .{ path, before_id });
            allocator.free(path);
            path = next;
        }
        if (options.after) |after_id| {
            const next = try std.fmt.allocPrint(allocator, "{s}&after={s}", .{ path, after_id });
            allocator.free(path);
            path = next;
        }
        if (options.around) |around_id| {
            const next = try std.fmt.allocPrint(allocator, "{s}&around={s}", .{ path, around_id });
            allocator.free(path);
            path = next;
        }

        return self.rest_client.request(allocator, []models.Message, path, .{});
    }

    pub fn sendMessage(
        self: *ChannelClient,
        allocator: std.mem.Allocator,
        channel_id: []const u8,
        content: []const u8,
    ) !std.json.Parsed(models.Message) {
        const payload_struct = struct {
            content: []const u8,
        }{ .content = content };

        var payload_buffer: std.Io.Writer.Allocating = .init(allocator);
        defer payload_buffer.deinit();

        try std.json.Stringify.value(payload_struct, .{}, &payload_buffer.writer);

        const path = try std.fmt.allocPrint(allocator, "/channels/{s}/messages", .{channel_id});
        defer allocator.free(path);

        return self.rest_client.request(allocator, models.Message, path, .{
            .method = .POST,
            .payload = payload_buffer.written(),
        });
    }

    pub fn fetchChannel(self: *ChannelClient, allocator: std.mem.Allocator, channel_id: []const u8) !std.json.Parsed(models.Channel) {
        const path = try std.fmt.allocPrint(allocator, "/channels/{s}", .{channel_id});
        defer allocator.free(path);
        return self.rest_client.request(allocator, models.Channel, path, .{});
    }

    pub fn fetchPinnedMessages(
        self: *ChannelClient,
        allocator: std.mem.Allocator,
        channel_id: []const u8,
    ) !std.json.Parsed([]models.Message) {
        const path = try std.fmt.allocPrint(allocator, "/channels/{s}/pins", .{channel_id});
        defer allocator.free(path);
        return self.rest_client.request(allocator, []models.Message, path, .{});
    }

    pub fn deleteMessage(
        self: *ChannelClient,
        allocator: std.mem.Allocator,
        channel_id: []const u8,
        message_id: []const u8,
    ) !void {
        const path = try std.fmt.allocPrint(allocator, "/channels/{s}/messages/{s}", .{ channel_id, message_id });
        defer allocator.free(path);
        try self.rest_client.requestNoContent(allocator, path, .{ .method = .DELETE });
    }

    pub fn startTyping(self: *ChannelClient, allocator: std.mem.Allocator, channel_id: []const u8) !void {
        const path = try std.fmt.allocPrint(allocator, "/channels/{s}/typing", .{channel_id});
        defer allocator.free(path);
        try self.rest_client.requestNoContent(allocator, path, .{ .method = .POST });
    }
};
