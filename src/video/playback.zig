const std = @import("std");
const c = @import("c.zig").c;
const ma = @import("../audio/c.zig").c;
const glfw = @import("glfw");
const YuvTexture = @import("../renderer/vulkan/yuv_texture.zig").YuvTexture;
const Core = @import("../renderer/vulkan/core.zig").Core;
const TextureRegistry = @import("../renderer/vulkan/texture_registry.zig").TextureRegistry;
const FrameQueue = @import("frame_queue.zig").FrameQueue;
const TelemetryQueue = @import("telemetry_queue.zig").TelemetryQueue;
const Demuxer = @import("demuxer.zig").Demuxer;
const DecoderContext = @import("decoder.zig").DecoderContext;
const PacketQueue = @import("packet_queue.zig").PacketQueue;

pub const PlaybackState = enum { loading, playing, paused, buffering, ended, error_state };
const max_consecutive_frame_drops: u32 = 240;

const audio_source_vtable = ma.ma_data_source_vtable{
    .onRead = audioSourceRead,
    .onSeek = audioSourceSeek,
    .onGetDataFormat = audioSourceGetFormat,
    .onGetCursor = null,
    .onGetLength = null,
    .onSetLooping = null,
};

pub const VideoPlayback = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: u32,

    state: PlaybackState = .paused,
    quit_flag: bool = false,

    packet_queue: ?*PacketQueue = null,
    demuxer: ?*Demuxer = null,
    decoder: ?*DecoderContext = null,

    decoder_flush_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seek_target_us: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),
    audio_flush_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    skip_until_us: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),
    audio_start_pts_us: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),
    eof_reached: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    target_playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    seek_reset_pending: bool = true,
    buffer_recovered_flag: bool = false,
    first_frame_uploaded: bool = false,

    format_ctx: ?*c.AVFormatContext = null,
    codec_ctx: ?*c.AVCodecContext = null,
    video_stream_idx: c_int = -1,
    audio_stream_idx: c_int = -1,
    audio_codec_ctx: ?*c.AVCodecContext = null,
    swr_ctx: ?*c.SwrContext = null,

    width: u32 = 0,
    height: u32 = 0,

    texture: ?*YuvTexture = null,
    y_size: usize = 0,
    u_size: usize = 0,
    v_size: usize = 0,
    frame_queue: ?FrameQueue = null,
    frame_drop_threshold_us: i64 = 250_000,
    time_telemetry: TelemetryQueue = .{},
    last_push_us: i64 = 0,
    push_interval_us: i64 = 33_333,

    upload_pending: bool = false,
    audio_engine: *ma.ma_engine = undefined,
    audio_data_source: ma.ma_data_source_base = undefined,
    audio_sound: ma.ma_sound = undefined,
    audio_rb: ma.ma_pcm_rb = undefined,
    audio_ready: bool = false,

    video_time_base: c.AVRational = .{ .num = 0, .den = 1 },
    fps: f64 = 60.0,
    start_time_us: i64 = 0,
    pause_start_time_us: i64 = 0,
    consecutive_frame_drops: u32 = 0,
    output_sample_rate: u32 = 48000,
    output_channels: u32 = 2,

    path_z: [:0]const u8,
    init_future: ?std.Io.Future(void) = null,
    target_initial_state: PlaybackState = .paused,

    low_water_mark: usize = 4,
    high_water_mark: usize = 16,

    fn initWorker(self: *VideoPlayback) void {
        self.initFfmpeg() catch |err| {
            std.log.err("FFmpeg init failed: {}", .{err});
            self.state = .error_state;
            glfw.postEmptyEvent();
            return;
        };

        if (self.target_playing.load(.acquire)) {
            self.state = .playing;
            if (self.audio_ready) _ = ma.ma_sound_start(&self.audio_sound);
        } else {
            self.state = .paused;
        }

        glfw.postEmptyEvent();
    }

    fn initFfmpeg(self: *VideoPlayback) !void {
        var format_ctx_ptr: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&format_ctx_ptr, self.path_z.ptr, null, null) != 0) return error.FFmpegOpen;
        self.format_ctx = format_ctx_ptr;

        if (c.avformat_find_stream_info(self.format_ctx.?, null) < 0) return error.FFmpegStreamInfo;

        var video_codec: ?*const c.AVCodec = null;
        var audio_codec: ?*const c.AVCodec = null;

        self.video_stream_idx = -1;
        self.audio_stream_idx = -1;
        for (0..@intCast(self.format_ctx.?.nb_streams)) |i| {
            const stream = self.format_ctx.?.streams[i];
            if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                self.video_stream_idx = @intCast(i);
                video_codec = c.avcodec_find_decoder(stream.*.codecpar.*.codec_id);
            } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO and self.audio_stream_idx == -1) {
                self.audio_stream_idx = @intCast(i);
                audio_codec = c.avcodec_find_decoder(stream.*.codecpar.*.codec_id);
            }
        }

        if (self.video_stream_idx == -1 or video_codec == null) return error.NoVideoStream;

        self.codec_ctx = c.avcodec_alloc_context3(video_codec.?) orelse return error.FFmpegAlloc;
        const target_stream = self.format_ctx.?.streams[@intCast(self.video_stream_idx)];
        self.video_time_base = target_stream.*.time_base;
        if (target_stream.*.avg_frame_rate.den != 0) {
            self.fps = c.av_q2d(target_stream.*.avg_frame_rate);
        } else if (target_stream.*.r_frame_rate.den != 0) {
            self.fps = c.av_q2d(target_stream.*.r_frame_rate);
        }
        self.fps = std.math.clamp(self.fps, 1.0, 1000.0);
        if (c.avcodec_parameters_to_context(self.codec_ctx.?, target_stream.*.codecpar) < 0) return error.FFmpegCodecParams;
        if (c.avcodec_open2(self.codec_ctx.?, video_codec.?, null) < 0) return error.FFmpegCodecOpen;

        self.width = @intCast(self.codec_ctx.?.width);
        self.height = @intCast(self.codec_ctx.?.height);
        if (self.codec_ctx.?.pix_fmt != c.AV_PIX_FMT_YUV420P) return error.UnsupportedPixelFormat;

        self.y_size = @as(usize, self.width) * @as(usize, self.height);
        self.u_size = (@as(usize, self.width) / 2) * (@as(usize, self.height) / 2);
        self.v_size = self.u_size;

        self.packet_queue = try self.allocator.create(PacketQueue);
        self.packet_queue.?.* = try PacketQueue.init(self.allocator, 256);
        self.frame_queue = try FrameQueue.init(self.allocator, 32, self.y_size + self.u_size + self.v_size);

        if (self.audio_stream_idx != -1 and audio_codec != null) {
            const astream = self.format_ctx.?.streams[@intCast(self.audio_stream_idx)];
            self.audio_codec_ctx = c.avcodec_alloc_context3(audio_codec.?) orelse return error.FFmpegAlloc;
            if (c.avcodec_parameters_to_context(self.audio_codec_ctx.?, astream.*.codecpar) < 0) return error.FFmpegCodecParams;
            if (c.avcodec_open2(self.audio_codec_ctx.?, audio_codec.?, null) < 0) return error.FFmpegCodecOpen;

            var out_layout: c.AVChannelLayout = undefined;
            c.av_channel_layout_default(&out_layout, @intCast(self.output_channels));
            defer c.av_channel_layout_uninit(&out_layout);

            var in_layout: c.AVChannelLayout = astream.*.codecpar.*.ch_layout;
            if (in_layout.nb_channels == 0) {
                c.av_channel_layout_default(&in_layout, @intCast(self.output_channels));
            }
            defer if (astream.*.codecpar.*.ch_layout.nb_channels == 0) c.av_channel_layout_uninit(&in_layout);

            var swr_ptr: ?*c.SwrContext = null;
            if (c.swr_alloc_set_opts2(
                &swr_ptr,
                &out_layout,
                c.AV_SAMPLE_FMT_FLT,
                @intCast(self.output_sample_rate),
                &in_layout,
                self.audio_codec_ctx.?.sample_fmt,
                self.audio_codec_ctx.?.sample_rate,
                0,
                null,
            ) < 0) return error.FFmpegSwsContext;
            self.swr_ctx = swr_ptr;
            if (c.swr_init(self.swr_ctx.?) < 0) return error.FFmpegSwsContext;

            if (ma.ma_pcm_rb_init(
                ma.ma_format_f32,
                self.output_channels,
                @intCast(self.output_sample_rate * 8),
                null,
                null,
                &self.audio_rb,
            ) != ma.MA_SUCCESS) return error.EngineInitFailed;

            var ds_config = ma.ma_data_source_config_init();
            ds_config.vtable = &audio_source_vtable;
            if (ma.ma_data_source_init(&ds_config, &self.audio_data_source) != ma.MA_SUCCESS) return error.EngineInitFailed;

            const ds: *ma.ma_data_source = @ptrCast(&self.audio_data_source);
            if (ma.ma_sound_init_from_data_source(self.audio_engine, ds, 0, null, &self.audio_sound) != ma.MA_SUCCESS) {
                return error.EngineInitFailed;
            }
            self.audio_ready = true;
        }

        self.start_time_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
        self.pause_start_time_us = self.start_time_us;

        self.demuxer = try self.allocator.create(Demuxer);
        self.demuxer.?.* = .{
            .format_ctx = self.format_ctx.?,
            .video_stream_idx = self.video_stream_idx,
            .audio_stream_idx = self.audio_stream_idx,
            .packet_queue = self.packet_queue.?,
            .frame_queue = &self.frame_queue.?,
            .seek_target_us = &self.seek_target_us,
            .decoder_flush_flag = &self.decoder_flush_flag,
            .eof_reached = &self.eof_reached,
            .quit_flag = &self.quit_flag,
            .io = self.io,
        };

        var audio_tb = c.AVRational{ .num = 0, .den = 1 };
        if (self.audio_stream_idx != -1) {
            audio_tb = self.format_ctx.?.streams[@intCast(self.audio_stream_idx)].*.time_base;
        }

        self.decoder = try self.allocator.create(DecoderContext);
        self.decoder.?.* = .{
            .video_codec_ctx = self.codec_ctx.?,
            .audio_codec_ctx = self.audio_codec_ctx,
            .swr_ctx = self.swr_ctx,
            .video_stream_idx = self.video_stream_idx,
            .audio_stream_idx = self.audio_stream_idx,
            .video_time_base = self.video_time_base,
            .audio_time_base = audio_tb,
            .output_channels = self.output_channels,
            .output_sample_rate = self.output_sample_rate,
            .packet_queue = self.packet_queue.?,
            .frame_queue = &self.frame_queue.?,
            .audio_rb = &self.audio_rb,
            .decoder_flush_flag = &self.decoder_flush_flag,
            .skip_until_us = &self.skip_until_us,
            .audio_start_pts_us = &self.audio_start_pts_us,
            .quit_flag = &self.quit_flag,
            .io = self.io,
            .width = self.width,
            .height = self.height,
            .y_size = self.y_size,
            .u_size = self.u_size,
        };

        try self.demuxer.?.start();
        try self.decoder.?.start();
    }

    pub fn initAsync(
        allocator: std.mem.Allocator,
        io: std.Io,
        id: u32,
        path: [:0]const u8,
        audio_engine: *ma.ma_engine,
    ) !*VideoPlayback {
        const self = try allocator.create(VideoPlayback);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .id = id,
            .audio_engine = audio_engine,
            .state = .loading,
            .path_z = try allocator.dupeZ(u8, path),
        };

        self.init_future = io.concurrent(initWorker, .{self}) catch io.async(initWorker, .{self});
        return self;
    }

    pub fn play(self: *VideoPlayback) void {
        if (self.state == .loading) {
            self.target_playing.store(true, .release);
            return;
        }

        if (self.state == .paused) {
            if (self.pause_start_time_us != 0) {
                const now_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
                const pause_duration_us = now_us - self.pause_start_time_us;
                if (pause_duration_us > 0) {
                    self.start_time_us += pause_duration_us;
                }
                self.pause_start_time_us = 0;
            }
            if (self.audio_ready) {
                _ = ma.ma_sound_start(&self.audio_sound);
            }
            self.state = .playing;
        }
    }

    pub fn pause(self: *VideoPlayback) void {
        if (self.state == .loading) {
            self.target_playing.store(false, .release);
            return;
        }
        if (self.state == .playing) {
            self.pause_start_time_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
            if (self.audio_ready) {
                _ = ma.ma_sound_stop(&self.audio_sound);
            }
            self.state = .paused;
        }
    }

    pub fn setVolume(self: *VideoPlayback, volume: f32) void {
        if (!self.audio_ready) return;
        const clamped = std.math.clamp(volume, 0.0, 1.0);
        ma.ma_sound_set_volume(&self.audio_sound, clamped);
    }

    pub fn getDurationS(self: *const VideoPlayback) f64 {
        if (self.format_ctx) |ctx| {
            if (ctx.duration > 0) {
                return @as(f64, @floatFromInt(ctx.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
            }
        }
        return 0.0;
    }

    pub fn getCurrentTimeS(self: *const VideoPlayback) f64 {
        const us = self.getPlaybackClockUs();
        return @as(f64, @floatFromInt(us)) / 1_000_000.0;
    }

    pub fn seekTo(self: *VideoPlayback, target_s: f64) void {
        const target_us = @as(i64, @intFromFloat(target_s * 1_000_000.0));

        if (self.audio_ready) {
            if (self.state == .playing) _ = ma.ma_sound_stop(&self.audio_sound);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.audio_sound, 0);
        }

        const skip_val = if (target_us == 0) @as(i64, -1) else target_us;
        self.skip_until_us.store(skip_val, .release);
        self.audio_start_pts_us.store(-1, .release);

        self.seek_target_us.store(target_us, .seq_cst);
        self.seek_reset_pending = true;
        self.first_frame_uploaded = false;

        self.audio_flush_pending.store(true, .release);

        if (self.state == .ended) {
            self.state = .playing;
        }
        if (self.frame_queue) |*queue| queue.wakeAll(self.io);
    }

    pub fn stop(self: *VideoPlayback) void {
        self.pause();
        self.seekTo(0.0);
    }

    pub fn isSeeking(self: *const VideoPlayback) bool {
        return self.seek_target_us.load(.monotonic) >= 0;
    }

    pub fn deinit(self: *VideoPlayback, core: *const Core, texture_registry: *TextureRegistry) void {
        self.quit_flag = true;

        if (self.init_future) |*future| {
            future.await(self.io);
            self.init_future = null;
        }

        self.allocator.free(self.path_z);

        _ = core.vkd.deviceWaitIdle(core.logical_device) catch {};

        if (self.frame_queue) |*queue| {
            queue.wakeAll(self.io);
        }

        if (self.demuxer) |d| {
            if (d.future != null) {
                _ = d.future.?.await(self.io);
            }
            self.allocator.destroy(d);
        }

        if (self.decoder) |d| {
            if (d.future != null) {
                _ = d.future.?.await(self.io);
            }
            self.allocator.destroy(d);
        }

        if (self.packet_queue) |pq| {
            pq.deinit(self.allocator);
            self.allocator.destroy(pq);
        }

        if (self.texture) |tex| {
            tex.destroy(self.allocator, core, texture_registry);
            self.texture = null;
        }

        if (self.audio_ready) {
            _ = ma.ma_sound_stop(&self.audio_sound);
            ma.ma_sound_uninit(&self.audio_sound);
            ma.ma_data_source_uninit(&self.audio_data_source);
            ma.ma_pcm_rb_uninit(&self.audio_rb);
            self.audio_ready = false;
        }

        if (self.swr_ctx) |ctx| {
            var swr_ptr: ?*c.SwrContext = ctx;
            c.swr_free(&swr_ptr);
            self.swr_ctx = null;
        }

        if (self.codec_ctx) |ctx| {
            var codec_ctx_ptr: ?*c.AVCodecContext = ctx;
            c.avcodec_free_context(&codec_ctx_ptr);
            self.codec_ctx = null;
        }

        if (self.audio_codec_ctx) |ctx| {
            var codec_ctx_ptr: ?*c.AVCodecContext = ctx;
            c.avcodec_free_context(&codec_ctx_ptr);
            self.audio_codec_ctx = null;
        }

        if (self.format_ctx) |ctx| {
            var format_ctx_ptr: ?*c.AVFormatContext = ctx;
            c.avformat_close_input(&format_ctx_ptr);
            self.format_ctx = null;
        }

        if (self.frame_queue) |*queue| {
            queue.deinit(self.allocator);
            self.frame_queue = null;
            self.y_size = 0;
            self.u_size = 0;
            self.v_size = 0;
        }
        self.allocator.destroy(self);
    }

    pub fn getTimeUntilNextFrameS(self: *VideoPlayback) ?f64 {
        if (self.state != .playing) return null;

        const frame_queue = if (self.frame_queue) |*queue| queue else return null;
        const slot = frame_queue.peekReadSlot(self.io) orelse return null;
        const current_playback_us = self.getPlaybackClockUs();
        const delta_us = slot.pts_us - current_playback_us;

        if (delta_us <= 0) return 0.0;
        return @as(f64, @floatFromInt(delta_us)) / 1_000_000.0;
    }

    fn getPlaybackClockUs(self: *const VideoPlayback) i64 {
        if (self.audio_ready) {
            const base_pts = self.audio_start_pts_us.load(.acquire);
            if (base_pts >= 0) {
                var frames: ma.ma_uint64 = 0;
                if (ma.ma_sound_get_cursor_in_pcm_frames(&self.audio_sound, &frames) == ma.MA_SUCCESS) {
                    const secs = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.output_sample_rate));
                    return base_pts + @as(i64, @intFromFloat(secs * 1_000_000.0));
                }
            }
        }

        if (self.pause_start_time_us != 0) {
            return self.pause_start_time_us - self.start_time_us;
        }

        return @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0)) - self.start_time_us;
    }

    pub fn tickPlayback(self: *VideoPlayback, frame_index: usize) !bool {
        if (self.state == .loading or self.state == .error_state) return false;
        if (self.seek_target_us.load(.monotonic) >= 0) {
            return false;
        }

        const frame_queue = if (self.frame_queue) |*queue| queue else return false;

        if (self.seek_reset_pending) {
            if (frame_queue.peekReadSlot(self.io)) |slot| {
                const frame_us = slot.pts_us;

                const now_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
                self.start_time_us = now_us - frame_us;

                if (self.pause_start_time_us != 0) {
                    self.pause_start_time_us = now_us;
                }

                self.seek_reset_pending = false;
                self.buffer_recovered_flag = false;

                if (self.audio_ready and self.state == .playing) {
                    _ = ma.ma_sound_start(&self.audio_sound);
                }

                _ = self.time_telemetry.push(@as(f64, @floatFromInt(frame_us)) / 1_000_000.0);
            } else {
                return false;
            }
        } else if (self.buffer_recovered_flag) {
            const hardware_us = self.getPlaybackClockUs();
            const now_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
            self.start_time_us = now_us - hardware_us;
            self.buffer_recovered_flag = false;
        }

        if (self.state == .paused and !self.first_frame_uploaded) {
            if (frame_queue.peekReadSlot(self.io)) |slot| {
                if (self.texture) |tex| {
                    try tex.upload(frame_index, slot.yuv_buffer, self.y_size, self.u_size);
                    self.upload_pending = true;
                    self.first_frame_uploaded = true;
                    return true;
                }
            }
        }

        if (self.state == .paused or self.state == .ended) {
            return false;
        }

        const queued_frames = frame_queue.getReadableCount(self.io);
        const is_eof = self.eof_reached.load(.acquire);

        if (self.state == .playing and queued_frames <= self.low_water_mark and !is_eof) {
            self.state = .buffering;
            self.pause_start_time_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
            if (self.audio_ready) {
                _ = ma.ma_sound_stop(&self.audio_sound);
            }
            return false;
        } else if (self.state == .buffering) {
            var audio_is_full = false;
            if (self.audio_ready) {
                const available = ma.ma_pcm_rb_available_read(&self.audio_rb);
                const cap: u32 = self.output_sample_rate * 8;
                if (available >= (cap * 9) / 10) {
                    audio_is_full = true;
                }
            }

            if (queued_frames >= self.high_water_mark or audio_is_full or is_eof) {
                self.state = .playing;
                self.buffer_recovered_flag = true;

                if (self.pause_start_time_us != 0) {
                    const now_us = @as(i64, @intFromFloat(glfw.getTime() * 1_000_000.0));
                    self.start_time_us += (now_us - self.pause_start_time_us);
                    self.pause_start_time_us = 0;
                }

                if (self.audio_ready) {
                    _ = ma.ma_sound_start(&self.audio_sound);
                }
            } else {
                return false;
            }
        }

        const current_playback_us = self.getPlaybackClockUs();
        var uploaded = false;

        while (frame_queue.peekReadSlot(self.io)) |slot| {
            if (slot.pts_us > current_playback_us) break;

            const late_by_us = current_playback_us - slot.pts_us;
            const is_late = late_by_us > self.frame_drop_threshold_us;
            if (!is_late) {
                if (self.texture) |tex| {
                    try tex.upload(frame_index, slot.yuv_buffer, self.y_size, self.u_size);
                    self.upload_pending = true;
                    uploaded = true;
                    self.first_frame_uploaded = true;
                }
            }
            frame_queue.releaseReadSlot(self.io);
        }

        if (is_eof and self.state == .playing and frame_queue.getReadableCount(self.io) == 0) {
            self.state = .ended;
        }

        if (@abs(current_playback_us - self.last_push_us) >= self.push_interval_us) {
            self.last_push_us = current_playback_us;
            const current_s = @as(f64, @floatFromInt(current_playback_us)) / 1_000_000.0;
            _ = self.time_telemetry.push(current_s);
        }

        return uploaded;
    }
};

