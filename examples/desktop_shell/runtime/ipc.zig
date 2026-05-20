//! Local IPC helpers for resident app-runner activation.
//!
//! The intended compositor binding is:
//!
//! ```text
//! bind = SUPER, SPACE, exec, app_launcher --toggle
//! ```
//!
//! The tiny CLI process should call `sendActivation`, then exit. A resident
//! daemon owns the Ramiel window/renderer and calls `acceptActivation` from its
//! event integration to receive `activation.Request` values.

const std = @import("std");
const activation = @import("activation.zig");

pub const default_socket_name = "app-launcher.sock";
pub const max_request_bytes = 4096;

pub fn socketPath(allocator: std.mem.Allocator, runtime_dir: []const u8, app_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ runtime_dir, app_id, default_socket_name });
}

pub fn defaultSocketPath(allocator: std.mem.Allocator, app_id: []const u8) ![]u8 {
    return socketPath(allocator, "/tmp", app_id);
}

pub const Client = struct {
    path: []const u8,
    io: std.Io,

    pub fn sendActivation(self: Client, request: activation.Request) !void {
        var address = try std.Io.net.UnixAddress.init(self.path);
        var stream = try address.connect(self.io);
        defer stream.close(self.io);

        var buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &buffer);
        try activation.format(request, &writer.interface);
        try writer.interface.flush();
    }
};

pub const Server = struct {
    path: []const u8,
    io: std.Io,
    listener: std.Io.net.Server,

    pub fn listen(path: []const u8, io: std.Io) !Server {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        var address = try std.Io.net.UnixAddress.init(path);
        const listener = try address.listen(io, .{});
        return .{ .path = path, .io = io, .listener = listener };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
        std.Io.Dir.deleteFileAbsolute(self.io, self.path) catch {};
    }

    /// Accept one client, read a single newline-terminated activation request,
    /// parse it, then close the client stream.
    pub fn acceptActivation(self: *Server) !activation.Request {
        var stream = try self.listener.accept(self.io);
        defer stream.close(self.io);

        var read_buffer: [max_request_bytes]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EmptyActivationRequest;
        return activation.parse(line);
    }
};

test "socket path uses runtime dir and app id" {
    const allocator = std.testing.allocator;
    const path = try socketPath(allocator, "/run/user/1000", "test-app");
    defer allocator.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, "/test-app-app-launcher.sock"));
}
