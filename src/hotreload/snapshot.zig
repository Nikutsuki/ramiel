//! State snapshot/restore for warm restart, over the ramiel.state envelope helpers.
const std = @import("std");
const state = @import("../state.zig");

pub fn snapshotJsonAlloc(comptime StateT: type, st: *const StateT, alloc: std.mem.Allocator) ![]u8 {
    const SnapshotT = state.snapshotTypeOf(StateT);
    const snap: SnapshotT = state.snapshotOf(st);
    return state.stringifyEnvelopeAlloc(SnapshotT, alloc, state.snapshotVersionOf(StateT), snap, .{});
}

pub fn restoreFromJson(comptime StateT: type, st: *StateT, alloc: std.mem.Allocator, bytes: []const u8) !void {
    const SnapshotT = state.snapshotTypeOf(StateT);
    var parsed = try state.parseEnvelope(SnapshotT, alloc, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try state.restoreSnapshotInto(st, &parsed.value.data);
}
