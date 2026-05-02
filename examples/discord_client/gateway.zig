const std = @import("std");
const builtin = @import("builtin");
const ws = @import("wss").ws;

const core = @import("core.zig");

fn replacePendingMessage(state: *core.AppState, message: core.DiscordModels.Message, replacement: core.UIMessage) bool {
    var i: usize = state.messages.items.len;
    while (i > 0) {
        i -= 1;
        const existing = &state.messages.items[i];
        if (existing.delivery_status != .pending) continue;
        if (!std.mem.startsWith(u8, existing.id, "local-")) continue;
        if (!std.mem.eql(u8, existing.channel_id, message.channel_id)) continue;
        if (!std.mem.eql(u8, existing.content, message.content)) continue;

        existing.deinit(state.allocator);
        existing.* = replacement;
        return true;
    }
    return false;
}

fn websocketWorker(app: *core.App) void {
    const io = app.io;
    var client = ws.wss.Client.connect(app.allocator, .{
        .host = "gateway.discord.gg",
        .port = 443,
        .path = "/?v=10&encoding=json",
        .verify_peer = false,
        .max_frame_payload = 64 << 20,
        .max_message_payload = 64 << 20,
        .recv_buffer_mode = .adaptive,
        .recv_buffer_base_capacity = 64 * 1024,
    }) catch |err| {
        std.log.err("WebSocket connection failed: {s}", .{@errorName(err)});
        return;
    };
    defer client.close();

    var heartbeat_interval_ms: ?u64 = null;
    var next_heartbeat_at: ?std.Io.Clock.Timestamp = null;
    var seq: ?i64 = null;
    var identify_sent = false;

    while (!app.state.shutdown_flag.load(.acquire)) {
        if (next_heartbeat_at) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io, deadline.clock);
            if (std.Io.Clock.Timestamp.compare(now, .gte, deadline)) {
                const payload = if (seq) |s|
                    std.fmt.allocPrint(app.allocator, "{{\"op\":1,\"d\":{d}}}", .{s}) catch null
                else
                    app.allocator.dupe(u8, "{\"op\":1,\"d\":null}") catch null;

                if (payload) |p| {
                    defer app.allocator.free(p);
                    client.sendText(p) catch break;
                }

                const clamped: i64 = @intCast(@min(heartbeat_interval_ms.?, @as(u64, @intCast(std.math.maxInt(i64)))));
                const duration = std.Io.Clock.Duration{
                    .clock = .awake,
                    .raw = std.Io.Duration.fromMilliseconds(clamped),
                };
                next_heartbeat_at = std.Io.Clock.Timestamp.fromNow(io, duration);
            }
        }

        const msg = client.recvManaged() catch |err| switch (err) {
            error.ReadFailed => continue,
            else => break,
        };

        switch (msg.kind) {
            .text => {
                const payload = app.allocator.dupe(u8, msg.payload) catch continue;
                defer app.allocator.free(payload);

                var parsed = std.json.parseFromSlice(std.json.Value, app.allocator, payload, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const root = parsed.value.object;

                if (root.get("s")) |s_val| {
                    if (s_val == .integer) {
                        seq = s_val.integer;
                    }
                }
                const op_val = root.get("op") orelse continue;
                if (op_val != .integer) continue;

                switch (op_val.integer) {
                    0 => {
                        if (app.state.shutdown_flag.load(.acquire)) continue;
                        const dupe_payload = app.allocator.dupe(u8, payload) catch continue;
                        app.postMessageId(.{ .ws_receive = dupe_payload });
                    },
                    1 => {
                        const h_payload = if (seq) |s|
                            std.fmt.allocPrint(app.allocator, "{{\"op\":1,\"d\":{d}}}", .{s}) catch null
                        else
                            app.allocator.dupe(u8, "{\"op\":1,\"d\":null}") catch null;
                        if (h_payload) |p| {
                            defer app.allocator.free(p);
                            _ = client.sendText(p) catch {};
                        }
                    },
                    10 => {
                        const d_val = root.get("d") orelse continue;
                        if (d_val == .object) if (d_val.object.get("heartbeat_interval")) |hi| {
                            if (hi == .integer) {
                                heartbeat_interval_ms = @intCast(hi.integer);
                                const clamped: i64 = @intCast(@min(heartbeat_interval_ms.?, @as(u64, @intCast(std.math.maxInt(i64)))));
                                const duration = std.Io.Clock.Duration{
                                    .clock = .awake,
                                    .raw = std.Io.Duration.fromMilliseconds(clamped),
                                };
                                next_heartbeat_at = std.Io.Clock.Timestamp.fromNow(io, duration);
                            }
                        };

                        if (!identify_sent) {
                            const token = app.state.discord.?.rest.token;
                            const os_name = @tagName(builtin.os.tag);
                            const id_payload = std.fmt.allocPrint(
                                app.allocator,
                                "{{\"op\":2,\"d\":{{\"token\":\"{s}\",\"properties\":{{\"os\":\"{s}\",\"browser\":\"Ramiel\",\"device\":\"Ramiel\"}}}}}}",
                                .{ token, os_name },
                            ) catch null;
                            if (id_payload) |p| {
                                defer app.allocator.free(p);
                                client.sendText(p) catch {};
                                identify_sent = true;
                            }
                        }
                    },
                    else => {},
                }
            },
            .close => break,
            .binary, .ping, .pong => {},
        }
    }
}

pub fn processGatewayEvent(allocator: std.mem.Allocator, state: *core.AppState, raw_payload: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const op_val = root.object.get("op") orelse return;
    if (op_val != .integer or op_val.integer != 0) return;
    const t_val = root.object.get("t") orelse return;
    if (t_val != .string) return;
    if (!std.mem.eql(u8, t_val.string, "MESSAGE_CREATE")) return;

    const d_val = root.object.get("d") orelse return;
    var message_str = std.Io.Writer.Allocating.init(allocator);
    defer message_str.deinit();
    try std.json.Stringify.value(d_val, .{}, &message_str.writer);

    var msg_payload = try std.json.parseFromSlice(core.DiscordModels.Message, allocator, message_str.written(), .{ .ignore_unknown_fields = true });
    defer msg_payload.deinit();
    const message = msg_payload.value;

    const active_channel = state.selected_channel_id orelse return;
    if (!std.mem.eql(u8, message.channel_id, active_channel)) return;
    for (state.messages.items) |existing| {
        if (std.mem.eql(u8, existing.id, message.id)) return;
    }

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
                        const is_gifv = if (embed.kind) |kind| std.mem.eql(u8, kind, "gifv") else
                            (std.mem.indexOf(u8, url, "tenor.com") != null or std.mem.indexOf(u8, url, "giphy.com") != null);
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

    const new_msg = core.UIMessage{
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

    if (replacePendingMessage(state, message, new_msg)) return;

    try state.messages.append(state.allocator, new_msg);
    core.sortMessagesOldestFirst(state.messages.items);
}

pub fn startWebsocket(state: *core.AppState) !void {
    state.ws_thread = try std.Thread.spawn(.{}, websocketWorker, .{state.app});
}
