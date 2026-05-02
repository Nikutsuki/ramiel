const std = @import("std");
const models = @import("models.zig");
const rest = @import("rest.zig");

pub const UserClient = struct {
    rest_client: *rest.RestClient,

    pub fn init(rest_client: *rest.RestClient) UserClient {
        return .{ .rest_client = rest_client };
    }

    pub fn fetchMe(self: *UserClient, allocator: std.mem.Allocator) !std.json.Parsed(models.User) {
        return self.rest_client.request(allocator, models.User, "/users/@me", .{});
    }

    pub fn fetchDMs(self: *UserClient, allocator: std.mem.Allocator) !std.json.Parsed([]models.Channel) {
        return self.rest_client.request(allocator, []models.Channel, "/users/@me/channels", .{});
    }

    pub fn createDM(self: *UserClient, allocator: std.mem.Allocator, recipient_user_id: []const u8) !std.json.Parsed(models.Channel) {
        const payload_struct = struct {
            recipient_id: []const u8,
        }{ .recipient_id = recipient_user_id };

        var payload_buffer: std.Io.Writer.Allocating = .init(allocator);
        defer payload_buffer.deinit();

        try std.json.Stringify.value(payload_struct, .{}, &payload_buffer.writer);

        return self.rest_client.request(allocator, models.Channel, "/users/@me/channels", .{
            .method = .POST,
            .payload = payload_buffer.written(),
        });
    }

    pub fn fetchUser(self: *UserClient, allocator: std.mem.Allocator, user_id: []const u8) !std.json.Parsed(models.User) {
        const path = try std.fmt.allocPrint(allocator, "/users/{s}", .{user_id});
        defer allocator.free(path);
        return self.rest_client.request(allocator, models.User, path, .{});
    }
};
