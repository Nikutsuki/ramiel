const std = @import("std");
const UpdateAction = @import("ui/context.zig").UpdateAction;

pub const SnapshotVersion = u32;

pub fn actionRank(action: UpdateAction) u2 {
    return switch (action) {
        .none => 0,
        .repaint => 1,
        .relayout => 2,
        .rebuild => 3,
    };
}

pub fn combineAction(a: UpdateAction, b: UpdateAction) UpdateAction {
    return if (actionRank(b) > actionRank(a)) b else a;
}

pub const ActionAccumulator = struct {
    value: UpdateAction = .none,

    pub fn add(self: *ActionAccumulator, action: UpdateAction) void {
        self.value = combineAction(self.value, action);
    }

    pub fn addIf(self: *ActionAccumulator, condition: bool, action: UpdateAction) void {
        if (condition) self.add(action);
    }

    pub fn finish(self: ActionAccumulator) UpdateAction {
        return self.value;
    }
};

pub fn wrap(comptime ParentMessage: type, comptime tag: anytype, child: anytype) ParentMessage {
    return @unionInit(ParentMessage, @tagName(tag), child);
}

pub fn wrapTag(
    comptime ParentMessage: type,
    comptime ChildMessage: type,
    comptime tag: anytype,
) *const fn (ChildMessage, ?*const anyopaque) ParentMessage {
    return struct {
        fn handler(value: ChildMessage, _: ?*const anyopaque) ParentMessage {
            return wrap(ParentMessage, tag, value);
        }
    }.handler;
}

pub fn Envelope(comptime SnapshotT: type) type {
    return struct {
        version: SnapshotVersion,
        data: SnapshotT,
    };
}

pub fn envelope(comptime SnapshotT: type, version: SnapshotVersion, data: SnapshotT) Envelope(SnapshotT) {
    return .{ .version = version, .data = data };
}

pub fn stringifyAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
    options: std.json.Stringify.Options,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, options);
}

pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: std.json.ParseOptions,
) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, options);
}

pub fn stringifyEnvelopeAlloc(
    comptime SnapshotT: type,
    allocator: std.mem.Allocator,
    version: SnapshotVersion,
    data: SnapshotT,
    options: std.json.Stringify.Options,
) ![]u8 {
    return stringifyAlloc(allocator, envelope(SnapshotT, version, data), options);
}

pub fn parseEnvelope(
    comptime SnapshotT: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: std.json.ParseOptions,
) !std.json.Parsed(Envelope(SnapshotT)) {
    return parse(Envelope(SnapshotT), allocator, bytes, options);
}

pub fn expectEnvelopeVersion(comptime SnapshotT: type, parsed: *const std.json.Parsed(Envelope(SnapshotT)), expected: SnapshotVersion) !void {
    if (parsed.value.version != expected) return error.UnsupportedSnapshotVersion;
}

pub const ModuleContract = struct {
    /// Recommended per-feature shape:
    /// State owns serializable data plus transient UI fields for one module.
    /// Runtime owns non-serializable handles such as canvases, fonts, workers, sockets, and OS resources.
    /// Snapshot is the JSON-facing value. It should contain no pointers, handles, or allocator-owned containers.
    pub const naming = "State, Runtime, Snapshot, Msg, update, build, snapshot, restoreSnapshot";
};

test "UpdateAction accumulator keeps strongest invalidation" {
    var acc = ActionAccumulator{};
    acc.add(.repaint);
    acc.add(.none);
    acc.add(.relayout);
    acc.add(.repaint);
    try std.testing.expectEqual(UpdateAction.relayout, acc.finish());
}

test "wrap creates parent union messages" {
    const Child = union(enum) { selected: usize };
    const Parent = union(enum) { child: Child, close };

    const msg = wrap(Parent, .child, Child{ .selected = 2 });
    try std.testing.expectEqual(@as(usize, 2), msg.child.selected);
}

test "versioned snapshot json round trips" {
    const Snapshot = struct {
        selected: usize,
        name: []const u8,
    };

    const data = Snapshot{ .selected = 3, .name = "alpha" };
    const bytes = try stringifyEnvelopeAlloc(Snapshot, std.testing.allocator, 1, data, .{});
    defer std.testing.allocator.free(bytes);

    var parsed = try parseEnvelope(Snapshot, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try expectEnvelopeVersion(Snapshot, &parsed, 1);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.data.selected);
    try std.testing.expectEqualStrings("alpha", parsed.value.data.name);
}
