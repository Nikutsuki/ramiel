const std = @import("std");
const c = @import("c.zig").c;
const PacketQueue = @import("packet_queue.zig").PacketQueue;
const FrameQueue = @import("frame_queue.zig").FrameQueue;

pub const Demuxer = struct {
    format_ctx: *c.AVFormatContext,
    video_stream_idx: c_int,
    audio_stream_idx: c_int,

    packet_queue: *PacketQueue,
    frame_queue: *FrameQueue,

    seek_target_us: *std.atomic.Value(i64),
    decoder_flush_flag: *std.atomic.Value(bool),
    eof_reached: *std.atomic.Value(bool),
    quit_flag: *bool,
    io: std.Io,

    future: ?std.Io.Future(void) = null,

    pub fn start(self: *Demuxer) !void {
        self.future = try self.io.concurrent(task, .{self});
    }

    fn task(self: *Demuxer) void {
        var pkt = c.av_packet_alloc() orelse return;
        defer c.av_packet_free(&pkt);

        while (!self.quit_flag.*) {
            _ = self.io.checkCancel() catch break;

            const pending_seek = self.seek_target_us.load(.acquire);
            if (pending_seek >= 0) {
                self.eof_reached.store(false, .release);

                const target_stream = self.format_ctx.streams[@intCast(self.video_stream_idx)];
                const seek_pts_stream = c.av_rescale_q(
                    pending_seek,
                    .{ .num = 1, .den = 1_000_000 },
                    target_stream.*.time_base,
                );

                var start_time = target_stream.*.start_time;
                if (start_time == c.AV_NOPTS_VALUE) start_time = 0;
                const target_pts = seek_pts_stream + start_time;

                std.log.debug("[Demuxer] Initiating absolute seek to Target PTS: {d}", .{target_pts});

                _ = c.av_seek_frame(self.format_ctx, self.video_stream_idx, target_pts, c.AVSEEK_FLAG_BACKWARD);

                self.decoder_flush_flag.store(true, .release);
                self.frame_queue.clear(self.io);

                while (self.decoder_flush_flag.load(.acquire) and !self.quit_flag.*) {
                    _ = std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                }

                std.log.debug("[Demuxer] Seek handshake complete. Resuming Demux.", .{});

                _ = self.seek_target_us.cmpxchgStrong(pending_seek, -1, .release, .monotonic);
                continue;
            }

            const read_result = c.av_read_frame(self.format_ctx, pkt);
            if (read_result < 0) {
                if (read_result == c.AVERROR_EOF) {
                    if (!self.eof_reached.load(.acquire)) {
                        std.log.debug("[Demuxer] AVERROR_EOF reached. Halting packet reads.", .{});
                        self.eof_reached.store(true, .release);
                    }
                    _ = std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
                    continue;
                }
                break;
            }

            if (pkt.*.stream_index != self.video_stream_idx and pkt.*.stream_index != self.audio_stream_idx) {
                c.av_packet_unref(pkt);
                continue;
            }

            while (!self.packet_queue.push(pkt)) {
                if (self.quit_flag.* or self.seek_target_us.load(.acquire) >= 0) {
                    c.av_packet_unref(pkt);
                    break;
                }
                _ = std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
            }
        }
    }
};
