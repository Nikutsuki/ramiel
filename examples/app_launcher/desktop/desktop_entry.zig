//! Minimal `.desktop` entry parsing for app runners.
//!
//! This parser intentionally focuses on launcher metadata. It ignores localized
//! keys for now and only reads the `[Desktop Entry]` group.

const std = @import("std");

pub const Entry = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    generic_name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    categories: []const u8 = "",
    no_display: bool = false,
    hidden: bool = false,
    terminal: bool = false,

    pub fn shouldShow(self: Entry) bool {
        return self.name.len > 0 and self.exec.len > 0 and !self.no_display and !self.hidden;
    }
};

pub fn parse(id: []const u8, contents: []const u8) Entry {
    var entry = Entry{ .id = id };
    var in_desktop_entry = false;

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_desktop_entry) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "Name")) entry.name = value;
        if (std.mem.eql(u8, key, "GenericName")) entry.generic_name = value;
        if (std.mem.eql(u8, key, "Exec")) entry.exec = value;
        if (std.mem.eql(u8, key, "Icon")) entry.icon = value;
        if (std.mem.eql(u8, key, "Categories")) entry.categories = value;
        if (std.mem.eql(u8, key, "NoDisplay")) entry.no_display = parseBool(value);
        if (std.mem.eql(u8, key, "Hidden")) entry.hidden = parseBool(value);
        if (std.mem.eql(u8, key, "Terminal")) entry.terminal = parseBool(value);
    }

    return entry;
}

pub fn sanitizeExec(allocator: std.mem.Allocator, exec: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    var last_was_space = false;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(exec[i])) {
            if (!last_was_space and out.writer.end > 0) try out.writer.writeByte(' ');
            last_was_space = true;
            continue;
        }
        try out.writer.writeByte(exec[i]);
        last_was_space = false;
    }

    if (out.writer.end > 0 and out.writer.buffer[out.writer.end - 1] == ' ') {
        out.writer.end -= 1;
    }
    return out.toOwnedSlice();
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true");
}

test "parse desktop entry" {
    const text =
        \\[Desktop Entry]
        \\Name=Firefox
        \\GenericName=Web Browser
        \\Exec=firefox %u
        \\Icon=firefox
        \\Categories=Network;WebBrowser;
        \\NoDisplay=false
    ;
    const entry = parse("firefox.desktop", text);
    try std.testing.expectEqualStrings("Firefox", entry.name);
    try std.testing.expectEqualStrings("firefox %u", entry.exec);
    try std.testing.expect(entry.shouldShow());
}

test "sanitize exec removes field codes" {
    const allocator = std.testing.allocator;
    const out = try sanitizeExec(allocator, "firefox %u --new-window %U");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("firefox --new-window", out);
}
