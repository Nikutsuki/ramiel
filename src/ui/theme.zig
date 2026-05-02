const std = @import("std");
const palette_lib = @import("../assets/palette.zig");
const Color = palette_lib.Color;

pub const SemanticTokens = struct {
    bg_base: Color,
    bg_surface: Color,
    bg_elevated: Color,

    text_main: Color,
    text_muted: Color,
    text_inverse: Color,
    text_disabled: Color,

    action_default: Color,
    action_hover: Color,
    action_pressed: Color,
    action_disabled: Color,

    status_success: Color,
    status_warning: Color,
    status_danger: Color,

    border_subtle: Color,
    border_focus: Color,

    pub fn init(p: *const palette_lib.Palette, is_dark: bool) SemanticTokens {
        if (is_dark) {
            return .{
                .bg_base = p.neutral.step_900,
                .bg_surface = p.neutral.step_800,
                .bg_elevated = p.neutral.step_700,

                .text_main = p.neutral.step_50,
                .text_muted = p.neutral.step_400,
                .text_inverse = p.neutral.step_900,
                .text_disabled = p.neutral.step_600,

                .action_default = p.brand.step_500,
                .action_hover = p.brand.step_400,
                .action_pressed = p.brand.step_600,
                .action_disabled = p.neutral.step_700,

                .status_success = p.success.step_400,
                .status_warning = p.warning.step_400,
                .status_danger = p.danger.step_400,

                .border_subtle = p.neutral.step_700,
                .border_focus = p.brand.step_400,
            };
        } else {
            return .{
                .bg_base = p.neutral.step_50,
                .bg_surface = p.neutral.step_100,
                .bg_elevated = p.neutral.step_50,

                .text_main = p.neutral.step_900,
                .text_muted = p.neutral.step_500,
                .text_inverse = p.neutral.step_50,
                .text_disabled = p.neutral.step_300,

                .action_default = p.brand.step_500,
                .action_hover = p.brand.step_600,
                .action_pressed = p.brand.step_700,
                .action_disabled = p.neutral.step_200,

                .status_success = p.success.step_500,
                .status_warning = p.warning.step_500,
                .status_danger = p.danger.step_500,

                .border_subtle = p.neutral.step_200,
                .border_focus = p.brand.step_500,
            };
        }
    }
};

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
