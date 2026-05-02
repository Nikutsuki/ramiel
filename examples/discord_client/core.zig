const std = @import("std");
pub const lib = @import("ramiel");

const discord_mod = @import("discord/mod.zig");
pub const Discord = discord_mod.Discord;
pub const DiscordModels = discord_mod.models;

pub const UIContext = lib.UIContext;
pub const Node = lib.Node;
pub const InteractionMessage = lib.InteractionMessage;
pub const FontData = lib.FontData;
pub const Application = lib.Application;
pub const NodeId = lib.NodeId;
pub const UpdateAction = lib.UpdateAction;
pub const Color = lib.Color;
pub const components = lib.components;
pub const Style = lib.Style;
pub const tw = lib.tw;

pub const AppMsg = union(enum) {
    input_key: void,
    send: void,
    open_dms: void,
    channel_click: usize,
    guild_click: usize,
    dm_click: usize,
    ws_receive: []const u8,
    guild_hover_enter: usize,
    guild_hover_exit: usize,
    server_bar_hover_enter: void,
    server_bar_hover_exit: void,
    virtual_list_need_data: struct { target: VirtualListTarget, start: usize, end: usize },
    virtual_list_scroll: struct { target: VirtualListTarget, delta: f32 },
    messages_fetch_done: struct {
        channel_id: []const u8,
        payload_json: ?[]const u8 = null,
        error_name: ?[]const u8 = null,
        is_history: bool = false,
    },
    guild_channels_fetch_done: struct {
        guild_id: []const u8,
        payload_json: ?[]const u8 = null,
        error_name: ?[]const u8 = null,
    },
    send_done: struct {
        local_message_id: []const u8,
        channel_id: []const u8,
        error_name: ?[]const u8 = null,
    },
    bootstrap_done: void,
    video_toggle: []const u8,
    video_seek: struct { id: []const u8, value: f32 },
    video_volume: struct { id: []const u8, value: f32 },
    video_hover: struct { id: []const u8, hovered: bool },

    open_preview: struct {
        url_or_id: []const u8,
        is_video: bool,
        is_gif: bool,
        width: u32,
        height: u32,
    },
    close_preview: void,
    randomize_theme: void,
    virtual_list_drag_state: struct {
        target: VirtualListTarget,
        is_dragging: bool,
    },

    pub fn deinit(self: AppMsg, allocator: std.mem.Allocator) void {
        switch (self) {
            .ws_receive => |payload| allocator.free(payload),
            .messages_fetch_done => |payload| {
                allocator.free(payload.channel_id);
                if (payload.payload_json) |json| allocator.free(json);
                if (payload.error_name) |err_name| allocator.free(err_name);
            },
            .guild_channels_fetch_done => |payload| {
                allocator.free(payload.guild_id);
                if (payload.payload_json) |json| allocator.free(json);
                if (payload.error_name) |err_name| allocator.free(err_name);
            },
            .send_done => |payload| {
                allocator.free(payload.local_message_id);
                allocator.free(payload.channel_id);
                if (payload.error_name) |err_name| allocator.free(err_name);
            },
            else => {},
        }
    }
};

const T = lib.For(AppMsg);
pub const AppUIContext = T.UIContext;
pub const AppNode = T.Node;
pub const AppInteractionMessage = T.InteractionMessage;
pub const App = lib.Application(AppState, AppMsg);

pub const NodeIds = lib.declareIds(.{
    "input",
    "send_button",
    "tooltip",
    "guild_container",
    "guild_bar_shell",
    "guild_virtual_list",
    "browser_virtual_list",
    "message_virtual_list",
}){};

pub const VirtualListTarget = enum {
    guilds,
    browser,
    messages,
};

pub const IconIds = enum(u32) {
    add = 1,
};

pub const PreviewMedia = struct {
    url_or_id: []u8,
    is_video: bool,
    is_gif: bool,
    width: u32,
    height: u32,
};

pub const VideoState = struct {
    playback: *lib.VideoPlayback,
    volume: f32 = 1.0,
    controls_hovered: bool = false,
    ui_progress_override: ?f32 = null,
};

