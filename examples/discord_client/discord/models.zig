const std = @import("std");

pub const User = struct {
    id: []const u8,
    username: []const u8 = "",
    discriminator: ?[]const u8 = null,
    global_name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,

    bot: bool = false,

    pub fn displayName(self: User) []const u8 {
        if (self.global_name) |name| {
            if (name.len > 0) return name;
        }
        if (self.username.len > 0) return self.username;
        return "unknown-user";
    }
};

pub const Guild = struct {
    id: []const u8,
    name: []const u8,
    icon: ?[]const u8 = null,
    owner: ?bool = null,
    owner_id: ?[]const u8 = null,
    permissions: ?[]const u8 = null,
    features: ?[][]const u8 = null,
    description: ?[]const u8 = null,
    preferred_locale: ?[]const u8 = null,
    premium_tier: ?u8 = null,
    max_presences: ?u32 = null,
    max_members: ?u32 = null,
    approximate_member_count: ?u32 = null,
    approximate_presence_count: ?u32 = null,
};

pub const Role = struct {
    id: []const u8,
    name: []const u8,
    color: u32 = 0,
    position: i32 = 0,
    permissions: []const u8 = "0",
    managed: bool = false,
    mentionable: bool = false,
};

pub const Channel = struct {
    id: []const u8,
    type: u8,
    guild_id: ?[]const u8 = null,
    position: ?i32 = null,
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    nsfw: ?bool = null,
    last_message_id: ?[]const u8 = null,
    rate_limit_per_user: ?u32 = null,
    recipients: ?[]User = null,
    parent_id: ?[]const u8 = null,

    pub fn displayName(self: Channel) []const u8 {
        if (self.name) |channel_name| {
            if (channel_name.len > 0) return channel_name;
        }
        if (self.recipients) |recipients| {
            if (recipients.len > 0) {
                return recipients[0].displayName();
            }
        }
        return "unknown-channel";
    }

    pub fn isDirectMessage(self: Channel) bool {
        return self.type == 1 or self.type == 3;
    }
};

pub const Message = struct {
    id: []const u8,
    channel_id: []const u8,
    author: User = .{ .id = "0" },
    content: []const u8,
    timestamp: []const u8,
    edited_timestamp: ?[]const u8 = null,
    tts: bool = false,
    mention_everyone: bool = false,
    attachments: ?[]Attachment = null,
    embeds: ?[]Embed = null,
    pinned: bool = false,
    flags: ?u32 = null,
    type: ?u8 = null,
};

pub const Attachment = struct {
    id: []const u8,
    filename: []const u8,
    size: u32 = 0,
    url: ?[]const u8 = null,
    proxy_url: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const Embed = struct {
    pub const Media = struct {
        url: ?[]const u8 = null,
        proxy_url: ?[]const u8 = null,
        width: ?u32 = null,
        height: ?u32 = null,
    };
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    type: ?[]const u8 = null,
    color: ?u32 = null,
    image: ?Media = null,
    thumbnail: ?Media = null,
    video: ?Media = null,
};
