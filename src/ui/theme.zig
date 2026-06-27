const std = @import("std");
const palette_lib = @import("../assets/palette.zig");
const Color = palette_lib.Color;

pub const SemanticTokens = struct {
    bg_base: Color,
    bg_surface: Color,
    bg_elevated: Color,
    bg_subtle: Color,
    bg_overlay: Color,

    text_main: Color,
    text_muted: Color,
    text_inverse: Color,
    text_disabled: Color,
    text_accent: Color,

    action_default: Color,
    action_hover: Color,
    action_pressed: Color,
    action_disabled: Color,
    action_subtle: Color,
    action_text: Color,

    accent_default: Color,
    accent_hover: Color,
    accent_pressed: Color,
    accent_subtle: Color,
    accent_text: Color,

    secondary_default: Color,
    secondary_hover: Color,
    secondary_pressed: Color,
    secondary_subtle: Color,
    secondary_text: Color,

    status_success: Color,
    status_success_bg: Color,
    status_success_text: Color,
    status_warning: Color,
    status_warning_bg: Color,
    status_warning_text: Color,
    status_info: Color,
    status_info_bg: Color,
    status_info_text: Color,
    status_danger: Color,
    status_danger_bg: Color,
    status_danger_text: Color,

    border_subtle: Color,
    border_strong: Color,
    border_focus: Color,

    pub fn init(p: *const palette_lib.Palette, is_dark: bool) SemanticTokens {
        if (is_dark) {
            return .{
                .bg_base = p.neutral.step_800,
                .bg_surface = p.neutral.step_700,
                .bg_elevated = p.neutral.step_600,
                .bg_subtle = p.neutral.step_900,
                .bg_overlay = withAlpha(p.neutral.step_900, 0.88),

                .text_main = p.neutral.step_50,
                .text_muted = p.neutral.step_400,
                .text_inverse = p.neutral.step_900,
                .text_disabled = p.neutral.step_600,
                .text_accent = p.brand.step_300,

                .action_default = p.brand.step_500,
                .action_hover = p.brand.step_400,
                .action_pressed = p.brand.step_600,
                .action_disabled = p.neutral.step_700,
                .action_subtle = withAlpha(p.brand.step_700, 0.38),
                .action_text = p.neutral.step_50,

                .accent_default = p.accent.step_500,
                .accent_hover = p.accent.step_400,
                .accent_pressed = p.accent.step_600,
                .accent_subtle = withAlpha(p.accent.step_700, 0.36),
                .accent_text = p.accent.step_200,

                .secondary_default = p.brand_secondary.step_500,
                .secondary_hover = p.brand_secondary.step_400,
                .secondary_pressed = p.brand_secondary.step_600,
                .secondary_subtle = withAlpha(p.brand_secondary.step_700, 0.34),
                .secondary_text = p.brand_secondary.step_200,

                .status_success = p.success.step_400,
                .status_success_bg = withAlpha(p.success.step_800, 0.44),
                .status_success_text = p.success.step_200,
                .status_warning = p.warning.step_400,
                .status_warning_bg = withAlpha(p.warning.step_800, 0.46),
                .status_warning_text = p.warning.step_200,
                .status_info = p.info.step_400,
                .status_info_bg = withAlpha(p.info.step_800, 0.44),
                .status_info_text = p.info.step_200,
                .status_danger = p.danger.step_400,
                .status_danger_bg = withAlpha(p.danger.step_800, 0.46),
                .status_danger_text = p.danger.step_200,

                .border_subtle = p.neutral.step_700,
                .border_strong = p.neutral.step_500,
                .border_focus = p.brand.step_400,
            };
        } else {
            return .{
                .bg_base = p.neutral.step_50,
                .bg_surface = p.neutral.step_100,
                .bg_elevated = p.neutral.step_50,
                .bg_subtle = p.neutral.step_200,
                .bg_overlay = withAlpha(p.neutral.step_50, 0.92),

                .text_main = p.neutral.step_900,
                .text_muted = p.neutral.step_500,
                .text_inverse = p.neutral.step_50,
                .text_disabled = p.neutral.step_300,
                .text_accent = p.brand.step_600,

                .action_default = p.brand.step_500,
                .action_hover = p.brand.step_600,
                .action_pressed = p.brand.step_700,
                .action_disabled = p.neutral.step_200,
                .action_subtle = p.brand.step_100,
                .action_text = p.neutral.step_50,

                .accent_default = p.accent.step_500,
                .accent_hover = p.accent.step_600,
                .accent_pressed = p.accent.step_700,
                .accent_subtle = p.accent.step_100,
                .accent_text = p.accent.step_700,

                .secondary_default = p.brand_secondary.step_500,
                .secondary_hover = p.brand_secondary.step_600,
                .secondary_pressed = p.brand_secondary.step_700,
                .secondary_subtle = p.brand_secondary.step_100,
                .secondary_text = p.brand_secondary.step_700,

                .status_success = p.success.step_500,
                .status_success_bg = p.success.step_100,
                .status_success_text = p.success.step_700,
                .status_warning = p.warning.step_500,
                .status_warning_bg = p.warning.step_100,
                .status_warning_text = p.warning.step_800,
                .status_info = p.info.step_500,
                .status_info_bg = p.info.step_100,
                .status_info_text = p.info.step_700,
                .status_danger = p.danger.step_500,
                .status_danger_bg = p.danger.step_100,
                .status_danger_text = p.danger.step_700,

                .border_subtle = p.neutral.step_200,
                .border_strong = p.neutral.step_400,
                .border_focus = p.brand.step_500,
            };
        }
    }
};

fn withAlpha(color: Color, alpha: f32) Color {
    return color.withAlpha(alpha);
}

pub const Theme = struct {
    palette: palette_lib.Palette,
    tokens: SemanticTokens,
    is_dark: bool,

    pub fn init(base_brand_oklch: [4]f32, is_dark: bool) Theme {
        const p = palette_lib.Palette.init(base_brand_oklch);
        return .{
            .palette = p,
            .tokens = SemanticTokens.init(&p, is_dark),
            .is_dark = is_dark,
        };
    }

    pub const Mode = enum { dark, light };

    pub fn fromOklch(brand: struct { l: f32, c: f32, h: f32, a: f32 = 1.0 }, mode: Mode) Theme {
        return Theme.init(.{ brand.l, brand.c, brand.h, brand.a }, mode == .dark);
    }

    pub fn initRandom(prng: std.Random, is_dark: bool) Theme {
        const p = palette_lib.Palette.initRandom(prng);
        return .{
            .palette = p,
            .tokens = SemanticTokens.init(&p, is_dark),
            .is_dark = is_dark,
        };
    }

    pub fn switchMode(self: *Theme) void {
        self.is_dark = !self.is_dark;
        self.tokens = SemanticTokens.init(&self.palette, self.is_dark);
    }
};
