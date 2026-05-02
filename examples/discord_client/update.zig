const std = @import("std");
const glfw = @import("glfw");

const core = @import("core.zig");
const gateway = @import("gateway.zig");
const sync = @import("sync.zig");

const server_bar_close_delay_s: f64 = 0.12;

const MessagesFetchTaskCtx = struct {
    app: *core.App,
    channel_id: []u8,
    before_id: ?[]u8 = null,
    is_history: bool = false,
};

const GuildChannelsFetchTaskCtx = struct {
    app: *core.App,
    guild_id: []u8,
};

const SendTaskCtx = struct {
    app: *core.App,
    local_message_id: []u8,
    channel_id: []u8,
    content: []u8,
};

fn postMessagesFetchDone(app: *core.App, channel_id: []const u8, payload_json: ?[]const u8, err_name: ?[]const u8, is_history: bool) void {
    app.postMessageId(.{
        .messages_fetch_done = .{
            .channel_id = app.allocator.dupe(u8, channel_id) catch return,
            .payload_json = if (payload_json) |json| app.allocator.dupe(u8, json) catch null else null,
            .error_name = if (err_name) |err| app.allocator.dupe(u8, err) catch null else null,
            .is_history = is_history,
        },
    });
}

fn messagesFetchTask(ctx: MessagesFetchTaskCtx) void {
    defer {
        ctx.app.allocator.free(ctx.channel_id);
        if (ctx.before_id) |bid| ctx.app.allocator.free(bid);
    }

    var payload = ctx.app.state.discord.?.channels.fetchMessages(ctx.app.allocator, ctx.channel_id, .{
        .limit = 50,
        .before = ctx.before_id,
    }) catch |err| {
        postMessagesFetchDone(ctx.app, ctx.channel_id, null, @errorName(err), ctx.is_history);
        return;
    };
    defer payload.deinit();

    var writer = std.Io.Writer.Allocating.init(ctx.app.allocator);
    defer writer.deinit();
    std.json.Stringify.value(payload.value, .{}, &writer.writer) catch |err| {
        postMessagesFetchDone(ctx.app, ctx.channel_id, null, @errorName(err), ctx.is_history);
        return;
    };
    postMessagesFetchDone(ctx.app, ctx.channel_id, writer.written(), null, ctx.is_history);
}

fn startAsyncMessagesFetch(state: *core.AppState, channel_id: []const u8, before_id: ?[]const u8, is_history: bool) void {
    if (!is_history) {
        if (state.messages_fetch_future) |*future| {
            future.cancel(state.app.io);
            future.await(state.app.io);
            state.messages_fetch_future = null;
        }
    }
    const task_ctx = MessagesFetchTaskCtx{
        .app = state.app,
        .channel_id = state.allocator.dupe(u8, channel_id) catch return,
        .before_id = if (before_id) |bid| state.allocator.dupe(u8, bid) catch null else null,
        .is_history = is_history,
    };
    if (is_history) {
        state.history_fetch_future = state.app.io.concurrent(messagesFetchTask, .{task_ctx}) catch state.app.io.async(messagesFetchTask, .{task_ctx});
    } else {
        state.messages_fetch_future = state.app.io.concurrent(messagesFetchTask, .{task_ctx}) catch state.app.io.async(messagesFetchTask, .{task_ctx});
    }
}

fn postGuildChannelsFetchDone(app: *core.App, guild_id: []const u8, payload_json: ?[]const u8, err_name: ?[]const u8) void {
    app.postMessageId(.{
        .guild_channels_fetch_done = .{
            .guild_id = app.allocator.dupe(u8, guild_id) catch return,
            .payload_json = if (payload_json) |json| app.allocator.dupe(u8, json) catch null else null,
            .error_name = if (err_name) |err| app.allocator.dupe(u8, err) catch null else null,
        },
    });
}

