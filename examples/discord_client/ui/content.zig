const std = @import("std");
const core = @import("../core.zig");

const BrowseBuildCtx = struct {
    allocator: std.mem.Allocator,
    state: *const core.AppState,
    browsing_dms: bool,
    font: *core.FontData,
};

const MessageBuildCtx = struct {
    allocator: std.mem.Allocator,
    state: *const core.AppState,
    font: *core.FontData,
};

fn maybeSlice(value: ?[]const u8) []const u8 {
    return value orelse "";
}

fn isImageAttachment(attachment: core.UIAttachment) bool {
    if (std.mem.endsWith(u8, attachment.filename, ".png") or
        std.mem.endsWith(u8, attachment.filename, ".jpg") or
        std.mem.endsWith(u8, attachment.filename, ".jpeg") or
        std.mem.endsWith(u8, attachment.filename, ".gif") or
        std.mem.endsWith(u8, attachment.filename, ".webp")) return true;
    if (attachment.content_type) |content_type| {
        if (std.mem.startsWith(u8, content_type, "image/")) return true;
    }
    return false;
}

fn isGifAttachment(attachment: core.UIAttachment) bool {
    if (std.mem.endsWith(u8, attachment.filename, ".gif")) return true;
    if (attachment.content_type) |content_type| {
        if (std.mem.eql(u8, content_type, "image/gif")) return true;
    }
    return false;
}

fn isVideoAttachment(attachment: core.UIAttachment) bool {
    if (std.mem.endsWith(u8, attachment.filename, ".mp4") or
        std.mem.endsWith(u8, attachment.filename, ".mov") or
        std.mem.endsWith(u8, attachment.filename, ".webm") or
        std.mem.endsWith(u8, attachment.filename, ".mkv")) return true;
    if (attachment.content_type) |content_type| {
        if (std.mem.startsWith(u8, content_type, "video/") and !std.mem.eql(u8, content_type, "image/gif")) return true;
    }
    return false;
}

fn formatByteSize(allocator: std.mem.Allocator, bytes: u32) ![]u8 {
    const value = @as(f64, @floatFromInt(bytes));
    if (value >= 1024.0 * 1024.0) {
        return std.fmt.allocPrint(allocator, "{d:.1} MB", .{value / (1024.0 * 1024.0)});
    }
    if (value >= 1024.0) {
        return std.fmt.allocPrint(allocator, "{d:.1} KB", .{value / 1024.0});
    }
    return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
}

fn buildAttachmentCard(ctx: *core.AppUIContext, payload: *const MessageBuildCtx, attachment: core.UIAttachment) !*core.AppNode {
    const build_alloc = ctx.build_arena.allocator();
    const tokens = ctx.active_theme.tokens;
    var children = std.ArrayList(?*core.AppNode).empty;
    defer children.deinit(build_alloc);
    const size_text = try formatByteSize(payload.allocator, attachment.size);
    defer payload.allocator.free(size_text);
    const label = try std.fmt.allocPrint(payload.allocator, "{s} ({s})", .{ attachment.filename, size_text });
    defer payload.allocator.free(label);
    try children.append(build_alloc, try ctx.ux().text(.{
        .content = label,
        .font = payload.font,
        .style = .{ .text_color = tokens.text_main },
    }));
    if (attachment.content_type) |content_type| {
        try children.append(build_alloc, try ctx.ux().text(.{
            .content = content_type,
            .font = payload.font,
            .style = .{ .text_color = tokens.text_muted },
        }));
    }
    if (attachment.url) |url| {
        try children.append(build_alloc, try ctx.ux().text(.{
            .content = url,
            .font = payload.font,
            .max_width = 560,
            .style = .{ .text_color = tokens.action_default },
        }));
    }

    var card_bg = tokens.bg_surface;
    card_bg[3] = 0.85;

    return ctx.ux().div(.{
        .style = .{
            .width = .Full,
            .direction = .Column,
            .gap = 3,
            .padding = core.lib.layout.Spacing.all(8),
            .background_color = card_bg,
            .corner_radius = core.lib.layout.CornerRadius.all(8),
        },
        .children = try children.toOwnedSlice(build_alloc),
    });
}

fn hexToRgba(hex: u32) [4]f32 {
    const r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0;
    return .{ r, g, b, 1.0 };
}

