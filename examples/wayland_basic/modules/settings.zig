const std = @import("std");

const dir_name = "ramiel-bar";

pub const Accent = enum {
    blue,
    purple,
    pink,
    red,
    orange,
    green,
    teal,

    pub fn oklch(self: Accent) struct { l: f32, c: f32, h: f32 } {
        return switch (self) {
            .blue => .{ .l = 0.62, .c = 0.13, .h = 250 },
            .purple => .{ .l = 0.62, .c = 0.14, .h = 300 },
            .pink => .{ .l = 0.66, .c = 0.15, .h = 350 },
            .red => .{ .l = 0.62, .c = 0.16, .h = 25 },
            .orange => .{ .l = 0.72, .c = 0.14, .h = 65 },
            .green => .{ .l = 0.70, .c = 0.14, .h = 150 },
            .teal => .{ .l = 0.70, .c = 0.10, .h = 195 },
        };
    }
};

pub const Rounding = enum {
    sharp,
    default,
    round,

    pub fn scale(self: Rounding) f32 {
        return switch (self) {
            .sharp => 0.0,
            .default => 1.0,
            .round => 1.8,
        };
    }

    pub fn label(self: Rounding) []const u8 {
        return switch (self) {
            .sharp => "Sharp",
            .default => "Default",
            .round => "Round",
        };
    }
};

pub const Settings = struct {
    clock_24h: bool = true,
    show_workspaces: bool = true,
    show_title: bool = true,
    show_battery: bool = true,
    show_volume: bool = true,
    show_tray: bool = true,
    dark_mode: bool = true,
    border_enabled: bool = true,
    accent: Accent = .blue,
    rounding: Rounding = .default,
};

/// Boolean toggles, in display order. Non-bool settings (accent, rounding) have
/// their own cycle controls.
pub const Key = enum {
    dark_mode,
    border_enabled,
    clock_24h,
    show_workspaces,
    show_title,
    show_battery,
    show_volume,
    show_tray,

    pub fn label(self: Key) []const u8 {
        return switch (self) {
            .dark_mode => "Dark mode",
            .border_enabled => "Pill border",
            .clock_24h => "24-hour clock",
            .show_workspaces => "Workspaces",
            .show_title => "Window title",
            .show_battery => "Battery",
            .show_volume => "Volume",
            .show_tray => "Tray icons",
        };
    }
};

pub const keys = [_]Key{ .dark_mode, .border_enabled, .clock_24h, .show_workspaces, .show_title, .show_battery, .show_volume, .show_tray };

pub fn get(s: Settings, k: Key) bool {
    return switch (k) {
        inline else => |kk| @field(s, @tagName(kk)),
    };
}

pub fn toggle(s: *Settings, k: Key) void {
    switch (k) {
        inline else => |kk| {
            @field(s.*, @tagName(kk)) = !@field(s.*, @tagName(kk));
        },
    }
}

pub fn cycleAccent(s: *Settings) void {
    const n = @typeInfo(Accent).@"enum".fields.len;
    s.accent = @enumFromInt((@intFromEnum(s.accent) + 1) % n);
}

pub fn cycleRounding(s: *Settings) void {
    const n = @typeInfo(Rounding).@"enum".fields.len;
    s.rounding = @enumFromInt((@intFromEnum(s.rounding) + 1) % n);
}

/// Config directory ($XDG_CONFIG_HOME/ramiel-bar or ~/.config/ramiel-bar).
pub fn configDir(env: *std.process.Environ.Map, buf: []u8) ?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |base| {
        if (base.len > 0) return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, dir_name }) catch null;
    }
    if (env.get("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/{s}", .{ home, dir_name }) catch null;
    }
    return null;
}
