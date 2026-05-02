//! FFT spectrum over the audio tap: Hann window, in-place radix-2, log-spaced bands,
//! one-pole peak-fall smoothing.

const std = @import("std");

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    fft_size: usize,
    n_bands: usize,
    sample_rate: f32,

    real: []f32,
    imag: []f32,
    window: []f32,
    band_lo: []u32,
    band_hi: []u32,
    bands: []f32,

    decay: f32 = 0.85,
    db_floor: f32 = -72.0,
    db_ceiling: f32 = -6.0,

    pub fn init(
        allocator: std.mem.Allocator,
        fft_size: usize,
        n_bands: usize,
        sample_rate: f32,
    ) !Analyzer {
        if (fft_size == 0 or (fft_size & (fft_size - 1)) != 0) return error.FftSizeNotPow2;
        if (n_bands == 0) return error.InvalidBandCount;

        const real = try allocator.alloc(f32, fft_size);
        errdefer allocator.free(real);
        const imag = try allocator.alloc(f32, fft_size);
        errdefer allocator.free(imag);
        const window = try allocator.alloc(f32, fft_size);
        errdefer allocator.free(window);
        const band_lo = try allocator.alloc(u32, n_bands);
        errdefer allocator.free(band_lo);
        const band_hi = try allocator.alloc(u32, n_bands);
        errdefer allocator.free(band_hi);
        const bands = try allocator.alloc(f32, n_bands);
        errdefer allocator.free(bands);

        const n_f: f32 = @floatFromInt(fft_size - 1);
        for (window, 0..) |*w, i| {
            const t: f32 = @floatFromInt(i);
            w.* = 0.5 * (1.0 - @cos(2.0 * std.math.pi * t / n_f));
        }

        const nyquist: f32 = sample_rate * 0.5;
        const f_min: f32 = 20.0;
        const f_max: f32 = @max(nyquist, f_min + 1.0);
        const log_min: f32 = @log(f_min);
        const log_max: f32 = @log(f_max);
        const fft_bins: u32 = @intCast(fft_size / 2);
        const bin_hz: f32 = sample_rate / @as(f32, @floatFromInt(fft_size));

        for (0..n_bands) |b| {
            const t0: f32 = @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(n_bands));
            const t1: f32 = @as(f32, @floatFromInt(b + 1)) / @as(f32, @floatFromInt(n_bands));
            const lo_hz: f32 = @exp(log_min + (log_max - log_min) * t0);
            const hi_hz: f32 = @exp(log_min + (log_max - log_min) * t1);
            var lo: u32 = @intFromFloat(@max(1.0, @floor(lo_hz / bin_hz)));
            var hi: u32 = @intFromFloat(@max(@as(f32, @floatFromInt(lo + 1)), @ceil(hi_hz / bin_hz)));
            if (hi > fft_bins) hi = fft_bins;
            if (lo >= hi) lo = hi - 1;
            band_lo[b] = lo;
            band_hi[b] = hi;
        }

        @memset(bands, 0);

        return .{
            .allocator = allocator,
            .fft_size = fft_size,
            .n_bands = n_bands,
            .sample_rate = sample_rate,
            .real = real,
            .imag = imag,
            .window = window,
            .band_lo = band_lo,
            .band_hi = band_hi,
            .bands = bands,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.allocator.free(self.real);
        self.allocator.free(self.imag);
        self.allocator.free(self.window);
        self.allocator.free(self.band_lo);
        self.allocator.free(self.band_hi);
        self.allocator.free(self.bands);
    }

    pub fn compute(self: *Analyzer, samples: []const f32) void {
        const n = self.fft_size;

        const copy_n = @min(samples.len, n);
        for (0..copy_n) |i| {
            self.real[i] = samples[i] * self.window[i];
            self.imag[i] = 0.0;
        }
        for (copy_n..n) |i| {
            self.real[i] = 0.0;
            self.imag[i] = 0.0;
        }

        fft(self.real, self.imag);

        const norm: f32 = 2.0 / @as(f32, @floatFromInt(n));
        for (0..self.n_bands) |b| {
            const lo = self.band_lo[b];
            const hi = self.band_hi[b];
            var peak: f32 = 0.0;
            var i: u32 = lo;
            while (i < hi) : (i += 1) {
                const re = self.real[i];
                const im = self.imag[i];
                const mag = @sqrt(re * re + im * im) * norm;
                if (mag > peak) peak = mag;
            }
            const safe = @max(peak, 1e-9);
            const db = 20.0 * std.math.log10(safe);
            const t = (db - self.db_floor) / (self.db_ceiling - self.db_floor);
            const new_val = std.math.clamp(t, 0.0, 1.0);

            const cur = self.bands[b];
            const next = if (new_val >= cur) new_val else cur * self.decay;
            self.bands[b] = next;
        }
    }
};