pub const UIGuild = struct {
    id: []u8,
    name: []u8,
    icon_url: ?[]u8 = null,
    is_owner: bool = false,
    permissions: ?[]u8 = null,

    pub fn deinit(self: *UIGuild, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.icon_url) |icon| allocator.free(icon);
        if (self.permissions) |permissions| allocator.free(permissions);
    }
};

pub const UIChannel = struct {
    id: []u8,
    name: []u8,
    kind: u8,
    guild_id: ?[]u8 = null,
    topic: ?[]u8 = null,
    is_dm: bool,

    pub fn deinit(self: *UIChannel, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.guild_id) |guild_id| allocator.free(guild_id);
        if (self.topic) |topic| allocator.free(topic);
    }
};

pub const UIMessage = struct {
    pub const DeliveryStatus = enum {
        sent,
        pending,
        failed,
    };

    id: []u8,
    channel_id: []u8,
    author_id: []u8,
    author_name: []u8,
    author_avatar: ?[]u8 = null,
    content: []u8,
    timestamp: []u8,
    edited_timestamp: ?[]u8 = null,
    pinned: bool,
    attachment_count: u16,
    embed_count: u16,
    attachments: []UIAttachment = &.{},
    embeds: []UIEmbed = &.{},
    delivery_status: DeliveryStatus = .sent,

    pub fn deinit(self: *UIMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.channel_id);
        allocator.free(self.author_id);
        allocator.free(self.author_name);
        if (self.author_avatar) |author_avatar| allocator.free(author_avatar);
        allocator.free(self.content);
        allocator.free(self.timestamp);
        if (self.edited_timestamp) |edited_timestamp| allocator.free(edited_timestamp);
        for (self.attachments) |*attachment| attachment.deinit(allocator);
        allocator.free(self.attachments);
        for (self.embeds) |*embed| embed.deinit(allocator);
        allocator.free(self.embeds);
    }
};

pub const UIAttachment = struct {
    id: []u8,
    filename: []u8,
    size: u32 = 0,
    url: ?[]u8 = null,
    proxy_url: ?[]u8 = null,
    content_type: ?[]u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,

    pub fn deinit(self: *UIAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.filename);
        if (self.url) |url| allocator.free(url);
        if (self.proxy_url) |proxy_url| allocator.free(proxy_url);
        if (self.content_type) |content_type| allocator.free(content_type);
    }
};

pub const UIEmbedMedia = struct {
    url: ?[]u8 = null,
    proxy_url: ?[]u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,

    pub fn deinit(self: *UIEmbedMedia, allocator: std.mem.Allocator) void {
        if (self.url) |url| allocator.free(url);
        if (self.proxy_url) |proxy_url| allocator.free(proxy_url);
    }
};

pub const UIEmbed = struct {
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    url: ?[]u8 = null,
    kind: ?[]u8 = null,
    color: ?u32 = null,
    image: ?UIEmbedMedia = null,
    thumbnail: ?UIEmbedMedia = null,
    video: ?UIEmbedMedia = null,

    pub fn deinit(self: *UIEmbed, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.description) |description| allocator.free(description);
        if (self.url) |url| allocator.free(url);
        if (self.kind) |kind| allocator.free(kind);
        if (self.image) |*image| image.deinit(allocator);
        if (self.thumbnail) |*thumbnail| thumbnail.deinit(allocator);
        if (self.video) |*video| video.deinit(allocator);
    }
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    font_data: *FontData = undefined,
    wallpaper_id: u32 = 0,
    discord: ?*Discord = null,

    guilds: std.ArrayList(UIGuild) = .empty,
    channels: std.ArrayList(UIChannel) = .empty,
    dms: std.ArrayList(UIChannel) = .empty,
    messages: std.ArrayList(UIMessage) = .empty,

    selected_guild_id: ?[]u8 = null,
    selected_channel_id: ?[]u8 = null,

    me_name: ?[]u8 = null,
    status_line: ?[]u8 = null,

    app: *App = undefined,
    ws_thread: ?std.Thread = null,
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    hovered_guild_index: ?usize = null,
    last_hovered_index: usize = 0,
    server_bar_hovered: bool = false,
    server_bar_close_deadline: ?f64 = null,

    is_bootstrapped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bootstrap_future: ?std.Io.Future(void) = null,
    messages_fetch_future: ?std.Io.Future(void) = null,
    channels_fetch_future: ?std.Io.Future(void) = null,
    send_message_future: ?std.Io.Future(void) = null,
    history_fetch_future: ?std.Io.Future(void) = null,
    pending_local_message_seq: u64 = 0,
    is_fetching_history: bool = false,

    guilds_list: components.VirtualListState = undefined,
    browser_list: components.VirtualListState = undefined,
    messages_list: components.VirtualListState = undefined,
    video_playbacks: std.StringHashMap(VideoState) = undefined,

    preview_media: ?PreviewMedia = null,
};

