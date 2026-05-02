const std = @import("std");
const models = @import("models.zig");
const rest = @import("rest.zig");

pub const GuildClient = struct {
    rest_client: *rest.RestClient,

    pub fn init(rest_client: *rest.RestClient) GuildClient {
        return .{ .rest_client = rest_client };
    }

    pub fn fetchMeGuilds(self: *GuildClient, allocator: std.mem.Allocator) !std.json.Parsed([]models.Guild) {
        return self.rest_client.request(allocator, []models.Guild, "/users/@me/guilds", .{});
    }

    pub fn fetchGuild(self: *GuildClient, allocator: std.mem.Allocator, guild_id: []const u8) !std.json.Parsed(models.Guild) {
        const path = try std.fmt.allocPrint(allocator, "/guilds/{s}", .{guild_id});
        defer allocator.free(path);
        return self.rest_client.request(allocator, models.Guild, path, .{});
    }

    pub fn fetchGuildChannels(self: *GuildClient, allocator: std.mem.Allocator, guild_id: []const u8) !std.json.Parsed([]models.Channel) {
        const path = try std.fmt.allocPrint(allocator, "/guilds/{s}/channels", .{guild_id});
        defer allocator.free(path);
        return self.rest_client.request(allocator, []models.Channel, path, .{});
    }

    pub fn fetchGuildRoles(self: *GuildClient, allocator: std.mem.Allocator, guild_id: []const u8) !std.json.Parsed([]models.Role) {
        const path = try std.fmt.allocPrint(allocator, "/guilds/{s}/roles", .{guild_id});
        defer allocator.free(path);
        return self.rest_client.request(allocator, []models.Role, path, .{});
    }
};