fn buildEmbedCard(ctx: *core.AppUIContext, payload: *const MessageBuildCtx, embed: core.UIEmbed) !*core.AppNode {
    const build_alloc = ctx.build_arena.allocator();
    const tokens = ctx.active_theme.tokens;

    var text_column_children = std.ArrayList(?*core.AppNode).empty;
    defer text_column_children.deinit(build_alloc);

    if (embed.title) |title| {
        const is_link = embed.url != null;
        try text_column_children.append(build_alloc, try ctx.ux().text(.{
            .content = title,
            .font = payload.font,
            .max_width = 340,
            .style = .{ .text_color = if (is_link) tokens.action_default else tokens.text_main },
        }));
    }

    if (embed.description) |description| {
        try text_column_children.append(build_alloc, try ctx.ux().text(.{
            .content = description,
            .font = payload.font,
            .max_width = 340,
            .style = .{ .text_color = tokens.text_muted },
        }));
    }

    var top_row_children = std.ArrayList(?*core.AppNode).empty;
    defer top_row_children.deinit(build_alloc);

    if (text_column_children.items.len > 0) {
        try top_row_children.append(build_alloc, try ctx.ux().div(.{
            .style = .{
                .direction = .Column,
                .gap = 6,
                .flex_grow = 1,
            },
            .children = try text_column_children.toOwnedSlice(build_alloc),
        }));
    }

    if (embed.thumbnail) |thumbnail| {
        if (thumbnail.url) |url| {
            const dims = calculateMediaSize(thumbnail.width, thumbnail.height, 96.0, 96.0);
            try top_row_children.append(build_alloc, try ctx.ux().asyncImage(.{
                .source = url,
                .intrinsic_size = .{
                    @as(f32, @floatFromInt(thumbnail.width orelse 0)),
                    @as(f32, @floatFromInt(thumbnail.height orelse 0)),
                },
                .style = .{
                    .width = .{ .exact = dims[0] },
                    .height = .{ .exact = dims[1] },
                    .corner_radius = core.lib.layout.CornerRadius.all(4),
                    .object_fit = .scale_down,
                },
                .alt_text = "embed-thumbnail",
                .alt_font = payload.font,
            }));
        }
    }

    var main_column_children = std.ArrayList(?*core.AppNode).empty;
    defer main_column_children.deinit(build_alloc);

    if (top_row_children.items.len > 0) {
        try main_column_children.append(build_alloc, try ctx.ux().div(.{
            .style = .{
                .width = .Full,
                .direction = .Row,
                .gap = 16,
                .align_items = .Start,
            },
            .children = try top_row_children.toOwnedSlice(build_alloc),
        }));
    }

    if (embed.image) |image| {
        if (image.url) |url| {
            const dims = calculateMediaSize(image.width, image.height, 430.0, 300.0);
            try main_column_children.append(build_alloc, try ctx.ux().asyncImage(.{
                .source = url,
                .intrinsic_size = .{
                    @as(f32, @floatFromInt(image.width orelse 0)),
                    @as(f32, @floatFromInt(image.height orelse 0)),
                },
                .style = .{
                    .width = .{ .exact = dims[0] },
                    .height = .{ .exact = dims[1] },
                    .corner_radius = core.lib.layout.CornerRadius.all(4),
                    .object_fit = .scale_down,
                },
                .alt_text = "embed-image",
                .alt_font = payload.font,
            }));
        }
    }

    const color_bar_color: [4]f32 = if (embed.color) |hex| hexToRgba(hex) else tokens.border_subtle;

    return ctx.ux().div(.{
        .style = .{
            .width = .{ .exact = 480 },
            .direction = .Row,
            .align_items = .Stretch,
            .background_color = tokens.bg_base,
            .corner_radius = core.lib.layout.CornerRadius.all(4),
        },
        .children = &.{ try ctx.ux().div(.{
            .style = .{
                .width = .{ .exact = 4 },
                .background_color = color_bar_color,
                .corner_radius = .{ .top_left = 4, .bottom_left = 4, .top_right = 0, .bottom_right = 0 },
            },
        }), try ctx.ux().div(.{
            .style = .{
                .direction = .Column,
                .gap = 12,
                .padding = .{ .top = 12, .bottom = 12, .left = 12, .right = 16 },
                .flex_grow = 1,
            },
            .children = try main_column_children.toOwnedSlice(build_alloc),
        }) },
    });
}

fn selectedGuildName(state: *const core.AppState) []const u8 {
    const selected_id = state.selected_guild_id orelse return "Direct Messages";
    for (state.guilds.items) |guild| {
        if (std.mem.eql(u8, guild.id, selected_id)) return guild.name;
    }
    return "Guild";
}