fn fft(re: []f32, im: []f32) void {
    const n = re.len;
    std.debug.assert(re.len == im.len);
    std.debug.assert(n != 0 and (n & (n - 1)) == 0);

    var j: usize = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var bit: usize = n >> 1;
        while ((j & bit) != 0) {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len >> 1;
        const angle: f32 = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen_re: f32 = @cos(angle);
        const wlen_im: f32 = @sin(angle);

        var k: usize = 0;
        while (k < n) : (k += len) {
            var w_re: f32 = 1.0;
            var w_im: f32 = 0.0;
            var p: usize = 0;
            while (p < half) : (p += 1) {
                const a_re = re[k + p];
                const a_im = im[k + p];
                const b_re = re[k + p + half];
                const b_im = im[k + p + half];
                const t_re = b_re * w_re - b_im * w_im;
                const t_im = b_re * w_im + b_im * w_re;
                re[k + p] = a_re + t_re;
                im[k + p] = a_im + t_im;
                re[k + p + half] = a_re - t_re;
                im[k + p + half] = a_im - t_im;
                const nw_re = w_re * wlen_re - w_im * wlen_im;
                const nw_im = w_re * wlen_im + w_im * wlen_re;
                w_re = nw_re;
                w_im = nw_im;
            }
        }
    }
}

test "fft round-trips a single-sample impulse" {
    const allocator = std.testing.allocator;
    const N: usize = 16;
    const re = try allocator.alloc(f32, N);
    defer allocator.free(re);
    const im = try allocator.alloc(f32, N);
    defer allocator.free(im);
    @memset(re, 0);
    @memset(im, 0);
    re[0] = 1.0;
    fft(re, im);
    for (0..N) |k| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), re[k], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), im[k], 1e-5);
    }
}

test "analyzer detects a single-tone peak in the right band" {
    const allocator = std.testing.allocator;
    const N: usize = 1024;
    const sample_rate: f32 = 44100.0;
    const tone_hz: f32 = 1000.0;
    const samples = try allocator.alloc(f32, N);
    defer allocator.free(samples);
    for (samples, 0..) |*s, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / sample_rate;
        s.* = @sin(2.0 * std.math.pi * tone_hz * t);
    }
    var an = try Analyzer.init(allocator, N, 32, sample_rate);
    defer an.deinit();
    an.compute(samples);

    var max_band: usize = 0;
    var max_val: f32 = 0;
    for (an.bands, 0..) |v, idx| {
        if (v > max_val) {
            max_val = v;
            max_band = idx;
        }
    }
    const lo_hz = @as(f32, @floatFromInt(an.band_lo[max_band])) * sample_rate / @as(f32, @floatFromInt(N));
    const hi_hz = @as(f32, @floatFromInt(an.band_hi[max_band])) * sample_rate / @as(f32, @floatFromInt(N));
    try std.testing.expect(lo_hz <= tone_hz);
    try std.testing.expect(hi_hz >= tone_hz);
    try std.testing.expect(max_val > 0.5);
}
