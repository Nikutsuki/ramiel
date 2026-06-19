const std = @import("std");

pub const Color = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const transparent: Color = .{};

    pub fn rgbaU8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn from(c: [4]f32) Color {
        return .{ .r = chan(c[0]), .g = chan(c[1]), .b = chan(c[2]), .a = chan(c[3]) };
    }

    pub fn toArray(self: Color) [4]f32 {
        return .{ f(self.r), f(self.g), f(self.b), f(self.a) };
    }

    pub fn bits(self: Color) u32 {
        return @bitCast(self);
    }

    pub fn eql(a: Color, b: Color) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    pub fn withAlpha(self: Color, alpha: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = chan(alpha) };
    }

    pub fn scaleAlpha(self: Color, factor: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = chan(f(self.a) * factor) };
    }

    pub fn lerp(a: Color, b: Color, t: f32) Color {
        return .{
            .r = chan(f(a.r) + (f(b.r) - f(a.r)) * t),
            .g = chan(f(a.g) + (f(b.g) - f(a.g)) * t),
            .b = chan(f(a.b) + (f(b.b) - f(a.b)) * t),
            .a = chan(f(a.a) + (f(b.a) - f(a.a)) * t),
        };
    }

    fn chan(v: f32) u8 {
        return @intFromFloat(@max(0.0, @min(255.0, v * 255.0 + 0.5)));
    }

    fn f(c: u8) f32 {
        return @as(f32, @floatFromInt(c)) / 255.0;
    }
};

pub fn parse(comptime input_str: []const u8) Color {
    @setEvalBranchQuota(100000);

    const str = comptime std.mem.trim(u8, input_str, " \t\r\n");

    comptime if (std.mem.startsWith(u8, str, "#")) {
        return Color.from(parseHex(str));
    } else if (std.mem.startsWith(u8, str, "oklch")) {
        return Color.from(parseOklch(str));
    } else {
        @compileError("Unsupported color format. Expected hex or oklch, found: '" ++ str ++ "'");
    };
}

fn parseHex(comptime str: []const u8) [4]f32 {
    const hex_str = comptime if (str[0] == '#') str[1..] else str;

    if (hex_str.len == 3) {
        return .{
            hexCharToFloat(hex_str[0]),
            hexCharToFloat(hex_str[1]),
            hexCharToFloat(hex_str[2]),
            1.0,
        };
    } else if (hex_str.len == 4) {
        return .{
            hexCharToFloat(hex_str[0]),
            hexCharToFloat(hex_str[1]),
            hexCharToFloat(hex_str[2]),
            hexCharToFloat(hex_str[3]),
        };
    } else if (hex_str.len == 6) {
        return .{
            hexToFloat(hex_str[0..2]),
            hexToFloat(hex_str[2..4]),
            hexToFloat(hex_str[4..6]),
            1.0,
        };
    } else if (hex_str.len == 8) {
        return .{
            hexToFloat(hex_str[0..2]),
            hexToFloat(hex_str[2..4]),
            hexToFloat(hex_str[4..6]),
            hexToFloat(hex_str[6..8]),
        };
    } else {
        @compileError("Hex color must be 3, 4, 6, or 8 characters long. Found: '" ++ hex_str ++ "'");
    }
}

fn hexCharToFloat(comptime c: u8) f32 {
    const str: [2]u8 = comptime .{ c, c };
    return hexToFloat(&str);
}

fn hexToFloat(comptime hex: []const u8) f32 {
    const val = comptime std.fmt.parseInt(u8, hex, 16) catch @compileError("Invalid hex digit: " ++ hex);
    return @as(f32, @floatFromInt(val)) / 255.0;
}

fn parseOklch(comptime str: []const u8) [4]f32 {
    const open_idx = comptime std.mem.indexOf(u8, str, "(") orelse @compileError("oklch string missing '('");
    const close_idx = comptime std.mem.lastIndexOf(u8, str, ")") orelse @compileError("oklch string missing ')'");

    if (open_idx >= close_idx) {
        @compileError("Invalid oklch parentheses layout.");
    }

    const inner = comptime str[open_idx + 1 .. close_idx];
    var it = comptime std.mem.tokenizeAny(u8, inner, " /,\t\n\r");

    const l_str = comptime it.next() orelse @compileError("Missing L component in oklch string");
    const c_str = comptime it.next() orelse @compileError("Missing C component in oklch string");
    const h_str = comptime it.next() orelse @compileError("Missing H component in oklch string");
    const a_str = comptime it.next();

    const l = comptime if (std.mem.eql(u8, l_str, "none")) 0.0 else parseNumberOrPercent(l_str);
    const c = comptime if (std.mem.eql(u8, c_str, "none")) 0.0 else parseNumberOrPercent(c_str);
    const h = comptime if (std.mem.eql(u8, h_str, "none")) 0.0 else parseNumberOrPercent(h_str);
    const alpha = comptime if (a_str) |a| (if (std.mem.eql(u8, a, "none")) 1.0 else parseNumberOrPercent(a)) else 1.0;

    return oklchToRgb(l, c, h, alpha);
}

