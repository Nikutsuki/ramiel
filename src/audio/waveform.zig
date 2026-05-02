//! Off-thread waveform peaks via ma_decoder, mono, num_buckets peaks in [0,1].

const std = @import("std");
const c = @import("c.zig").c;

pub const PeakSet = struct {
    peaks: []f32,
    duration_seconds: f64,

    pub fn deinit(self: *PeakSet, allocator: std.mem.Allocator) void {
        allocator.free(self.peaks);
        self.peaks = &.{};
    }
};

pub fn extractPeaks(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    num_buckets: usize,
) !PeakSet {
    if (num_buckets == 0) return error.InvalidBucketCount;

    var config = c.ma_decoder_config_init(c.ma_format_f32, 1, 0);
    var decoder: c.ma_decoder = undefined;
    if (c.ma_decoder_init_file(path.ptr, &config, &decoder) != c.MA_SUCCESS) {
        return error.DecodeInitFailed;
    }
    defer _ = c.ma_decoder_uninit(&decoder);

    var total_frames: c.ma_uint64 = 0;
    if (c.ma_decoder_get_length_in_pcm_frames(&decoder, &total_frames) != c.MA_SUCCESS) {
        return error.LengthQueryFailed;
    }
    if (total_frames == 0) return error.EmptyAudio;

    const peaks = try allocator.alloc(f32, num_buckets);
    @memset(peaks, 0.0);

    var sample_rate: c.ma_uint32 = 44100;
    sample_rate = decoder.outputSampleRate;
    const sr_f64: f64 = @floatFromInt(@max(sample_rate, 1));
    const total_f64: f64 = @floatFromInt(total_frames);
    const duration_seconds = total_f64 / sr_f64;

    const CHUNK: usize = 4096;
    var chunk_buf: [CHUNK]f32 = undefined;

    var processed: u64 = 0;
    while (processed < total_frames) {
        const remaining = total_frames - processed;
        const want: usize = @intCast(@min(@as(u64, CHUNK), remaining));

        var got: c.ma_uint64 = 0;
        const rc = c.ma_decoder_read_pcm_frames(&decoder, &chunk_buf, want, &got);
        if (rc != c.MA_SUCCESS and rc != c.MA_AT_END) break;
        if (got == 0) break;

        var i: usize = 0;
        while (i < got) : (i += 1) {
            const sample = chunk_buf[i];
            const abs_sample = @abs(sample);
            const frame_idx = processed + i;
            const f_idx: f64 = @floatFromInt(frame_idx);
            const bucket_f = f_idx * @as(f64, @floatFromInt(num_buckets)) / total_f64;
            var bucket: usize = @intFromFloat(bucket_f);
            if (bucket >= num_buckets) bucket = num_buckets - 1;
            if (abs_sample > peaks[bucket]) peaks[bucket] = abs_sample;
        }

        processed += got;
        if (rc == c.MA_AT_END) break;
    }

    return .{ .peaks = peaks, .duration_seconds = duration_seconds };
}