fn guildChannelsFetchTask(ctx: GuildChannelsFetchTaskCtx) void {
    defer ctx.app.allocator.free(ctx.guild_id);
    var payload = ctx.app.state.discord.?.guilds.fetchGuildChannels(ctx.app.allocator, ctx.guild_id) catch |err| {
        postGuildChannelsFetchDone(ctx.app, ctx.guild_id, null, @errorName(err));
        return;
    };
    defer payload.deinit();

    var writer = std.Io.Writer.Allocating.init(ctx.app.allocator);
    defer writer.deinit();
    std.json.Stringify.value(payload.value, .{}, &writer.writer) catch |err| {
        postGuildChannelsFetchDone(ctx.app, ctx.guild_id, null, @errorName(err));
        return;
    };
    postGuildChannelsFetchDone(ctx.app, ctx.guild_id, writer.written(), null);
}

fn startAsyncGuildChannelsFetch(state: *core.AppState, guild_id: []const u8) void {
    if (state.channels_fetch_future) |*future| {
        future.cancel(state.app.io);
        future.await(state.app.io);
        state.channels_fetch_future = null;
    }
    const task_ctx = GuildChannelsFetchTaskCtx{
        .app = state.app,
        .guild_id = state.allocator.dupe(u8, guild_id) catch return,
    };
    state.channels_fetch_future = state.app.io.async(guildChannelsFetchTask, .{task_ctx});
}

fn postSendDone(app: *core.App, local_message_id: []const u8, channel_id: []const u8, err_name: ?[]const u8) void {
    app.postMessageId(.{
        .send_done = .{
            .local_message_id = app.allocator.dupe(u8, local_message_id) catch return,
            .channel_id = app.allocator.dupe(u8, channel_id) catch return,
            .error_name = if (err_name) |err| app.allocator.dupe(u8, err) catch null else null,
        },
    });
}

fn sendTask(ctx: SendTaskCtx) void {
    defer ctx.app.allocator.free(ctx.local_message_id);
    defer ctx.app.allocator.free(ctx.channel_id);
    defer ctx.app.allocator.free(ctx.content);
    var send_payload = ctx.app.state.discord.?.channels.sendMessage(ctx.app.allocator, ctx.channel_id, ctx.content) catch |err| {
        postSendDone(ctx.app, ctx.local_message_id, ctx.channel_id, @errorName(err));
        return;
    };
    defer send_payload.deinit();
    postSendDone(ctx.app, ctx.local_message_id, ctx.channel_id, null);
}

fn startAsyncSend(state: *core.AppState, local_message_id: []const u8, channel_id: []const u8, content: []const u8) void {
    if (state.send_message_future) |*future| {
        future.cancel(state.app.io);
        future.await(state.app.io);
        state.send_message_future = null;
    }
    const task_ctx = SendTaskCtx{
        .app = state.app,
        .local_message_id = state.allocator.dupe(u8, local_message_id) catch return,
        .channel_id = state.allocator.dupe(u8, channel_id) catch return,
        .content = state.allocator.dupe(u8, content) catch return,
    };
    state.send_message_future = state.app.io.async(sendTask, .{task_ctx});
}

fn targetState(state: *core.AppState, target: core.VirtualListTarget) *core.components.VirtualListState {
    return switch (target) {
        .guilds => &state.guilds_list,
        .browser => &state.browser_list,
        .messages => &state.messages_list,
    };
}

fn targetBaseId(state: *core.AppState, target: core.VirtualListTarget) core.NodeId {
    return switch (target) {
        .guilds => core.NodeIds.guild_virtual_list,
        .browser => core.components.deriveChildId(
            core.NodeIds.browser_virtual_list,
            if (state.selected_guild_id) |guild_id| guild_id else "dms",
        ),
        .messages => core.components.deriveChildId(
            core.NodeIds.message_virtual_list,
            if (state.selected_channel_id) |channel_id| channel_id else "none",
        ),
    };
}