fn buildBrowseEntry(
    allocator: std.mem.Allocator,
    ui: *core.AppUIContext,
    channel: core.UIChannel,
    index: usize,
    is_selected: bool,
    browsing_dms: bool,
    font: *core.FontData,
) !*core.AppNode {
    const tokens = ui.active_theme.tokens;
    const ux = ui.ux();
    const tw = core.tw;
    const prefix = if (browsing_dms) "@ " else "# ";
    const label = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, channel.name });
    defer allocator.free(label);

    var entry_bg = if (is_selected) tokens.action_default else tokens.bg_surface;
    entry_bg[3] = if (is_selected) 0.9 else 0.72;

    var hover_bg = if (is_selected) tokens.action_hover else tokens.action_default;
    hover_bg[3] = if (is_selected) 0.95 else 0.9;

    return try ux.button(.{
        .label = label,
        .font = font,
        .class = .{
            tw.w_full,
            tw.h(32.0),
            tw.flex_row,
            tw.items_center,
            tw.justify_start,
            tw.px(2.5),
            tw.bg_value(entry_bg),
            tw.rounded(6.0),
            tw.hover_value(hover_bg),
            tw.transition_colors(100),
        },
        .label_class = .{ tw.text_color_value(if (is_selected) tokens.text_inverse else tokens.text_main), tw.text(12) },
        .on_click = if (browsing_dms) core.AppMsg{ .dm_click = index } else core.AppMsg{ .channel_click = index },
    });
}

fn onBrowseNeedData(start: usize, end: usize) core.AppMsg {
    return .{ .virtual_list_need_data = .{ .target = .browser, .start = start, .end = end } };
}

fn onBrowseScroll(delta: f32) core.AppMsg {
    return .{ .virtual_list_scroll = .{ .target = .browser, .delta = delta } };
}

fn onMessagesNeedData(start: usize, end: usize) core.AppMsg {
    return .{ .virtual_list_need_data = .{ .target = .messages, .start = start, .end = end } };
}

fn onMessagesScroll(delta: f32) core.AppMsg {
    return .{ .virtual_list_scroll = .{ .target = .messages, .delta = delta } };
}

fn buildBrowseVirtualItem(ctx: *core.AppUIContext, index: usize, userdata: ?*const anyopaque) anyerror!*core.AppNode {
    const payload: *const BrowseBuildCtx = @ptrCast(@alignCast(userdata.?));
    const items = if (payload.browsing_dms) payload.state.dms.items else payload.state.channels.items;
    if (index >= items.len) return error.IndexOutOfBounds;
    const item = items[index];
    return buildBrowseEntry(
        payload.allocator,
        ctx,
        item,
        index,
        core.isChannelSelected(payload.state, item.id),
        payload.browsing_dms,
        payload.font,
    );
}

fn buildMessageContent(ctx: *core.AppUIContext, payload: *const MessageBuildCtx, content: []const u8, body_color: [4]f32) !*core.AppNode {
    const build_alloc = ctx.build_arena.allocator();
    var children = std.ArrayList(?*core.AppNode).empty;
    defer children.deinit(build_alloc);

    var i: usize = 0;
    var last: usize = 0;
    var has_emotes = false;

    while (i < content.len) {
        if (content[i] == '<' and i + 2 < content.len and (content[i + 1] == ':' or (content[i + 1] == 'a' and content[i + 2] == ':'))) {
            const is_anim = content[i + 1] == 'a';
            const start_idx = i;
            const colon1 = std.mem.indexOfScalarPos(u8, content, if (is_anim) i + 3 else i + 2, ':');
            if (colon1) |c1| {
                const end_idx = std.mem.indexOfScalarPos(u8, content, c1 + 1, '>');
                if (end_idx) |e_idx| {
                    has_emotes = true;
                    const id_str = content[c1 + 1 .. e_idx];
                    const ext = if (is_anim) ".gif" else ".png";
                    const url = try std.fmt.allocPrint(build_alloc, "https://cdn.discordapp.com/emojis/{s}{s}", .{ id_str, ext });

                    if (start_idx > last) {
                        try children.append(build_alloc, try ctx.ux().text(.{
                            .content = try build_alloc.dupe(u8, content[last..start_idx]),
                            .font = payload.font,
                            .style = .{ .text_color = body_color },
                        }));
                    }

                    try children.append(build_alloc, try ctx.ux().asyncImage(.{
                        .source = url,
                        .style = .{
                            .width = .{ .exact = 22 },
                            .height = .{ .exact = 22 },
                            .corner_radius = core.lib.layout.CornerRadius.all(4),
                        },
                        .alt_text = try build_alloc.dupe(u8, content[start_idx .. e_idx + 1]),
                        .alt_font = payload.font,
                    }));

                    last = e_idx + 1;
                    i = e_idx + 1;
                    continue;
                }
            }
        }
        i += 1;
    }

    if (!has_emotes) {
        return ctx.ux().text(.{
            .content = content,
            .font = payload.font,
            .style = .{ .text_color = body_color },
        });
    }

    if (last < content.len) {
        try children.append(build_alloc, try ctx.ux().text(.{
            .content = try build_alloc.dupe(u8, content[last..]),
            .font = payload.font,
            .style = .{ .text_color = body_color },
        }));
    }

    return ctx.ux().div(.{
        .style = .{
            .width = .{ .exact = 620 },
            .direction = .Row,
            .flex_wrap = .Wrap,
            .gap = 4,
            .align_items = .Center,
        },
        .children = try children.toOwnedSlice(build_alloc),
    });
}