pub fn initAppState(allocator: std.mem.Allocator, discord: ?*Discord) AppState {
    return .{
        .allocator = allocator,
        .discord = discord,
        .guilds_list = components.VirtualListState.init(allocator, .horizontal, 0),
        .browser_list = components.VirtualListState.init(allocator, .vertical, 0),
        .messages_list = components.VirtualListState.init(allocator, .vertical, 0),
        .video_playbacks = std.StringHashMap(VideoState).init(allocator),
    };
}

pub fn freeOptionalOwned(allocator: std.mem.Allocator, value: *?[]u8) void {
    if (value.*) |slice| allocator.free(slice);
    value.* = null;
}

pub fn setOptionalOwned(allocator: std.mem.Allocator, target: *?[]u8, value: ?[]const u8) !void {
    freeOptionalOwned(allocator, target);
    if (value) |slice| {
        target.* = try allocator.dupe(u8, slice);
    }
}

pub fn dupOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |slice| return try allocator.dupe(u8, slice);
    return null;
}

pub fn setStatus(state: *AppState, line: []const u8) void {
    setOptionalOwned(state.allocator, &state.status_line, line) catch {};
}

pub fn reportError(state: *AppState, prefix: []const u8, err: anyerror) void {
    var status_buf: [256]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_buf, "{s}: {s}", .{ prefix, @errorName(err) }) catch prefix;
    setStatus(state, status_line);
}

pub fn isGuildSelected(state: *const AppState, guild_id: []const u8) bool {
    if (state.selected_guild_id) |selected| {
        return std.mem.eql(u8, selected, guild_id);
    }
    return false;
}

pub fn isChannelSelected(state: *const AppState, channel_id: []const u8) bool {
    if (state.selected_channel_id) |selected| {
        return std.mem.eql(u8, selected, channel_id);
    }
    return false;
}

pub fn activeChannelName(state: *const AppState) []const u8 {
    const selected = state.selected_channel_id orelse return "none";

    for (state.channels.items) |channel| {
        if (std.mem.eql(u8, selected, channel.id)) return channel.name;
    }

    for (state.dms.items) |channel| {
        if (std.mem.eql(u8, selected, channel.id)) return channel.name;
    }

    return "none";
}

pub fn clearGuilds(state: *AppState) void {
    for (state.guilds.items) |*guild| guild.deinit(state.allocator);
    state.guilds.clearRetainingCapacity();
}

pub fn clearChannels(state: *AppState) void {
    for (state.channels.items) |*channel| channel.deinit(state.allocator);
    state.channels.clearRetainingCapacity();
}

pub fn clearDMs(state: *AppState) void {
    for (state.dms.items) |*channel| channel.deinit(state.allocator);
    state.dms.clearRetainingCapacity();
}

pub fn clearMessages(state: *AppState) void {
    for (state.messages.items) |*message| message.deinit(state.allocator);
    state.messages.clearRetainingCapacity();

    var it = state.video_playbacks.iterator();
    while (it.next()) |entry| {
        state.app.video_manager.destroyPlayback(entry.value_ptr.*.playback.id);
        state.allocator.free(entry.key_ptr.*);
    }
    state.video_playbacks.clearRetainingCapacity();
}