fn cursorInsideGuildBarShell(ui: *core.AppUIContext, state: *core.AppState) bool {
    const shell = ui.getById(core.NodeIds.guild_bar_shell) orelse return false;
    const cursor = state.app.window.getCursorPos();
    const rect = shell.getTransformedRect();
    const x = @as(f32, @floatCast(cursor.x));
    const y = @as(f32, @floatCast(cursor.y));
    return x >= rect.x and x <= rect.x + rect.width and
        y >= rect.y and y <= rect.y + rect.height;
}

fn getInputNode(ui: *core.AppUIContext) ?*core.AppNode {
    return ui.getById(core.NodeIds.input);
}

fn getInputText(allocator: std.mem.Allocator, ui: *core.AppUIContext) ![]u8 {
    const raw = ui.getInputText(core.NodeIds.input) orelse return error.InputNotFound;
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    return allocator.dupe(u8, trimmed);
}

fn clearInputText(ui: *core.AppUIContext) void {
    const input_node = getInputNode(ui) orelse return;
    switch (input_node.payload) {
        .text_input => {
            input_node.payload.text_input.buffer.clearRetainingCapacity();
            input_node.payload.text_input.cursor_index = 0;
            input_node.payload.text_input.selection_anchor = null;
        },
        .text_area => {
            input_node.payload.text_area.buffer.clearRetainingCapacity();
            input_node.payload.text_area.cursor_index = 0;
            input_node.payload.text_area.selection_anchor = null;
            input_node.payload.text_area.scroll_y = 0.0;
            input_node.payload.text_area.target_nav_x = 0.0;
        },
        else => return,
    }
    input_node.markDirtyWithAncestors();
}

fn scrollMessagesToBottom(ui: *core.AppUIContext, state: *core.AppState) void {
    state.messages_list.setTotalItems(state.messages.items.len);
    const list_id = targetBaseId(state, .messages);
    _ = core.components.scrollVirtualListToEnd(core.AppMsg, ui, &state.messages_list, list_id);
}

fn setApiPayloadStatus(state: *core.AppState, prefix: []const u8, payload: []const u8) void {
    var snippet_buf: [192]u8 = undefined;
    const clipped_len = @min(payload.len, snippet_buf.len);
    @memcpy(snippet_buf[0..clipped_len], payload[0..clipped_len]);
    const snippet = snippet_buf[0..clipped_len];
    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}: {s}", .{ prefix, snippet }) catch prefix;
    core.setStatus(state, line);
}

fn sendComposerMessage(allocator: std.mem.Allocator, ui: *core.AppUIContext, state: *core.AppState) core.UpdateAction {
    const selected_channel_id = state.selected_channel_id orelse {
        core.setStatus(state, "Select a channel first.");
        return .none;
    };

    const text = getInputText(allocator, ui) catch |err| {
        core.reportError(state, "Input read failed", err);
        return .none;
    };
    defer allocator.free(text);

    if (text.len == 0) {
        core.setStatus(state, "Cannot send an empty message.");
        return .none;
    }

    const local_id = std.fmt.allocPrint(allocator, "local-{d}", .{state.pending_local_message_seq}) catch return .none;
    defer allocator.free(local_id);
    state.pending_local_message_seq +%= 1;
    const author_name = if (state.me_name) |name| name else "You";
    state.messages.append(allocator, .{
        .id = allocator.dupe(u8, local_id) catch return .none,
        .channel_id = allocator.dupe(u8, selected_channel_id) catch return .none,
        .author_id = allocator.dupe(u8, "local-user") catch return .none,
        .author_name = allocator.dupe(u8, author_name) catch return .none,
        .author_avatar = null,
        .content = allocator.dupe(u8, text) catch return .none,
        .timestamp = allocator.dupe(u8, "sending...") catch return .none,
        .edited_timestamp = null,
        .pinned = false,
        .attachment_count = 0,
        .embed_count = 0,
        .attachments = &.{},
        .embeds = &.{},
        .delivery_status = .pending,
    }) catch return .none;
    clearInputText(ui);
    scrollMessagesToBottom(ui, state);
    startAsyncSend(state, local_id, selected_channel_id, text);
    core.setStatus(state, "Sending message...");
    return .rebuild;
}