fn makeSeekMsg(value: f32, userdata: ?*const anyopaque) core.AppMsg {
    const id_ptr: *const []const u8 = @ptrCast(@alignCast(userdata.?));
    return .{ .video_seek = .{ .id = id_ptr.*, .value = value } };
}

fn makeVolumeMsg(value: f32, userdata: ?*const anyopaque) core.AppMsg {
    const id_ptr: *const []const u8 = @ptrCast(@alignCast(userdata.?));
    return .{ .video_volume = .{ .id = id_ptr.*, .value = value } };
}

fn calculateMediaSize(intrinsic_w: ?u32, intrinsic_h: ?u32, max_w: f32, max_h: f32) [2]f32 {
    if (intrinsic_w) |iw| {
        if (intrinsic_h) |ih| {
            const fw: f32 = @floatFromInt(iw);
            const fh: f32 = @floatFromInt(ih);

            if (fw <= 0.0 or fh <= 0.0) return .{ max_w, max_h };

            const scale_w = max_w / fw;
            const scale_h = max_h / fh;

            const scale = @min(@min(scale_w, scale_h), 1.0);

            return .{ @round(fw * scale), @round(fh * scale) };
        }
    }
    return .{ max_w, max_h };
}

fn buildMessageVirtualItem(ctx: *core.AppUIContext, index: usize, userdata: ?*const anyopaque) anyerror!*core.AppNode {
    const build_alloc = ctx.build_arena.allocator();
    const tw = core.tw;
    const payload: *const MessageBuildCtx = @ptrCast(@alignCast(userdata.?));
    if (index >= payload.state.messages.items.len) return error.IndexOutOfBounds;
    const message = payload.state.messages.items[index];

    const display_timestamp = if (message.delivery_status == .pending)
        try payload.allocator.dupe(u8, "sending...")
    else
        try core.formatTimestampCompact(payload.allocator, message.timestamp);
    defer payload.allocator.free(display_timestamp);
    const meta = try std.fmt.allocPrint(payload.allocator, "{s}  {s}", .{ message.author_name, display_timestamp });
    defer payload.allocator.free(meta);
    const body = if (message.content.len > 0) message.content else "(empty message)";
    const body_color: [4]f32 = switch (message.delivery_status) {
        .pending => .{ 0.72, 0.75, 0.82, 1.0 },
        else => .{ 0.95, 0.97, 1.0, 1.0 },
    };
    var content_children = std.ArrayList(?*core.AppNode).empty;
    defer content_children.deinit(build_alloc);
    try content_children.append(build_alloc, try ctx.ux().text(.{
        .content = meta,
        .font = payload.font,
        .style = .{ .text_color = .{ 0.82, 0.86, 0.95, 1.0 } },
    }));

    try content_children.append(build_alloc, try buildMessageContent(ctx, payload, body, body_color));

    const comp = ctx.components();

    for (message.attachments) |attachment| {
        if (isGifAttachment(attachment)) {
            if (payload.state.video_playbacks.getEntry(attachment.id)) |entry| {
                const video_state = entry.value_ptr.*;

                const gif_node = try comp.animatedMedia(.{
                    .playback = video_state.playback,
                    .desc = .{ .style = tw.style(.{
                        tw.w(480),
                        tw.h(270),
                        tw.rounded(8),
                        tw.cursor_pointer,
                    }) },
                    .logic = .{ .on_click = .{ .open_preview = .{
                        .url_or_id = attachment.id,
                        .is_video = true,
                        .is_gif = true,
                        .width = 800,
                        .height = 600,
                    } } },
                });
                try content_children.append(build_alloc, gif_node);
            }
            continue;
        }
        if (isImageAttachment(attachment)) {
            if (attachment.url) |url| {
                const dims = calculateMediaSize(attachment.width, attachment.height, 400.0, 300.0);

                const img_node = try ctx.ux().asyncImage(.{
                    .source = url,
                    .intrinsic_size = .{
                        @as(f32, @floatFromInt(attachment.width orelse 0)),
                        @as(f32, @floatFromInt(attachment.height orelse 0)),
                    },
                    .style = .{
                        .width = .{ .exact = dims[0] },
                        .height = .{ .exact = dims[1] },
                        .corner_radius = core.lib.layout.CornerRadius.all(8),
                        .object_fit = .scale_down,
                    },
                    .alt_text = attachment.filename,
                    .alt_font = payload.font,
                });

                try content_children.append(build_alloc, try ctx.ux().div(.{
                    .style = .{
                        .width = .{ .exact = dims[0] },
                        .height = .{ .exact = dims[1] },
                        .corner_radius = core.lib.layout.CornerRadius.all(8),
                    },
                    .events = &.{
                        .{ .event = .click, .msg = .{ .open_preview = .{
                            .url_or_id = url,
                            .is_video = false,
                            .is_gif = false,
                            .width = attachment.width orelse 800,
                            .height = attachment.height orelse 600,
                        } } },
                    },
                    .children = &.{img_node},
                }));
                continue;
            }
        }
        if (isVideoAttachment(attachment)) {
            if (payload.state.video_playbacks.getEntry(attachment.id)) |entry| {
                const video_state = entry.value_ptr.*;
                const duration = video_state.playback.getDurationS();
                const progress = if (video_state.ui_progress_override) |override|
                    override
                else if (duration > 0.0)
                    std.math.clamp(@as(f32, @floatCast(video_state.playback.getCurrentTimeS() / duration)), 0.0, 1.0)
                else
                    0.0;

                var id_buf: [64]u8 = undefined;
                const base_str = try std.fmt.bufPrint(&id_buf, "video_{s}", .{attachment.id});
                const base_id = core.components.deriveChildId(core.NodeIds.message_virtual_list, base_str);

                const dims = calculateMediaSize(attachment.width, attachment.height, 480.0, 270.0);

                const player_node = try comp.videoPlayer(.{
                    .desc = .{
                        .base_id = base_id,
                        .font = payload.font,
                        .style = tw.style(.{
                            tw.w(dims[0]),
                            tw.h(dims[1]),
                            tw.rounded(8),
                            .{ .object_fit = .contain },
                        }),
                    },
                    .logic = .{
                        .playback = video_state.playback,
                        .progress = progress,
                        .volume = video_state.volume,
                        .is_hovered = video_state.controls_hovered,
                        .on_play_toggle = .{ .video_toggle = attachment.id },
                        .on_seek = makeSeekMsg,
                        .on_volume = makeVolumeMsg,
                        .on_seek_volume_userdata = @ptrCast(&entry.key_ptr.*),
                        .on_hover_enter = .{ .video_hover = .{ .id = attachment.id, .hovered = true } },
                        .on_hover_leave = .{ .video_hover = .{ .id = attachment.id, .hovered = false } },
                    },
                });

                try content_children.append(build_alloc, try ctx.ux().div(.{
                    .style = .{
                        .width = .{ .exact = dims[0] },
                        .height = .{ .exact = dims[1] },
                        .corner_radius = core.lib.layout.CornerRadius.all(8),
                    },
                    .events = &.{
                        .{ .event = .click, .msg = .{ .open_preview = .{
                            .url_or_id = attachment.id,
                            .is_video = true,
                            .is_gif = false,
                            .width = attachment.width orelse 1280,
                            .height = attachment.height orelse 720,
                        } } },
                    },
                    .children = &.{player_node},
                }));
            } else {
                const video_card_title = try std.fmt.allocPrint(payload.allocator, "Video: {s}", .{attachment.filename});
                defer payload.allocator.free(video_card_title);
                try content_children.append(build_alloc, try ctx.ux().div(.{
                    .style = .{
                        .width = .Full,
                        .direction = .Column,
                        .gap = 4,
                        .padding = core.lib.layout.Spacing.all(8),
                        .background_color = comptime core.Color.parse("oklch(0.29 0.03 248 / 0.82)"),
                        .corner_radius = core.lib.layout.CornerRadius.all(8),
                    },
                    .children = &.{
                        try ctx.ux().text(.{
                            .content = video_card_title,
                            .font = payload.font,
                            .style = .{ .text_color = .{ 0.91, 0.94, 1.0, 1.0 } },
                        }),
                        try ctx.ux().text(.{
                            .content = maybeSlice(attachment.url),
                            .font = payload.font,
                            .max_width = 560,
                            .style = .{ .text_color = .{ 0.56, 0.76, 1.0, 1.0 } },
                        }),
                    },
                }));
            }
            continue;
        }
        try content_children.append(build_alloc, try buildAttachmentCard(ctx, payload, attachment));
    }
    for (message.embeds) |embed| {
        if (embed.video) |video| {
            if (video.url) |url| {
                if (payload.state.video_playbacks.getEntry(url)) |entry| {
                    const video_state = entry.value_ptr.*;
                    if (video_state.volume == 0.0) {
                        const gif_node = try comp.animatedMedia(.{
                            .playback = video_state.playback,
                            .desc = .{ .style = tw.style(.{
                                tw.w(480),
                                tw.h(270),
                                tw.rounded(8),
                                tw.cursor_pointer,
                            }) },
                            .logic = .{ .on_click = .{ .open_preview = .{
                                .url_or_id = url,
                                .is_video = true,
                                .is_gif = true,
                                .width = 800,
                                .height = 600,
                            } } },
                        });

                        try content_children.append(build_alloc, gif_node);
                        continue;
                    } else {
                        const duration = video_state.playback.getDurationS();
                        const progress = if (video_state.ui_progress_override) |override|
                            override
                        else if (duration > 0.0)
                            std.math.clamp(@as(f32, @floatCast(video_state.playback.getCurrentTimeS() / duration)), 0.0, 1.0)
                        else
                            0.0;

                        var id_buf: [64]u8 = undefined;
                        const final_hash = std.hash.CityHash64.hash(url);
                        const base_str = try std.fmt.bufPrint(&id_buf, "embed_video_{x}", .{final_hash});
                        const base_id = core.components.deriveChildId(core.NodeIds.message_virtual_list, base_str);

                        const player_node = try comp.videoPlayer(.{
                            .desc = .{
                                .base_id = base_id,
                                .font = payload.font,
                                .style = tw.style(.{ tw.w(480), tw.h(270), tw.rounded(8) }),
                            },
                            .logic = .{
                                .playback = video_state.playback,
                                .progress = progress,
                                .volume = video_state.volume,
                                .is_hovered = video_state.controls_hovered,
                                .on_play_toggle = .{ .video_toggle = url },
                                .on_seek = makeSeekMsg,
                                .on_volume = makeVolumeMsg,
                                .on_seek_volume_userdata = @ptrCast(&entry.key_ptr.*),
                                .on_hover_enter = .{ .video_hover = .{ .id = url, .hovered = true } },
                                .on_hover_leave = .{ .video_hover = .{ .id = url, .hovered = false } },
                            },
                        });
                        try content_children.append(build_alloc, player_node);
                        continue; // Skip embedding card if video player is shown
                    }
                }
            }
        }
        try content_children.append(build_alloc, try buildEmbedCard(ctx, payload, embed));
    }

    const avatar_node = if (message.author_avatar) |avatar_url|
        try ctx.ux().asyncImage(.{
            .source = avatar_url,
            .style = .{
                .width = .{ .exact = 36 },
                .height = .{ .exact = 36 },
                .corner_radius = core.lib.layout.CornerRadius.all(18),
            },
            .alt_text = message.author_name,
            .alt_font = payload.font,
        })
    else
        try ctx.ux().div(.{
            .style = .{
                .width = .{ .exact = 36 },
                .height = .{ .exact = 36 },
                .corner_radius = core.lib.layout.CornerRadius.all(18),
                .background_color = comptime core.Color.parse("oklch(0.45 0.08 255 / 1)"),
                .align_items = .Center,
                .justify_content = .Center,
            },
            .children = &.{
                try ctx.ux().text(.{
                    .content = message.author_name[0..@min(message.author_name.len, 1)],
                    .font = payload.font,
                    .style = .{ .text_color = .{ 1.0, 1.0, 1.0, 1.0 } },
                }),
            },
        });

    const card_bg = switch (message.delivery_status) {
        .sent => comptime core.Color.parse("oklch(0.27 0.03 255 / 0.82)"),
        .pending => comptime core.Color.parse("oklch(0.24 0.02 255 / 0.6)"),
        .failed => comptime core.Color.parse("oklch(0.34 0.1 25 / 0.78)"),
    };

    return ctx.ux().div(.{
        .style = .{
            .width = .Full,
            .direction = .Row,
            .align_items = .Start,
            .gap = 10,
            .padding = core.lib.layout.Spacing.all(8),
            .background_color = card_bg,
            .corner_radius = core.lib.layout.CornerRadius.all(8),
        },
        .children = &.{
            avatar_node,
            try ctx.ux().div(.{
                .style = .{
                    .width = .Full,
                    .direction = .Column,
                    .gap = 6,
                },
                .children = try content_children.toOwnedSlice(build_alloc),
            }),
        },
    });
}