fn parseNumberOrPercent(comptime str: []const u8) f32 {
    if (std.mem.endsWith(u8, str, "%")) {
        const val_str = comptime str[0 .. str.len - 1];
        const val = comptime std.fmt.parseFloat(f32, val_str) catch @compileError("Invalid numeric format: " ++ val_str);
        return val / 100.0;
    } else {
        const val = comptime std.fmt.parseFloat(f32, str) catch @compileError("Invalid numeric format: " ++ str);
        return val;
    }
}

pub fn oklch(l: f32, c: f32, h: f32, alpha: f32) Color {
    return Color.from(oklchToRgb(l, c, h, alpha));
}

pub fn oklchToRgb(l: f32, c: f32, h: f32, alpha: f32) [4]f32 {
    const h_rad = h * std.math.pi / 180.0;

    const a = c * @cos(h_rad);
    const b = c * @sin(h_rad);

    const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = l - 0.0894841775 * a - 1.2914855480 * b;

    const l_cubed = l_ * l_ * l_;
    const m_cubed = m_ * m_ * m_;
    const s_cubed = s_ * s_ * s_;

    const r_lin = 4.0767416621 * l_cubed - 3.3077115913 * m_cubed + 0.2309699292 * s_cubed;
    const g_lin = -1.2684380046 * l_cubed + 2.6097574011 * m_cubed - 0.3413193965 * s_cubed;
    const b_lin = -0.0041960863 * l_cubed - 0.7034186147 * m_cubed + 1.7076147010 * s_cubed;

    return .{
        linearToSrgb(r_lin),
        linearToSrgb(g_lin),
        linearToSrgb(b_lin),
        alpha,
    };
}

fn linearToSrgb(val: f32) f32 {
    const clamped = std.math.clamp(val, 0.0, 1.0);
    if (clamped <= 0.0031308) {
        return 12.92 * clamped;
    } else {
        return 1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    }
}

pub fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
    const clamped_s = std.math.clamp(s, 0.0, 1.0);
    const clamped_v = std.math.clamp(v, 0.0, 1.0);
    const normalized_h = @mod(if (h < 0.0) h + 360.0 else h, 360.0);

    const c = clamped_v * clamped_s;
    const h_prime = normalized_h / 60.0;
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));

    var rgb_prime: [3]f32 = .{ 0.0, 0.0, 0.0 };
    if (h_prime < 1.0) {
        rgb_prime = .{ c, x, 0.0 };
    } else if (h_prime < 2.0) {
        rgb_prime = .{ x, c, 0.0 };
    } else if (h_prime < 3.0) {
        rgb_prime = .{ 0.0, c, x };
    } else if (h_prime < 4.0) {
        rgb_prime = .{ 0.0, x, c };
    } else if (h_prime < 5.0) {
        rgb_prime = .{ x, 0.0, c };
    } else {
        rgb_prime = .{ c, 0.0, x };
    }

    const m = clamped_v - c;
    return .{
        rgb_prime[0] + m,
        rgb_prime[1] + m,
        rgb_prime[2] + m,
    };
}

pub fn rgbToHsv(r: f32, g: f32, b: f32) [3]f32 {
    const clamped_r = std.math.clamp(r, 0.0, 1.0);
    const clamped_g = std.math.clamp(g, 0.0, 1.0);
    const clamped_b = std.math.clamp(b, 0.0, 1.0);

    const max_c = @max(clamped_r, @max(clamped_g, clamped_b));
    const min_c = @min(clamped_r, @min(clamped_g, clamped_b));
    const delta = max_c - min_c;

    var h: f32 = 0.0;
    if (delta > 0.0) {
        if (max_c == clamped_r) {
            h = 60.0 * @mod((clamped_g - clamped_b) / delta, 6.0);
        } else if (max_c == clamped_g) {
            h = 60.0 * (((clamped_b - clamped_r) / delta) + 2.0);
        } else {
            h = 60.0 * (((clamped_r - clamped_g) / delta) + 4.0);
        }
    }
    if (h < 0.0) h += 360.0;

    const s = if (max_c == 0.0) 0.0 else delta / max_c;
    const v = max_c;
    return .{ h, s, v };
}

pub fn rgbToHex(allocator: std.mem.Allocator, r: f32, g: f32, b: f32) ![]u8 {
    const r_byte: u8 = @intFromFloat(std.math.clamp(r * 255.0, 0.0, 255.0));
    const g_byte: u8 = @intFromFloat(std.math.clamp(g * 255.0, 0.0, 255.0));
    const b_byte: u8 = @intFromFloat(std.math.clamp(b * 255.0, 0.0, 255.0));
    return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ r_byte, g_byte, b_byte });
}
