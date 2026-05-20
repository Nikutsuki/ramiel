//! Shared types. Editing this file changes layout, flipping the reload to warm restart.
const lib = @import("ramiel");

pub const FontData = lib.FontData;

pub const AppMessage = enum(u8) {
    slider_drag,
};

pub const AppState = struct {
    font_data: *FontData = undefined,
    slider_value: f32 = 0.5,

    pub const snapshot_version: u32 = 1;
    pub const Snapshot = struct { slider_value: f32 = 0.5 };

    pub fn snapshot(self: *const AppState) Snapshot {
        return .{ .slider_value = self.slider_value };
    }

    pub fn restoreSnapshot(self: *AppState, data: *const Snapshot) !void {
        self.slider_value = data.slider_value;
    }
};

pub const App = lib.Application(AppState, AppMessage);