pub fn deinitAppState(state: *AppState) void {
    clearGuilds(state);
    clearChannels(state);
    clearDMs(state);
    clearMessages(state);

    state.guilds.deinit(state.allocator);
    state.channels.deinit(state.allocator);
    state.dms.deinit(state.allocator);
    state.messages.deinit(state.allocator);

    freeOptionalOwned(state.allocator, &state.selected_guild_id);
    freeOptionalOwned(state.allocator, &state.selected_channel_id);
    freeOptionalOwned(state.allocator, &state.me_name);
    freeOptionalOwned(state.allocator, &state.status_line);
    state.guilds_list.deinit();
    state.browser_list.deinit();
    state.messages_list.deinit();
    state.video_playbacks.deinit();

    if (state.preview_media) |*pm| {
        state.allocator.free(pm.url_or_id);
    }
}

pub fn parseSnowflakeId(id: []const u8) u64 {
    return std.fmt.parseUnsigned(u64, id, 10) catch std.math.maxInt(u64);
}

pub fn sortMessagesOldestFirst(messages: []UIMessage) void {
    if (messages.len < 2) return;

    var i: usize = 1;
    while (i < messages.len) : (i += 1) {
        var j = i;
        while (j > 0 and parseSnowflakeId(messages[j].id) < parseSnowflakeId(messages[j - 1].id)) : (j -= 1) {
            const tmp = messages[j - 1];
            messages[j - 1] = messages[j];
            messages[j] = tmp;
        }
    }
}

pub fn dupUIAttachments(allocator: std.mem.Allocator, attachments: ?[]DiscordModels.Attachment) ![]UIAttachment {
    const src = attachments orelse return &.{};
    if (src.len == 0) return &.{};
    const out = try allocator.alloc(UIAttachment, src.len);
    errdefer {
        for (out[0..], 0..) |*item, idx| {
            if (idx >= src.len) break;
            item.deinit(allocator);
        }
        allocator.free(out);
    }
    for (src, 0..) |attachment, idx| {
        out[idx] = .{
            .id = try allocator.dupe(u8, attachment.id),
            .filename = try allocator.dupe(u8, attachment.filename),
            .size = attachment.size,
            .url = try dupOptionalSlice(allocator, attachment.url),
            .proxy_url = try dupOptionalSlice(allocator, attachment.proxy_url),
            .content_type = try dupOptionalSlice(allocator, attachment.content_type),
            .width = attachment.width,
            .height = attachment.height,
        };
    }
    return out;
}

fn dupEmbedMedia(allocator: std.mem.Allocator, media: ?DiscordModels.Embed.Media) !?UIEmbedMedia {
    if (media) |value| {
        return .{
            .url = try dupOptionalSlice(allocator, value.url),
            .proxy_url = try dupOptionalSlice(allocator, value.proxy_url),
            .width = value.width,
            .height = value.height,
        };
    }
    return null;
}

pub fn dupUIEmbeds(allocator: std.mem.Allocator, embeds: ?[]DiscordModels.Embed) ![]UIEmbed {
    const src = embeds orelse return &.{};
    if (src.len == 0) return &.{};
    const out = try allocator.alloc(UIEmbed, src.len);
    errdefer {
        for (out[0..], 0..) |*item, idx| {
            if (idx >= src.len) break;
            item.deinit(allocator);
        }
        allocator.free(out);
    }
    for (src, 0..) |embed, idx| {
        out[idx] = .{
            .title = try dupOptionalSlice(allocator, embed.title),
            .description = try dupOptionalSlice(allocator, embed.description),
            .url = try dupOptionalSlice(allocator, embed.url),
            .kind = try dupOptionalSlice(allocator, embed.type),
            .color = embed.color,
            .image = try dupEmbedMedia(allocator, embed.image),
            .thumbnail = try dupEmbedMedia(allocator, embed.thumbnail),
            .video = try dupEmbedMedia(allocator, embed.video),
        };
    }
    return out;
}

pub fn formatTimestampCompact(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len >= 16 and raw[4] == '-' and raw[7] == '-' and (raw[10] == 'T' or raw[10] == ' ')) {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ raw[0..10], raw[11..16] });
    }
    return allocator.dupe(u8, raw);
}