pub fn startBootstrap(state: *core.AppState) void {
    sync.startBootstrap(state);
}

pub fn startWebsocket(state: *core.AppState) !void {
    try gateway.startWebsocket(state);
}

pub fn tick(app: *core.App) core.UpdateAction {
    const ui = &app.ui;
    const state = &app.state;
    const cursor_inside_bar = cursorInsideGuildBarShell(ui, state);
    var needs_rebuild = false;

    var it = state.video_playbacks.iterator();
    while (it.next()) |entry| {
        const vid = entry.value_ptr.*.playback;
        if (vid.isSeeking()) continue;

        if (entry.value_ptr.*.volume == 0.0 and vid.state == .ended) {
            vid.seekTo(0.0);
            needs_rebuild = true;
            continue;
        }

        var latest_time: ?f64 = null;
        while (vid.time_telemetry.pop()) |t| {
            latest_time = t;
        }

        if (latest_time) |_| {
            if (entry.value_ptr.*.ui_progress_override == null) {
                if (entry.value_ptr.*.controls_hovered) needs_rebuild = true;
            } else if (!vid.isSeeking()) {
                entry.value_ptr.*.ui_progress_override = null;
                needs_rebuild = true;
            }
        }
    }

    if (cursor_inside_bar) {
        state.server_bar_close_deadline = null;
        if (!state.server_bar_hovered) {
            state.server_bar_hovered = true;
            needs_rebuild = true;
        }
    } else if (!state.guilds_list.is_scrolling and state.server_bar_hovered and state.server_bar_close_deadline == null) {
        state.server_bar_close_deadline = glfw.getTime() + server_bar_close_delay_s;
    }

    if (state.server_bar_close_deadline) |deadline| {
        if (glfw.getTime() >= deadline) {
            state.server_bar_close_deadline = null;
            state.server_bar_hovered = false;
            state.hovered_guild_index = null;
            needs_rebuild = true;
        }
    }

    if (needs_rebuild) return .rebuild;
    return .none;
}

