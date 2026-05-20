const std = @import("std");
const build_options = @import("build_options");

pub const Action = enum {
    lock,
    suspend_,
    reboot,
    shutdown,
    logout,

    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .lock => "Lock",
            .suspend_ => "Suspend",
            .reboot => "Reboot",
            .shutdown => "Shut Down",
            .logout => "Log Out",
        };
    }

    /// Reboot/shutdown are destructive enough to warrant a confirm step.
    pub fn needsConfirm(self: Action) bool {
        return self == .reboot or self == .shutdown;
    }

    fn argv(self: Action) []const []const u8 {
        return switch (self) {
            .lock => &.{"hyprlock"},
            .suspend_ => &.{ "systemctl", "suspend" },
            .reboot => &.{ "systemctl", "reboot" },
            .shutdown => &.{ "systemctl", "poweroff" },
            .logout => &.{ "hyprctl", "dispatch", "exit" },
        };
    }

    fn cmdString(self: Action) []const u8 {
        return switch (self) {
            .lock => "hyprlock",
            .suspend_ => "systemctl suspend",
            .reboot => "systemctl reboot",
            .shutdown => "systemctl poweroff",
            .logout => "hyprctl dispatch exit",
        };
    }
};

/// Run a power action. With -Dpower-dry-run=true, the command is logged
/// instead of executed; otherwise it is spawned detached.
pub fn run(io: std.Io, action: Action) void {
    if (build_options.power_dry_run) {
        std.log.info("[power dry-run] {s}", .{action.cmdString()});
        return;
    }

    const child = std.process.spawn(io, .{
        .argv = action.argv(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.warn("power action {s} failed to spawn: {s}", .{ action.label(), @errorName(err) });
        return;
    };
    const waiter = std.Thread.spawn(.{}, waitChild, .{ io, child }) catch {
        var mutable = child;
        _ = mutable.wait(io) catch {};
        return;
    };
    waiter.detach();
}

fn waitChild(io: std.Io, child: std.process.Child) void {
    var mutable_child = child;
    _ = mutable_child.wait(io) catch {};
}