pub fn build(allocator: std.mem.Allocator, ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const font = state.font_data;
    const tokens = ui.active_theme.tokens;
    const comp = ui.components();
    const browsing_dms = state.selected_guild_id == null;
    const browser_title = if (browsing_dms) "Direct Messages" else "Guild Channels";
    const scope_title = if (browsing_dms) "DM Browser" else selectedGuildName(state);
    const browser_context_key = if (state.selected_guild_id) |guild_id| guild_id else "dms";
    const browser_list_id = core.components.deriveChildId(core.NodeIds.browser_virtual_list, browser_context_key);
    const message_context_key = if (state.selected_channel_id) |channel_id| channel_id else "none";
    const message_list_id = core.components.deriveChildId(core.NodeIds.message_virtual_list, message_context_key);
    const ux = ui.ux();
    const tw = core.tw;

    const browse_items = if (browsing_dms) state.dms.items else state.channels.items;
    const browser_list_node = if (browse_items.len == 0)
        try ux.text(.{
            .content = "Nothing to show yet.",
            .font = font,
            .class = .{ tw.text_muted, tw.text(12), tw.px(2) },
        })
    else blk: {
        var browse_ctx = BrowseBuildCtx{
            .allocator = allocator,
            .state = state,
            .browsing_dms = browsing_dms,
            .font = font,
        };
        const list_state = @constCast(&state.browser_list);
        list_state.setTotalItems(browse_items.len);
        break :blk try comp.virtualList(.{
            .logic = .{
                .base_id = browser_list_id,
                .state = list_state,
                .on_need_data = onBrowseNeedData,
                .on_scroll = onBrowseScroll,
                .build_item_fn = buildBrowseVirtualItem,
                .build_userdata = @ptrCast(&browse_ctx),
            },
            .desc = .{ .style = tw.style(.{ tw.w_full, tw.grow_1, tw.gap(1.5) }) },
        });
    };

    const message_list_node = if (state.messages.items.len == 0)
        try ux.text(.{
            .content = "No messages loaded.",
            .font = font,
            .class = .{ tw.text_muted, tw.text(12) },
        })
    else blk: {
        var msg_ctx = MessageBuildCtx{
            .allocator = allocator,
            .state = state,
            .font = font,
        };
        const list_state = @constCast(&state.messages_list);
        list_state.setTotalItems(state.messages.items.len);
        break :blk try comp.virtualList(.{
            .logic = .{
                .base_id = message_list_id,
                .state = list_state,
                .on_need_data = onMessagesNeedData,
                .on_scroll = onMessagesScroll,
                .build_item_fn = buildMessageVirtualItem,
                .build_userdata = @ptrCast(&msg_ctx),
            },
            .desc = .{ .style = tw.style(.{ tw.w_full, tw.grow_1, tw.gap(2) }) },
        });
    };

    const dm_button = try ux.button(.{
        .label = if (browsing_dms) "DMs" else "Open DMs",
        .font = font,
        .class = .{
            tw.w(110.0),
            tw.h(32.0),
            tw.px(2.5),
            tw.bg_value(if (browsing_dms) tokens.action_default else tw.color("#3d404a")),
            tw.rounded(6.0),
            tw.hover_action,
            tw.transition_colors(100),
        },
        .label_class = .{ tw.text_inverse, tw.text(12) },
        .on_click = .{ .open_dms = {} },
    });

    const theme_button = try ux.button(.{
        .label = "Theme",
        .font = font,
        .class = .{
            tw.w(92.0),
            tw.h(32.0),
            tw.px(2.5),
            tw.bg("#3d404aff"),
            tw.border_subtle,
            tw.rounded(6.0),
            tw.hover_action_default,
            tw.transition_colors(100),
        },
        .label_class = .{ tw.text_main, tw.text(12) },
        .on_click = .{ .randomize_theme = {} },
    });

    const active_channel_text = try std.fmt.allocPrint(allocator, "Active: {s}", .{core.activeChannelName(state)});
    defer allocator.free(active_channel_text);

    const status_line = state.status_line orelse "Ready";
    const add_icon = try comp.icon(.{
        .icon_id = @intFromEnum(core.IconIds.add),
        .scale = 1.0,
        .intrinsic_size = .{ 16.0, 16.0 },
        .style = .{
            .width = .{ .exact = 16 },
            .height = .{ .exact = 16 },
        },
        .tint = tokens.text_main,
        .alt_text = "Add",
        .alt_font = font,
        .fallback_state = .ready,
    });

    return try ux.div(.{
        .class = .{
            tw.w_full,
            tw.grow_1,
            tw.flex_col,
            tw.bg("#2e3038ff"),
        },
        .children = .{
            try ux.div(.{
                .class = .{
                    tw.w_full,
                    tw.h(48.0),
                    tw.flex_row,
                    tw.items_center,
                    tw.gap(2),
                    tw.px(4),
                    tw.bg("#2e3038ff"),
                    tw.border_b(1.0, "#1a1c21ff"),
                },
                .children = .{
                    try ux.text(.{
                        .content = scope_title,
                        .font = font,
                        .class = .{ tw.text_main, tw.text(14) },
                    }),
                    try ux.div(.{ .class = tw.grow_1 }),
                    theme_button,
                    dm_button,
                },
            }),
            try ux.div(.{
                .class = .{ tw.w_full, tw.grow_1, tw.flex_row },
                .children = .{
                    try ux.div(.{
                        .class = .{
                            tw.w(240.0),
                            tw.h_full,
                            tw.flex_col,
                            tw.gap(2),
                            tw.px(2),
                            tw.py(3),
                            tw.bg("#212429ff"),
                        },
                        .children = .{
                            try ux.text(.{
                                .content = browser_title,
                                .font = font,
                                .class = .{ tw.text_color("#d1d6e6ff"), tw.text(12), tw.px(2) },
                            }),
                            try ux.div(.{
                                .class = .{ tw.w_full, tw.grow_1, tw.flex_col, tw.gap(1.5) },
                                .children = .{browser_list_node},
                            }),
                        },
                    }),
                    try ux.div(.{
                        .class = .{
                            tw.w_full,
                            tw.h_full,
                            tw.grow_1,
                            tw.flex_col,
                            tw.bg("#2e3038ff"),
                        },
                        .children = .{
                            try ux.div(.{
                                .class = .{
                                    tw.w_full,
                                    tw.h(44.0),
                                    tw.flex_row,
                                    tw.items_center,
                                    tw.gap(2),
                                    tw.px(4),
                                    tw.border_b(1.0, "#24262bff"),
                                },
                                .children = .{
                                    add_icon,
                                    try ux.text(.{
                                        .content = active_channel_text,
                                        .font = font,
                                        .class = .{ tw.text_main, tw.text(13) },
                                    }),
                                    try ux.div(.{ .class = tw.grow_1 }),
                                    try ux.text(.{
                                        .content = status_line,
                                        .font = font,
                                        .class = .{ tw.text_muted, tw.text(11) },
                                    }),
                                },
                            }),
                            try ux.div(.{
                                .class = .{ tw.w_full, tw.grow_1, tw.flex_col, tw.gap(2), tw.px(4), tw.py(3) },
                                .children = .{message_list_node},
                            }),
                            try ux.div(.{
                                .class = .{
                                    tw.w_full,
                                    tw.h(72.0),
                                    tw.flex_row,
                                    tw.items_center,
                                    tw.gap(2),
                                    tw.px(4),
                                    tw.pb(3),
                                },
                                .children = .{
                                    try ux.textArea(.{
                                        .id = core.NodeIds.input,
                                        .font = font,
                                        .class = .{
                                            tw.w_full,
                                            tw.grow_1,
                                            tw.h(46.0),
                                            tw.px(2.5),
                                            tw.py(2),
                                            tw.bg("#3d404aff"),
                                            tw.rounded(8.0),
                                            tw.text_main,
                                            tw.overflow_hidden,
                                        },
                                        .on_key_down = .{ .input_key = {} },
                                    }),
                                    try ux.button(.{
                                        .id = core.NodeIds.send_button,
                                        .label = "Send",
                                        .font = font,
                                        .class = .{
                                            tw.w(88.0),
                                            tw.h(42.0),
                                            tw.bg_action,
                                            tw.rounded(8.0),
                                            tw.hover_action,
                                            tw.transition_colors(100),
                                        },
                                        .label_class = .{ tw.text_inverse, tw.text(12) },
                                        .on_click = .{ .send = {} },
                                    }),
                                },
                            }),
                        },
                    }),
                },
            }),
        },
    });
}
