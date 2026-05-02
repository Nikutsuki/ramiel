const std = @import("std");

pub const CdnClient = struct {
    pub fn init() CdnClient {
        return CdnClient{};
    }

    pub fn buildGuildIconUrl(self: CdnClient, allocator: std.mem.Allocator, guild_id: []const u8, icon_hash: []const u8) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(allocator, "https://cdn.discordapp.com/icons/{s}/{s}.png", .{ guild_id, icon_hash });
    }

    pub fn buildUserAvatarUrl(self: CdnClient, allocator: std.mem.Allocator, user_id: []const u8, avatar_hash: []const u8) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(allocator, "https://cdn.discordapp.com/avatars/{s}/{s}.png", .{ user_id, avatar_hash });
    }
};
