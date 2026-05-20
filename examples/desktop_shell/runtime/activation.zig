//! Activation command protocol shared by resident app-runner daemons and tiny
//! compositor-bound CLI clients.
//!
//! This file intentionally contains only parsing/formatting. Transport (Unix
//! socket on Linux, named pipe on Windows) can be added separately without
//! changing the command vocabulary used by app runners.

const std = @import("std");

pub const Request = union(enum) {
    show,
    hide,
    toggle,
    focus_search,
    custom: []const u8,
};

pub const ParseError = error{
    EmptyActivationRequest,
    UnknownActivationRequest,
};

pub fn parse(bytes: []const u8) ParseError!Request {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyActivationRequest;

    if (std.mem.eql(u8, trimmed, "show")) return .show;
    if (std.mem.eql(u8, trimmed, "hide")) return .hide;
    if (std.mem.eql(u8, trimmed, "toggle")) return .toggle;
    if (std.mem.eql(u8, trimmed, "focus-search")) return .focus_search;

    const custom_prefix = "custom ";
    if (std.mem.startsWith(u8, trimmed, custom_prefix)) {
        const payload = std.mem.trim(u8, trimmed[custom_prefix.len..], " \t\r\n");
        if (payload.len == 0) return error.UnknownActivationRequest;
        return .{ .custom = payload };
    }

    return error.UnknownActivationRequest;
}

pub fn format(request: Request, writer: anytype) !void {
    switch (request) {
        .show => try writer.writeAll("show\n"),
        .hide => try writer.writeAll("hide\n"),
        .toggle => try writer.writeAll("toggle\n"),
        .focus_search => try writer.writeAll("focus-search\n"),
        .custom => |payload| {
            try writer.writeAll("custom ");
            try writer.writeAll(payload);
            try writer.writeAll("\n");
        },
    }
}

pub fn formatAlloc(allocator: std.mem.Allocator, request: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try format(request, &out.writer);
    return out.toOwnedSlice();
}

test "parse activation commands" {
    try std.testing.expectEqual(Request.show, try parse("show\n"));
    try std.testing.expectEqual(Request.hide, try parse(" hide "));
    try std.testing.expectEqual(Request.toggle, try parse("toggle"));
    try std.testing.expectEqual(Request.focus_search, try parse("focus-search"));

    const custom = try parse("custom query firefox");
    try std.testing.expectEqualStrings("query firefox", custom.custom);

    try std.testing.expectError(error.EmptyActivationRequest, parse(" \n\t"));
    try std.testing.expectError(error.UnknownActivationRequest, parse("launch"));
}

test "format activation commands" {
    const allocator = std.testing.allocator;

    const toggle = try formatAlloc(allocator, .toggle);
    defer allocator.free(toggle);
    try std.testing.expectEqualStrings("toggle\n", toggle);

    const custom = try formatAlloc(allocator, .{ .custom = "query firefox" });
    defer allocator.free(custom);
    try std.testing.expectEqualStrings("custom query firefox\n", custom);
}
