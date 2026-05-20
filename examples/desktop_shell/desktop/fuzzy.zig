//! Small allocation-free fuzzy scoring for app runners.

const std = @import("std");

pub const no_match: i32 = -1;

pub fn score(query_raw: []const u8, candidate_raw: []const u8) i32 {
    const query = std.mem.trim(u8, query_raw, " \t\r\n");
    const candidate = std.mem.trim(u8, candidate_raw, " \t\r\n");
    if (query.len == 0) return 0;
    if (candidate.len == 0) return no_match;

    var qi: usize = 0;
    var last_match: ?usize = null;
    var total: i32 = 0;

    for (candidate, 0..) |c, ci| {
        if (qi >= query.len) break;
        if (asciiLower(c) != asciiLower(query[qi])) continue;

        total += 10;
        if (ci == 0) total += 8;
        if (ci > 0 and isBoundary(candidate[ci - 1])) total += 6;
        if (last_match) |prev| {
            if (ci == prev + 1) total += 5 else total -= @min(@as(i32, @intCast(ci - prev - 1)), 8);
        }
        last_match = ci;
        qi += 1;
    }

    if (qi != query.len) return no_match;
    total -= @min(@as(i32, @intCast(candidate.len - query.len)), 24);
    return total;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isBoundary(c: u8) bool {
    return c == ' ' or c == '-' or c == '_' or c == '.' or c == '/';
}

test "fuzzy score matches subsequences and prefers contiguous boundaries" {
    try std.testing.expect(score("ff", "Firefox") > no_match);
    try std.testing.expect(score("fox", "Firefox") > score("fox", "File Opener X"));
    try std.testing.expect(score("term", "Alacritty") == no_match);
    try std.testing.expect(score("al", "Alacritty") > score("al", "Calculator"));
}