fn audioSourceRead(
    p_data_source: ?*anyopaque,
    p_frames_out: ?*anyopaque,
    frame_count: ma.ma_uint64,
    p_frames_read: [*c]ma.ma_uint64,
) callconv(.c) ma.ma_result {
    const source = p_data_source orelse return ma.MA_INVALID_ARGS;
    const base: *ma.ma_data_source_base = @ptrCast(@alignCast(source));
    const self: *VideoPlayback = @fieldParentPtr("audio_data_source", base);
    const total_frames: ma.ma_uint32 = @intCast(frame_count);
    var frames_fulfilled: ma.ma_uint32 = 0;
    const p_out: [*]f32 = if (p_frames_out) |p| @ptrCast(@alignCast(p)) else undefined;

    if (self.audio_flush_pending.swap(false, .acquire)) {
        while (true) {
            var discard_frames: ma.ma_uint32 = 2048;
            var rb_ptr: ?*anyopaque = null;
            if (ma.ma_pcm_rb_acquire_read(&self.audio_rb, &discard_frames, &rb_ptr) != ma.MA_SUCCESS) break;
            _ = ma.ma_pcm_rb_commit_read(&self.audio_rb, discard_frames);
            if (discard_frames == 0) break;
        }
    }

    while (frames_fulfilled < total_frames) {
        var chunk_frames: ma.ma_uint32 = total_frames - frames_fulfilled;
        var p_buffer: ?*anyopaque = null;
        if (ma.ma_pcm_rb_acquire_read(&self.audio_rb, &chunk_frames, &p_buffer) != ma.MA_SUCCESS) break;

        if (chunk_frames > 0 and p_buffer != null and p_frames_out != null) {
            const src: [*]f32 = @ptrCast(@alignCast(p_buffer.?));
            const samples = @as(usize, chunk_frames) * self.output_channels;
            const offset = @as(usize, frames_fulfilled) * self.output_channels;
            @memcpy(p_out[offset .. offset + samples], src[0..samples]);
        }
        _ = ma.ma_pcm_rb_commit_read(&self.audio_rb, chunk_frames);

        if (chunk_frames == 0) break;
        frames_fulfilled += chunk_frames;
    }

    if (frames_fulfilled < total_frames) {
        if (self.state == .ended) {
            if (p_frames_read != null) p_frames_read[0] = frames_fulfilled;
            return ma.MA_SUCCESS;
        }

        if (p_frames_out != null) {
            const missing_frames = total_frames - frames_fulfilled;
            const samples = @as(usize, missing_frames) * self.output_channels;
            const offset = @as(usize, frames_fulfilled) * self.output_channels;
            @memset(p_out[offset .. offset + samples], 0);
        }
        frames_fulfilled = total_frames;
    }

    if (frames_fulfilled < total_frames and self.state == .playing) {
        std.log.warn("[Audio HW] UNDERFLOW! Requested: {d} | Provided: {d} | State: {s}", .{ total_frames, frames_fulfilled, @tagName(self.state) });
    }

    if (p_frames_read != null) p_frames_read[0] = frames_fulfilled;
    return ma.MA_SUCCESS;
}

fn audioSourceSeek(
    p_data_source: ?*anyopaque,
    frame_index: ma.ma_uint64,
) callconv(.c) ma.ma_result {
    _ = p_data_source;
    _ = frame_index;
    return ma.MA_SUCCESS;
}

fn audioSourceGetFormat(
    p_data_source: ?*anyopaque,
    p_format: [*c]ma.ma_format,
    p_channels: [*c]ma.ma_uint32,
    p_sample_rate: [*c]ma.ma_uint32,
    p_channel_map: [*c]ma.ma_channel,
    channel_map_cap: usize,
) callconv(.c) ma.ma_result {
    _ = p_channel_map;
    _ = channel_map_cap;
    const source = p_data_source orelse return ma.MA_INVALID_ARGS;
    const base: *ma.ma_data_source_base = @ptrCast(@alignCast(source));
    const self: *VideoPlayback = @fieldParentPtr("audio_data_source", base);
    if (p_format != null) p_format[0] = ma.ma_format_f32;
    if (p_channels != null) p_channels[0] = self.output_channels;
    if (p_sample_rate != null) p_sample_rate[0] = self.output_sample_rate;
    return ma.MA_SUCCESS;
}
