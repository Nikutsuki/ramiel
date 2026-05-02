const std = @import("std");
const core = @import("core.zig");

fn syncCurrentUser(state: *core.AppState) !void {
    var payload = try state.discord.?.users.fetchMe(state.allocator);
    defer payload.deinit();
    try core.setOptionalOwned(state.allocator, &state.me_name, payload.value.displayName());
}

fn syncGuilds(state: *core.AppState) !void {
    var payload = try state.discord.?.guilds.fetchMeGuilds(state.allocator);
    defer payload.deinit();
    core.clearGuilds(state);

    for (payload.value) |guild| {
        var icon_url: ?[]u8 = null;
        if (guild.icon) |hash| {
            icon_url = try state.discord.?.cdn.buildGuildIconUrl(state.allocator, guild.id, hash);
            state.app.loadImageFromUrlAsync(icon_url.?, icon_url.?, 2 * 1024 * 1024) catch {};
        }

        const permissions = try core.dupOptionalSlice(state.allocator, guild.permissions);
        errdefer if (permissions) |permissions_slice| state.allocator.free(permissions_slice);

        try state.guilds.append(state.allocator, .{
            .id = try state.allocator.dupe(u8, guild.id),
            .name = try state.allocator.dupe(u8, guild.name),
            .icon_url = icon_url,
            .is_owner = guild.owner orelse false,
            .permissions = permissions,
        });
    }
}

fn appendChannel(allocator: std.mem.Allocator, target: *std.ArrayList(core.UIChannel), channel: core.DiscordModels.Channel, is_dm: bool) !void {
    try target.append(allocator, .{
        .id = try allocator.dupe(u8, channel.id),
        .name = try allocator.dupe(u8, channel.displayName()),
        .kind = channel.type,
        .guild_id = try core.dupOptionalSlice(allocator, channel.guild_id),
        .topic = try core.dupOptionalSlice(allocator, channel.topic),
        .is_dm = is_dm,
    });
}

pub fn replaceGuildChannelsFromSlice(state: *core.AppState, channels: []core.DiscordModels.Channel) !void {
    core.clearChannels(state);
    for (channels) |channel| {
        if (channel.name == null and !channel.isDirectMessage()) continue;
        try appendChannel(state.allocator, &state.channels, channel, false);
    }
}

pub fn syncDMs(state: *core.AppState) !void {
    var payload = try state.discord.?.users.fetchDMs(state.allocator);
    defer payload.deinit();
    core.clearDMs(state);
    for (payload.value) |channel| {
        try appendChannel(state.allocator, &state.dms, channel, true);
    }
}

pub fn syncGuildChannels(state: *core.AppState, guild_id: []const u8) !void {
    var payload = try state.discord.?.guilds.fetchGuildChannels(state.allocator, guild_id);
    defer payload.deinit();
    try replaceGuildChannelsFromSlice(state, payload.value);
}

fn parseDiscordMessage(state: *core.AppState, message: core.DiscordModels.Message) !core.UIMessage {
    const attachments_len: usize = if (message.attachments) |items| items.len else 0;
    const embeds_len: usize = if (message.embeds) |items| items.len else 0;
    const author_avatar = if (message.author.avatar) |hash|
        try state.discord.?.cdn.buildUserAvatarUrl(state.allocator, message.author.id, hash)
    else
        null;
    const attachments = try core.dupUIAttachments(state.allocator, message.attachments);
    errdefer state.allocator.free(attachments);
    const embeds = try core.dupUIEmbeds(state.allocator, message.embeds);
    errdefer state.allocator.free(embeds);
    if (author_avatar) |avatar_url| {
        state.app.loadImageFromUrlAsync(avatar_url, avatar_url, 2 * 1024 * 1024) catch {};
    }
    for (attachments) |attachment| {
        if (attachment.url) |url| {
            if (attachment.content_type) |content_type| {
                if (std.mem.eql(u8, content_type, "image/gif")) {
                    if (!state.video_playbacks.contains(attachment.id)) {
                        const zurl = try state.allocator.dupeZ(u8, url);
                        defer state.allocator.free(zurl);
                        if (state.app.video_manager.createPlayback(zurl)) |playback| {
                            playback.setVolume(0.0); // Mute for GIF-like behavior
                            playback.play(); // Auto-start for GIF-like behavior
                            try state.video_playbacks.put(try state.allocator.dupe(u8, attachment.id), core.VideoState{ .playback = playback, .volume = 0.0, .controls_hovered = false, .ui_progress_override = null });
                        } else |_| {}
                    }
                } else if (std.mem.startsWith(u8, content_type, "image/")) {
                    state.app.loadImageFromUrlAsync(url, url, 4 * 1024 * 1024) catch {};
                } else if (std.mem.startsWith(u8, content_type, "video/")) {
                    if (!state.video_playbacks.contains(attachment.id)) {
                        const zurl = try state.allocator.dupeZ(u8, url);
                        defer state.allocator.free(zurl);
                        if (state.app.video_manager.createPlayback(zurl)) |playback| {
                            playback.pause(); // Prevent auto-starting
                            try state.video_playbacks.put(try state.allocator.dupe(u8, attachment.id), core.VideoState{ .playback = playback, .volume = 1.0, .controls_hovered = false, .ui_progress_override = null });
                        } else |_| {}
                    }
                }
            }
        }
    }
    for (embeds) |embed| {
        if (embed.image) |image| {
            if (image.url) |url| state.app.loadImageFromUrlAsync(url, url, 4 * 1024 * 1024) catch {};
        }
        if (embed.thumbnail) |thumbnail| {
            if (thumbnail.url) |url| state.app.loadImageFromUrlAsync(url, url, 4 * 1024 * 1024) catch {};
        }
        if (embed.video) |video| {
            if (video.url) |url| {
                if (!state.video_playbacks.contains(url)) {
                    const zurl = try state.allocator.dupeZ(u8, url);
                    defer state.allocator.free(zurl);
                    if (state.app.video_manager.createPlayback(zurl)) |playback| {
                        const is_gifv = if (embed.kind) |kind| std.mem.eql(u8, kind, "gifv") else (std.mem.indexOf(u8, url, "tenor.com") != null or std.mem.indexOf(u8, url, "giphy.com") != null);
                        if (is_gifv) {
                            playback.setVolume(0.0); // Mute for GIF-like behavior
                            playback.play(); // Auto-start for GIF-like behavior
                            try state.video_playbacks.put(try state.allocator.dupe(u8, url), core.VideoState{ .playback = playback, .volume = 0.0, .controls_hovered = false, .ui_progress_override = null });
                        } else {
                            playback.pause(); // Prevent auto-starting for regular videos
                            try state.video_playbacks.put(try state.allocator.dupe(u8, url), core.VideoState{ .playback = playback, .volume = 1.0, .controls_hovered = false, .ui_progress_override = null });
                        }
                    } else |_| {}
                }
            }
        }
    }
    return .{
        .id = try state.allocator.dupe(u8, message.id),
        .channel_id = try state.allocator.dupe(u8, message.channel_id),
        .author_id = try state.allocator.dupe(u8, message.author.id),
        .author_name = try state.allocator.dupe(u8, message.author.displayName()),
        .author_avatar = author_avatar,
        .content = try state.allocator.dupe(u8, message.content),
        .timestamp = try state.allocator.dupe(u8, message.timestamp),
        .edited_timestamp = try core.dupOptionalSlice(state.allocator, message.edited_timestamp),
        .pinned = message.pinned,
        .attachment_count = @as(u16, @intCast(@min(attachments_len, std.math.maxInt(u16)))),
        .embed_count = @as(u16, @intCast(@min(embeds_len, std.math.maxInt(u16)))),
        .attachments = attachments,
        .embeds = embeds,
    };
}