pub fn update(app: *core.App, msg: core.AppInteractionMessage) core.UpdateAction {
    const allocator = app.allocator;
    const ui = &app.ui;
    const state = &app.state;
    switch (msg.id) {
        .open_dms => {
            if (state.dms.items.len == 0) {
                core.setOptionalOwned(state.allocator, &state.selected_guild_id, null) catch return .none;
                core.setOptionalOwned(state.allocator, &state.selected_channel_id, null) catch return .none;
                core.clearMessages(state);
                state.browser_list.resetMeasurements();
                state.messages_list.resetMeasurements();
                core.setStatus(state, "No direct messages available.");
                return .rebuild;
            }

            core.setOptionalOwned(state.allocator, &state.selected_guild_id, null) catch return .none;

            var dm_index: usize = 0;
            if (state.selected_channel_id) |selected| {
                for (state.dms.items, 0..) |dm, index| {
                    if (std.mem.eql(u8, selected, dm.id)) {
                        dm_index = index;
                        break;
                    }
                }
            }

            const channel = state.dms.items[dm_index];
            core.setOptionalOwned(state.allocator, &state.selected_channel_id, channel.id) catch return .none;
            core.clearMessages(state);
            startAsyncMessagesFetch(state, channel.id, null, false);
            scrollMessagesToBottom(ui, state);
            state.browser_list.resetMeasurements();
            state.messages_list.resetMeasurements();
            core.setStatus(state, "Browsing direct messages.");
            return .rebuild;
        },
        .guild_click => |index| {
            if (index >= state.guilds.items.len) return .none;
            const guild = state.guilds.items[index];
            core.setOptionalOwned(state.allocator, &state.selected_guild_id, guild.id) catch return .none;
            core.setOptionalOwned(state.allocator, &state.selected_channel_id, null) catch return .none;
            state.server_bar_close_deadline = null;

            core.clearChannels(state);
            core.clearMessages(state);
            startAsyncGuildChannelsFetch(state, guild.id);
            state.browser_list.resetMeasurements();
            state.messages_list.resetMeasurements();
            return .rebuild;
        },
        .channel_click => |index| {
            if (index >= state.channels.items.len) return .none;
            const channel = state.channels.items[index];
            core.setOptionalOwned(state.allocator, &state.selected_channel_id, channel.id) catch return .none;
            core.clearMessages(state);
            startAsyncMessagesFetch(state, channel.id, null, false);
            scrollMessagesToBottom(ui, state);
            state.messages_list.resetMeasurements();
            return .rebuild;
        },
        .dm_click => |index| {
            if (index >= state.dms.items.len) return .none;
            const channel = state.dms.items[index];
            core.setOptionalOwned(state.allocator, &state.selected_guild_id, null) catch return .none;
            core.setOptionalOwned(state.allocator, &state.selected_channel_id, channel.id) catch return .none;
            core.clearMessages(state);
            startAsyncMessagesFetch(state, channel.id, null, false);
            scrollMessagesToBottom(ui, state);
            state.messages_list.resetMeasurements();
            return .rebuild;
        },
        .virtual_list_drag_state => |payload| {
            const list_state = targetState(state, payload.target);
            list_state.is_scrolling = payload.is_dragging;

            if (payload.target == .guilds and payload.is_dragging) {
                state.server_bar_close_deadline = null;
            }
            return .rebuild;
        },
        .virtual_list_need_data => |payload| {
            _ = payload.target;
            _ = payload.start;
            _ = payload.end;
            return .rebuild;
        },
        .virtual_list_scroll => |payload| {
            const list_state = targetState(state, payload.target);
            const base_id = targetBaseId(state, payload.target);
            _ = core.components.applyVirtualListScrollDelta(core.AppMsg, ui, list_state, base_id, payload.delta);

            if (payload.target == .messages and payload.delta < 0.0) {
                if (list_state.scroll_offset < 1500.0 and !state.is_fetching_history and state.messages.items.len > 0) {
                    state.is_fetching_history = true;
                    if (state.selected_channel_id) |channel_id| {
                        const before_id = state.messages.items[0].id;
                        startAsyncMessagesFetch(state, channel_id, before_id, true);
                        core.setStatus(state, "Fetching message history...");
                    }
                }
            }
            return .rebuild;
        },
        .send => return sendComposerMessage(allocator, ui, state),
        .input_key => {
            if (msg.data == .key) {
                const key = msg.data.key;
                if ((key.key == glfw.KeyEnter or key.key == glfw.KeyKpEnter) and key.action == glfw.Press) {
                    return sendComposerMessage(allocator, ui, state);
                }
            }
            return .none;
        },
        .ws_receive => |payload| {
            gateway.processGatewayEvent(allocator, state, payload) catch |err| core.reportError(state, "Gateway event processing failed", err);
            allocator.free(payload);
            return .rebuild;
        },
        .messages_fetch_done => |payload| {
            if (payload.is_history) {
                state.is_fetching_history = false;
                if (state.history_fetch_future) |*future| {
                    future.await(state.app.io);
                    state.history_fetch_future = null;
                }
            } else {
                if (state.messages_fetch_future) |*future| {
                    future.await(state.app.io);
                    state.messages_fetch_future = null;
                }
            }
            defer allocator.free(payload.channel_id);
            defer if (payload.payload_json) |json| allocator.free(json);
            defer if (payload.error_name) |err_name| allocator.free(err_name);
            if (!core.isChannelSelected(state, payload.channel_id)) return .none;
            if (payload.error_name) |err_name| {
                core.setStatus(state, err_name);
                return .rebuild;
            }
            const json = payload.payload_json orelse return .none;
            if (json.len == 0) {
                if (!payload.is_history) core.setStatus(state, "Message fetch returned empty payload.");
                return .rebuild;
            }
            if (json[0] != '[') {
                setApiPayloadStatus(state, "Message fetch returned unexpected payload", json);
                return .rebuild;
            }
            var parsed = std.json.parseFromSlice([]core.DiscordModels.Message, allocator, json, .{ .ignore_unknown_fields = true }) catch |err| {
                core.reportError(state, "Message parse failed", err);
                return .none;
            };
            defer parsed.deinit();

            if (payload.is_history) {
                const new_count = parsed.value.len;
                if (new_count > 0) {
                    sync.prependMessagesFromSlice(state, parsed.value) catch |err| {
                        core.reportError(state, "History apply failed", err);
                        return .none;
                    };
                    const base_id = targetBaseId(state, .messages);
                    state.messages_list.prependItems(core.AppMsg, ui, base_id, new_count);
                    core.setStatus(state, "History loaded.");
                } else {
                    core.setStatus(state, "No more history.");
                }
            } else {
                var overlap_idx: usize = 0;
                var has_overlap = false;

                if (state.messages.items.len > 0 and parsed.value.len > 0) {
                    const new_oldest_id = parsed.value[parsed.value.len - 1].id;
                    for (state.messages.items, 0..) |old_msg, idx| {
                        if (std.mem.eql(u8, old_msg.id, new_oldest_id)) {
                            overlap_idx = idx;
                            has_overlap = true;
                            break;
                        }
                    }
                }

                if (has_overlap) {
                    sync.mergeMessagesStabilized(state, parsed.value, overlap_idx) catch |err| {
                        core.reportError(state, "Message merge failed", err);
                        return .none;
                    };
                } else {
                    sync.replaceMessagesFromSlice(state, parsed.value) catch |err| {
                        core.reportError(state, "Message apply failed", err);
                        return .none;
                    };
                    state.messages_list.resetMeasurements();
                    scrollMessagesToBottom(ui, state);
                }
            }
            return .rebuild;
        },
        .guild_channels_fetch_done => |payload| {
            if (state.channels_fetch_future) |*future| {
                future.await(state.app.io);
                state.channels_fetch_future = null;
            }
            defer allocator.free(payload.guild_id);
            defer if (payload.payload_json) |json| allocator.free(json);
            defer if (payload.error_name) |err_name| allocator.free(err_name);
            if (!core.isGuildSelected(state, payload.guild_id)) return .none;
            if (payload.error_name) |err_name| {
                core.setStatus(state, err_name);
                return .rebuild;
            }
            const json = payload.payload_json orelse return .none;
            if (json.len == 0) {
                core.setStatus(state, "Channel fetch returned empty payload.");
                return .rebuild;
            }
            if (json[0] != '[') {
                setApiPayloadStatus(state, "Channel fetch returned unexpected payload", json);
                return .rebuild;
            }
            var parsed = std.json.parseFromSlice([]core.DiscordModels.Channel, allocator, json, .{ .ignore_unknown_fields = true }) catch |err| {
                core.reportError(state, "Channel parse failed", err);
                return .none;
            };
            defer parsed.deinit();
            sync.replaceGuildChannelsFromSlice(state, parsed.value) catch |err| {
                core.reportError(state, "Channel apply failed", err);
                return .none;
            };
            if (state.channels.items.len == 0) {
                core.setStatus(state, "Selected guild has no channels.");
                return .rebuild;
            }
            const first = state.channels.items[0];
            core.setOptionalOwned(state.allocator, &state.selected_channel_id, first.id) catch return .rebuild;
            startAsyncMessagesFetch(state, first.id, null, false);
            return .rebuild;
        },
        .send_done => |payload| {
            if (state.send_message_future) |*future| {
                future.await(state.app.io);
                state.send_message_future = null;
            }
            defer allocator.free(payload.local_message_id);
            defer allocator.free(payload.channel_id);
            defer if (payload.error_name) |err_name| allocator.free(err_name);
            for (state.messages.items) |*message| {
                if (std.mem.eql(u8, message.id, payload.local_message_id)) {
                    message.delivery_status = if (payload.error_name == null) .sent else .failed;
                    break;
                }
            }
            if (payload.error_name) |err_name| {
                core.setStatus(state, err_name);
            } else if (core.isChannelSelected(state, payload.channel_id)) {
                startAsyncMessagesFetch(state, payload.channel_id, null, false);
                core.setStatus(state, "Message sent.");
            }
            return .rebuild;
        },
        .guild_hover_enter => |index| {
            state.hovered_guild_index = index;
            state.last_hovered_index = index;
            return .rebuild;
        },
        .guild_hover_exit => |index| {
            if (state.hovered_guild_index == index) {
                state.hovered_guild_index = null;
                return .rebuild;
            }
            return .none;
        },
        .server_bar_hover_enter => {
            state.server_bar_close_deadline = null;
            if (!state.server_bar_hovered) {
                state.server_bar_hovered = true;
                return .rebuild;
            }
            return .none;
        },
        .server_bar_hover_exit => {
            if (!cursorInsideGuildBarShell(ui, state) and !state.guilds_list.is_scrolling and state.server_bar_hovered) {
                state.server_bar_close_deadline = glfw.getTime() + server_bar_close_delay_s;
            }
            return .none;
        },
        .bootstrap_done => {
            core.setStatus(state, "Bootstrap complete.");
            scrollMessagesToBottom(ui, state);
            return .rebuild;
        },
        .video_toggle => |id_str| {
            if (state.video_playbacks.get(id_str)) |video_state| {
                if (video_state.playback.state == .playing) {
                    video_state.playback.pause();
                } else if (video_state.playback.state == .paused) {
                    video_state.playback.play();
                }
                return .rebuild;
            }
            return .none;
        },
        .video_seek => |seek| {
            if (state.video_playbacks.getPtr(seek.id)) |video_state| {
                const duration = video_state.playback.getDurationS();
                if (duration > 0.0) {
                    video_state.ui_progress_override = std.math.clamp(seek.value, 0.0, 1.0);
                    const target_s = @as(f64, seek.value) * duration;
                    video_state.playback.seekTo(target_s);
                    return .rebuild;
                }
            }
            return .none;
        },
        .video_volume => |vol| {
            if (state.video_playbacks.getPtr(vol.id)) |video_state| {
                const clamped = std.math.clamp(vol.value, 0.0, 1.0);
                video_state.volume = clamped;
                video_state.playback.setVolume(clamped);
                return .rebuild;
            }
            return .none;
        },
        .video_hover => |hover| {
            if (state.video_playbacks.getPtr(hover.id)) |video_state| {
                if (video_state.controls_hovered != hover.hovered) {
                    video_state.controls_hovered = hover.hovered;
                    return .rebuild;
                }
            }
            return .none;
        },
        .open_preview => |payload| {
            if (state.preview_media) |*pm| state.allocator.free(pm.url_or_id);
            state.preview_media = .{
                .url_or_id = allocator.dupe(u8, payload.url_or_id) catch return .none,
                .is_video = payload.is_video,
                .is_gif = payload.is_gif,
                .width = payload.width,
                .height = payload.height,
            };
            return .rebuild;
        },
        .randomize_theme => {
            var prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(state.app.io, std.Io.Clock.awake).toMilliseconds()));
            const rand = prng.random();
            const random_theme = core.lib.Theme.initRandom(rand, true);
            state.app.ui.setTheme(random_theme);
            core.setStatus(state, "Theme randomized.");
            return .rebuild;
        },
        .close_preview => {
            if (state.preview_media) |*pm| {
                allocator.free(pm.url_or_id);
                state.preview_media = null;
                return .rebuild;
            }
            return .none;
        },
    }
}
