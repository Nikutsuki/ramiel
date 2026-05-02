const std = @import("std");

pub fn cubicBezier(progress: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    if (progress <= 0.0) return 0.0;
    if (progress >= 1.0) return 1.0;

    const ax = 1.0 - 3.0 * x2 + 3.0 * x1;
    const bx = 3.0 * x2 - 6.0 * x1;
    const cx = 3.0 * x1;

    const ay = 1.0 - 3.0 * y2 + 3.0 * y1;
    const by = 3.0 * y2 - 6.0 * y1;
    const cy = 3.0 * y1;

    var t = progress;
    for (0..8) |_| {
        const x_val = ((ax * t + bx) * t + cx) * t;
        const dx = ((3.0 * ax * t + 2.0 * bx) * t + cx); // X'(t)
        if (@abs(dx) < 1e-6) break;
        t -= (x_val - progress) / dx;
        t = std.math.clamp(t, 0.0, 1.0);
    }

    return ((ay * t + by) * t + cy) * t;
}

pub const EasingFunction = union(enum) {
    linear,
    ease,
    ease_in,
    ease_out,
    ease_in_out,
    step_start,
    step_end,
    cubic_bezier: struct { x1: f32, y1: f32, x2: f32, y2: f32 },

    pub fn apply(self: EasingFunction, t: f32) f32 {
        return switch (self) {
            .linear => t,
            .ease => cubicBezier(t, 0.25, 0.1, 0.25, 1.0),
            .ease_in => cubicBezier(t, 0.42, 0.0, 1.0, 1.0),
            .ease_out => cubicBezier(t, 0.0, 0.0, 0.58, 1.0),
            .ease_in_out => cubicBezier(t, 0.42, 0.0, 0.58, 1.0),
            .step_start => if (t > 0.0) 1.0 else 0.0,
            .step_end => if (t >= 1.0) 1.0 else 0.0,
            .cubic_bezier => |p| cubicBezier(t, p.x1, p.y1, p.x2, p.y2),
        };
    }
};

test "linear easing is identity" {
    const e: EasingFunction = .linear;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.apply(0.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.apply(0.5), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.apply(1.0), 1e-5);
}

test "ease_out at 0 and 1" {
    const e: EasingFunction = .ease_out;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.apply(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.apply(1.0), 1e-4);
}

test "step_start jumps at t>0" {
    const e: EasingFunction = .step_start;
    try std.testing.expectEqual(@as(f32, 0.0), e.apply(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), e.apply(0.001));
    try std.testing.expectEqual(@as(f32, 1.0), e.apply(1.0));
}

test "step_end stays at 0 until t=1" {
    const e: EasingFunction = .step_end;
    try std.testing.expectEqual(@as(f32, 0.0), e.apply(0.0));
    try std.testing.expectEqual(@as(f32, 0.0), e.apply(0.999));
    try std.testing.expectEqual(@as(f32, 1.0), e.apply(1.0));
}

test "cubic_bezier round-trips ease-in-out values" {
    const e = EasingFunction{ .cubic_bezier = .{ .x1 = 0.42, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.apply(0.5), 1e-3);
}
