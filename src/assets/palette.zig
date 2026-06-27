const std = @import("std");
const color_math = @import("../ui/color.zig");

pub const Color = color_math.Color;

pub const ColorScale = struct {
    step_50: Color,
    step_100: Color,
    step_200: Color,
    step_300: Color,
    step_400: Color,
    step_500: Color,
    step_600: Color,
    step_700: Color,
    step_800: Color,
    step_900: Color,
};

pub const Palette = struct {
    brand: ColorScale,
    brand_secondary: ColorScale,
    accent: ColorScale,
    neutral: ColorScale,
    success: ColorScale,
    warning: ColorScale,
    info: ColorScale,
    danger: ColorScale,

    pub fn init(base_brand_oklch: [4]f32) Palette {
        const l = base_brand_oklch[0];
        const c = base_brand_oklch[1];
        const h = base_brand_oklch[2];

        return .{
            .brand = generateScale(l, c, h),
            .brand_secondary = generateScale(l, c * 0.72, @mod(h + 34.0, 360.0)),
            .accent = generateScale(l, c * 0.9, @mod(h + 150.0, 360.0)),
            .neutral = generateScale(0.5, 0.018, @mod(h + 8.0, 360.0)),
            .success = generateScale(0.6, 0.15, 140.0),
            .warning = generateScale(0.7, 0.16, 80.0),
            .info = generateScale(0.62, 0.13, @mod(h + 220.0, 360.0)),
            .danger = generateScale(0.5, 0.18, 30.0),
        };
    }

    pub fn initRandom(prng: std.Random) Palette {
        const h = prng.float(f32) * 360.0;
        const c = 0.12 + (prng.float(f32) * 0.08);
        return init(.{ 0.6, c, h, 1.0 });
    }

    fn generateScale(base_l: f32, base_c: f32, h: f32) ColorScale {
        const l_offset = base_l - 0.60;

        return .{
            .step_50 = color_math.oklch(@max(0.98 + l_offset, 0.90), base_c * 0.2, h, 1.0),
            .step_100 = color_math.oklch(@max(0.95 + l_offset, 0.85), base_c * 0.4, h, 1.0),
            .step_200 = color_math.oklch(@max(0.88 + l_offset, 0.75), base_c * 0.7, h, 1.0),
            .step_300 = color_math.oklch(@max(0.80 + l_offset, 0.65), base_c * 0.9, h, 1.0),
            .step_400 = color_math.oklch(@max(0.70 + l_offset, 0.55), base_c, h, 1.0),
            .step_500 = color_math.oklch(base_l, base_c, h, 1.0),
            .step_600 = color_math.oklch(@min(0.50 + l_offset, 0.65), base_c, h, 1.0),
            .step_700 = color_math.oklch(@min(0.40 + l_offset, 0.55), base_c * 0.9, h, 1.0),
            .step_800 = color_math.oklch(@min(0.30 + l_offset, 0.45), base_c * 0.7, h, 1.0),
            .step_900 = color_math.oklch(@min(0.20 + l_offset, 0.35), base_c * 0.4, h, 1.0),
        };
    }
};
