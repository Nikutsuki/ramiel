const std = @import("std");

var enabled = std.atomic.Value(bool).init(true);

pub fn setEnabled(value: bool) void {
    enabled.store(value, .release);
}

pub fn isEnabled() bool {
    return enabled.load(.acquire);
}
