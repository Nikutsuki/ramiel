const std = @import("std");
const c = @import("c.zig").c;
const ma = @import("../audio/c.zig").c;
const PacketQueue = @import("packet_queue.zig").PacketQueue;
const FrameQueue = @import("frame_queue.zig").FrameQueue;

pub const DecoderContext = struct {
    video_codec_ctx: *c.AVCodecContext,
    audio_codec_ctx: ?*c.AVCodecContext,
    swr_ctx: ?*c.SwrContext,

    video_stream_idx: c_int,
    audio_stream_idx: c_int,
    video_time_base: c.AVRational,
    audio_time_base: c.AVRational,
    output_channels: u32,
    output_sample_rate: u32,

    packet_queue: *PacketQueue,
    frame_queue: *FrameQueue,
    audio_rb: *ma.ma_pcm_rb,

    decoder_flush_flag: *std.atomic.Value(bool),
    skip_until_us: *std.atomic.Value(i64),
    audio_start_pts_us: *std.atomic.Value(i64),
    quit_flag: *bool,
    io: std.Io,

    width: u32,
    height: u32,
    y_size: usize,
    u_size: usize,

    future: ?std.Io.Future(void) = null,

    pub fn start(self: *DecoderContext) !void {
        self.future = try self.io.concurrent(task, .{self});
    }

    fn task(self: *DecoderContext) void {
        var raw_pkt = c.av_packet_alloc() orelse return;
        defer c.av_packet_free(&raw_pkt);
        const pkt: *c.AVPacket = @ptrCast(raw_pkt);

        var raw_frm = c.av_frame_alloc() orelse return;
        defer c.av_frame_free(&raw_frm);
        const frm: *c.AVFrame = @ptrCast(raw_frm);

        var track_audio_pts: bool = true;

        while (!self.quit_flag.*) {
            _ = self.io.checkCancel() catch break;

            if (self.decoder_flush_flag.load(.acquire)) {
                c.avcodec_flush_buffers(self.video_codec_ctx);
                if (self.audio_codec_ctx) |actx| c.avcodec_flush_buffers(actx);
                if (self.swr_ctx) |swr| _ = c.swr_init(swr);

                self.packet_queue.flush();
                self.frame_queue.clear(self.io);

                track_audio_pts = true;
                self.decoder_flush_flag.store(false, .release);
                continue;
            }

            if (!self.packet_queue.pop(raw_pkt)) {
                _ = std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
                continue;
            }
            defer c.av_packet_unref(raw_pkt);

            const is_video = pkt.stream_index == self.video_stream_idx;
            const target_ctx = if (is_video) self.video_codec_ctx else self.audio_codec_ctx.?;

            if (c.avcodec_send_packet(target_ctx, raw_pkt) == 0) {
                while (c.avcodec_receive_frame(target_ctx, raw_frm) == 0) {
                    if (self.decoder_flush_flag.load(.acquire)) break;

                    if (is_video) {
                        var pts = frm.pts;
                        if (pts == c.AV_NOPTS_VALUE) pts = frm.best_effort_timestamp;
                        if (pts == c.AV_NOPTS_VALUE or self.video_time_base.den == 0) continue;

                        const pts_seconds = @as(f64, @floatFromInt(pts)) * c.av_q2d(self.video_time_base);
                        const frame_pts_us = @as(i64, @intFromFloat(pts_seconds * 1_000_000.0));

                        if (frame_pts_us < self.skip_until_us.load(.acquire)) continue;

                        const slot = self.frame_queue.acquireWriteSlot(self.io, self.quit_flag) orelse break;
                        if (self.quit_flag.*) break;

                        const y_dst = slot.yuv_buffer[0..self.y_size];
                        const u_dst = slot.yuv_buffer[self.y_size .. self.y_size + self.u_size];
                        const v_dst = slot.yuv_buffer[self.y_size + self.u_size ..];

                        copyPlane(y_dst, frm.data[0], self.width, self.height, frm.linesize[0]);
                        copyPlane(u_dst, frm.data[1], self.width / 2, self.height / 2, frm.linesize[1]);
                        copyPlane(v_dst, frm.data[2], self.width / 2, self.height / 2, frm.linesize[2]);

                        self.frame_queue.commitWriteSlot(self.io, frame_pts_us);
                    } else if (self.swr_ctx != null) {
                        var pts = frm.pts;
                        if (pts == c.AV_NOPTS_VALUE) pts = frm.best_effort_timestamp;

                        if (pts != c.AV_NOPTS_VALUE and self.audio_time_base.den != 0) {
                            const pts_seconds = @as(f64, @floatFromInt(pts)) * c.av_q2d(self.audio_time_base);
                            const audio_pts_us = @as(i64, @intFromFloat(pts_seconds * 1_000_000.0));

                            if (audio_pts_us < self.skip_until_us.load(.acquire)) continue;

                            if (track_audio_pts) {
                                self.audio_start_pts_us.store(audio_pts_us, .release);
                                track_audio_pts = false;
                            }
                        }

                        var out_samples: [8192]f32 = undefined;
                        var out_data: [1][*c]u8 = .{@ptrCast(out_samples[0..].ptr)};
                        const out_frames_cap: c_int = @intCast(out_samples.len / self.output_channels);

                        const got_frames = c.swr_convert(
                            self.swr_ctx.?,
                            &out_data,
                            out_frames_cap,
                            @ptrCast(&frm.data),
                            frm.nb_samples,
                        );

                        if (got_frames > 0) {
                            const sample_count: usize = @intCast(got_frames * @as(c_int, @intCast(self.output_channels)));
                            self.writeAudioSamples(out_samples[0..sample_count]);
                        }
                    }
                }
            }
        }
    }

    fn writeAudioSamples(self: *DecoderContext, samples: []const f32) void {
        var src_index: usize = 0;
        var stall_warning_triggered = false;

        while (src_index < samples.len and !self.quit_flag.*) {
            if (self.decoder_flush_flag.load(.acquire)) break;

            var writable_frames: ma.ma_uint32 = @intCast((samples.len - src_index) / self.output_channels);
            var out_ptr: ?*anyopaque = null;

            if (ma.ma_pcm_rb_acquire_write(self.audio_rb, &writable_frames, &out_ptr) != ma.MA_SUCCESS) break;

            if (writable_frames == 0 or out_ptr == null) {
                const available_read = ma.ma_pcm_rb_available_read(self.audio_rb);
                const capacity: u32 = self.output_sample_rate * 8;

                if (!stall_warning_triggered) {
                    std.log.warn("[Decoder] Audio RB FULL. Contains: {d}/{d} frames. Thread stalled.", .{ available_read, capacity });
                    stall_warning_triggered = true;
                }
                _ = std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                continue;
            }

            const dst: [*]f32 = @ptrCast(@alignCast(out_ptr.?));
            const writable_samples = @as(usize, writable_frames) * self.output_channels;
            @memcpy(dst[0..writable_samples], samples[src_index .. src_index + writable_samples]);
            _ = ma.ma_pcm_rb_commit_write(self.audio_rb, writable_frames);
            src_index += writable_samples;
        }
    }
};

fn copyPlane(dst: []u8, src: [*c]u8, width: usize, height: usize, linesize: c_int) void {
    if (width == 0 or height == 0 or linesize <= 0) return;
    const src_stride: usize = @intCast(linesize);
    const plane_size = width * height;
    if (src_stride == width) {
        @memcpy(dst[0..plane_size], src[0..plane_size]);
        return;
    }
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = src + (y * src_stride);
        const dst_row = dst[y * width ..][0..width];
        @memcpy(dst_row, src_row[0..width]);
    }
}
