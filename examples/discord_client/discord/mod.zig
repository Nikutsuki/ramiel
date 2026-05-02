const std = @import("std");

pub const models = @import("models.zig");
pub const rest = @import("rest.zig");
pub const guilds = @import("guilds.zig");
pub const channels = @import("channels.zig");
pub const users = @import("users.zig");
pub const cdn = @import("cdn.zig");

pub const Discord = struct {
    allocator: std.mem.Allocator,
    rest: *rest.RestClient,
    guilds: guilds.GuildClient,
    channels: channels.ChannelClient,
    users: users.UserClient,
    cdn: cdn.CdnClient,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, token: []const u8) !Discord {
        const rest_ptr = try allocator.create(rest.RestClient);
        errdefer allocator.destroy(rest_ptr);

        rest_ptr.* = try rest.RestClient.init(allocator, io, token);

        return .{
            .allocator = allocator,
            .rest = rest_ptr,
            .guilds = guilds.GuildClient.init(rest_ptr),
            .channels = channels.ChannelClient.init(rest_ptr),
            .users = users.UserClient.init(rest_ptr),
            .cdn = cdn.CdnClient.init(),
        };
    }

    pub fn deinit(self: *Discord) void {
        self.rest.deinit();
        self.allocator.destroy(self.rest);
    }
};