pub fn replaceMessagesFromSlice(state: *core.AppState, messages: []core.DiscordModels.Message) !void {
    core.clearMessages(state);
    try state.messages.ensureUnusedCapacity(state.allocator, messages.len);
    for (messages) |message| {
        try state.messages.append(state.allocator, try parseDiscordMessage(state, message));
    }
    core.sortMessagesOldestFirst(state.messages.items);
}

pub fn prependMessagesFromSlice(state: *core.AppState, messages: []core.DiscordModels.Message) !void {
    if (messages.len == 0) return;

    var parsed_msgs = try std.ArrayList(core.UIMessage).initCapacity(state.allocator, messages.len);
    defer parsed_msgs.deinit(state.allocator);

    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        parsed_msgs.appendAssumeCapacity(try parseDiscordMessage(state, messages[i]));
    }

    try state.messages.insertSlice(state.allocator, 0, parsed_msgs.items);
}

pub fn mergeMessagesStabilized(state: *core.AppState, parsed_slice: []const core.DiscordModels.Message, overlap_idx: usize) !void {
    var i: usize = overlap_idx;
    while (i < state.messages.items.len) : (i += 1) {
        state.messages.items[i].deinit(state.allocator);
    }
    state.messages.shrinkRetainingCapacity(overlap_idx);

    var j: usize = parsed_slice.len;
    while (j > 0) {
        j -= 1;
        const parsed_msg = try parseDiscordMessage(state, parsed_slice[j]);
        try state.messages.append(state.allocator, parsed_msg);
    }
}

pub fn syncMessages(state: *core.AppState, channel_id: []const u8) !void {
    var payload = try state.discord.?.channels.fetchMessages(state.allocator, channel_id, .{ .limit = 100 });
    defer payload.deinit();
    try replaceMessagesFromSlice(state, payload.value);
}

fn bootstrapState(state: *core.AppState) void {
    syncCurrentUser(state) catch |err| core.reportError(state, "Failed to fetch current user", err);
    syncGuilds(state) catch |err| core.reportError(state, "Failed to fetch guilds", err);
    syncDMs(state) catch |err| core.reportError(state, "Failed to fetch DMs", err);

    if (state.guilds.items.len > 0) {
        const guild = state.guilds.items[0];
        core.setOptionalOwned(state.allocator, &state.selected_guild_id, guild.id) catch {};
        syncGuildChannels(state, guild.id) catch |err| {
            core.reportError(state, "Failed to fetch initial channels", err);
            return;
        };

        if (state.channels.items.len > 0) {
            const channel = state.channels.items[0];
            core.setOptionalOwned(state.allocator, &state.selected_channel_id, channel.id) catch {};
            syncMessages(state, channel.id) catch |err| {
                core.reportError(state, "Failed to fetch initial messages", err);
                return;
            };
        }
    } else if (state.dms.items.len > 0) {
        const channel = state.dms.items[0];
        core.setOptionalOwned(state.allocator, &state.selected_channel_id, channel.id) catch {};
        syncMessages(state, channel.id) catch |err| {
            core.reportError(state, "Failed to fetch initial DM messages", err);
            return;
        };
    }

    if (state.status_line == null) core.setStatus(state, "Discord data loaded.");
}

fn bootstrapTask(app: *core.App) void {
    bootstrapState(&app.state);
    app.state.is_bootstrapped.store(true, .release);
    app.state.app.postMessageId(.bootstrap_done);
}

pub fn startBootstrap(state: *core.AppState) void {
    state.bootstrap_future = state.app.io.async(bootstrapTask, .{state.app});
}
