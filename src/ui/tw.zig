const std = @import("std");
const layout = @import("layout.zig");
const Size = layout.Size;

pub const text_xs = .{ .font_size = 12.0 };
pub const text_sm = .{ .font_size = 14.0 };
pub const text_base = .{ .font_size = 16.0 };
pub const text_lg = .{ .font_size = 18.0 };
pub const text_xl = .{ .font_size = 20.0 };
pub const text_2xl = .{ .font_size = 24.0 };
pub const text_3xl = .{ .font_size = 30.0 };
pub const text_4xl = .{ .font_size = 36.0 };
pub const text_5xl = .{ .font_size = 48.0 };

pub const font_light = .{ .font_weight = 0.3 };
pub const font_normal = .{ .font_weight = 0.5 };
pub const font_semibold = .{ .font_weight = 0.6 };
pub const font_bold = .{ .font_weight = 0.7 };
pub const font_ultra_bold = .{ .font_weight = 0.9 };

pub const w_full = .{ .width = Size.Full };
pub const h_full = .{ .height = Size.Full };
pub const w_auto = .{ .width = Size.Auto };
pub const h_auto = .{ .height = Size.Auto };

pub const flex_row = .{ .display = .flex, .direction = .Row };
pub const flex_col = .{ .display = .flex, .direction = .Column };
pub const items_center = .{ .align_items = .Center };
pub const justify_center = .{ .justify_content = .Center };
pub const justify_between = .{ .justify_content = .SpaceBetween };
