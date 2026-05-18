const std = @import("std");
const core = @import("../core.zig");
const loading = @import("loading.zig");
const content = @import("content.zig");
const guild_bar = @import("guild_bar.zig");
const tooltip = @import("tooltip.zig");

fn makeSeekMsg(value: f32, userdata: ?*const anyopaque) core.AppMsg {
    const id_ptr: *const []const u8 = @ptrCast(@alignCast(userdata.?));
    return .{ .video_seek = .{ .id = id_ptr.*, .value = value } };
}

fn makeVolumeMsg(value: f32, userdata: ?*const anyopaque) core.AppMsg {
    const id_ptr: *const []const u8 = @ptrCast(@alignCast(userdata.?));
    return .{ .video_volume = .{ .id = id_ptr.*, .value = value } };
}

pub fn build(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const allocator = ui.gpa;
    const font_data = state.font_data;
    const tokens = ui.active_theme.tokens;
    const ux = ui.ux();
    const tw = core.tw;

    if (!state.is_bootstrapped.load(.acquire)) {
        return loading.build(ui, font_data);
    }
    const content_node = try content.build(allocator, ui, state);
    const guild_bar_node = try guild_bar.build(allocator, ui, state);
    const tooltip_node = try tooltip.build(ui, state, font_data);

    const build_alloc = ui.build_arena.allocator();
    var children = std.ArrayList(?*core.AppNode).empty;
    defer children.deinit(build_alloc);

    try children.append(build_alloc, guild_bar_node);
    try children.append(build_alloc, content_node);
    try children.append(build_alloc, tooltip_node);

    if (state.preview_media) |media| {
        const comp = ui.components();
        var media_node: ?*core.AppNode = null;

        if (media.is_video) {
            if (state.video_playbacks.getEntry(media.url_or_id)) |entry| {
                const video_state = entry.value_ptr.*;
                if (media.is_gif) {
                    media_node = try comp.animatedMedia(.{
                        .playback = video_state.playback,
                        .desc = .{ .style = tw.style(.{ tw.w_full, tw.h_full, .{ .object_fit = .contain } }) },
                    });
                } else {
                    const duration = video_state.playback.getDurationS();
                    const progress = if (video_state.ui_progress_override) |override| override else if (duration > 0.0) std.math.clamp(@as(f32, @floatCast(video_state.playback.getCurrentTimeS() / duration)), 0.0, 1.0) else 0.0;

                    var id_buf: [64]u8 = undefined;
                    const base_str = try std.fmt.bufPrint(&id_buf, "fs_vid_{s}", .{media.url_or_id});
                    const base_id = core.components.deriveChildId(core.NodeIds.message_virtual_list, base_str);

                    media_node = try comp.videoPlayer(.{
                        .desc = .{
                            .base_id = base_id,
                            .font = font_data,
                            .style = tw.style(.{ tw.w_full, tw.h_full, .{ .object_fit = .contain } }),
                        },
                        .logic = .{
                            .playback = video_state.playback,
                            .progress = progress,
                            .volume = video_state.volume,
                            .is_hovered = video_state.controls_hovered,
                            .on_play_toggle = .{ .video_toggle = media.url_or_id },
                            .on_seek = makeSeekMsg,
                            .on_volume = makeVolumeMsg,
                            .on_seek_volume_userdata = @ptrCast(&entry.key_ptr.*),
                            .on_hover_enter = .{ .video_hover = .{ .id = media.url_or_id, .hovered = true } },
                            .on_hover_leave = .{ .video_hover = .{ .id = media.url_or_id, .hovered = false } },
                        },
                    });
                }
            }
        } else {
            media_node = try ui.ux().asyncImage(.{
                .source = media.url_or_id,
                .intrinsic_size = .{
                    @as(f32, @floatFromInt(media.width)),
                    @as(f32, @floatFromInt(media.height)),
                },
                .style = tw.style(.{ tw.size_full, tw.object_contain }),
                .alt_text = "Fullscreen Preview",
                .alt_font = font_data,
            });
        }

        if (media_node) |mn| {
            var overlay_bg = tokens.bg_base;
            overlay_bg[3] = 0.8;

            const preview_overlay = try ux.div(.{
                .class = .{
                    .{ .position = .absolute },
                    tw.w_full,
                    tw.h_full,
                    tw.bg_value(overlay_bg),
                    tw.items_center,
                    tw.justify_center,
                    .{ .backdrop_blur = 10 },
                    .{ .z_index = 100 },
                    tw.p_px(40.0),
                },
                .on_click = .{ .close_preview = {} },
                .children = .{mn},
            });
            try children.append(build_alloc, preview_overlay);
        }
    }

    var container_bg = tokens.bg_base;
    container_bg[3] = 0.0;

    const container = try ux.div(.{
        .class = .{
            tw.w_full,
            tw.h_full,
            tw.bg_value(container_bg),
            tw.flex_row,
        },
        .children = try children.toOwnedSlice(build_alloc),
    });

    return try ux.div(.{
        .class = .{
            tw.size_screen,
            tw.flex_col,
            tw.bg_surface,
        },
        .children = .{container},
    });
}
