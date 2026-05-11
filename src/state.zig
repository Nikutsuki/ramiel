const std = @import("std");
const UpdateAction = @import("ui/context.zig").UpdateAction;

pub const SnapshotVersion = u32;

fn requireDecl(comptime T: type, comptime name: []const u8, comptime context: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(context ++ " must declare `" ++ name ++ "`");
    }
}

pub fn assertSerializableState(comptime StateT: type) void {
    requireDecl(StateT, "Snapshot", "SerializableState");
    requireDecl(StateT, "snapshot_version", "SerializableState");
    requireDecl(StateT, "snapshot", "SerializableState");
    requireDecl(StateT, "restoreSnapshot", "SerializableState");
}

/// Snapshot decls on State are optional. A State is serializable when it declares
/// `Snapshot`, `snapshot`, and `restoreSnapshot`. `snapshot_version` defaults to 1
/// when absent. Use this in libraries that want to opt-out gracefully when the user
/// has not declared the snapshot surface.
pub fn isSerializable(comptime StateT: type) bool {
    return @hasDecl(StateT, "Snapshot") and
        @hasDecl(StateT, "snapshot") and
        @hasDecl(StateT, "restoreSnapshot");
}

/// `T.Snapshot` if declared, else an empty struct. The empty fallback round-trips
/// through JSON cleanly and lets snapshot/restore call sites stay uniform.
pub fn snapshotTypeOf(comptime StateT: type) type {
    if (@hasDecl(StateT, "Snapshot")) return StateT.Snapshot;
    return struct {};
}

/// Version declared on State, or 1 by default.
pub fn snapshotVersionOf(comptime StateT: type) SnapshotVersion {
    if (@hasDecl(StateT, "snapshot_version")) return StateT.snapshot_version;
    return 1;
}

/// Calls `state.snapshot()` if declared, else returns an empty fallback.
pub fn snapshotOf(state: anytype) snapshotTypeOf(@typeInfo(@TypeOf(state)).pointer.child) {
    const StateT = @typeInfo(@TypeOf(state)).pointer.child;
    if (comptime isSerializable(StateT)) return state.snapshot();
    return .{};
}

/// Calls `state.restoreSnapshot(data)` if declared, else no-op.
pub fn restoreSnapshotInto(state: anytype, data: anytype) !void {
    const StateT = @typeInfo(@TypeOf(state)).pointer.child;
    if (comptime isSerializable(StateT)) {
        try state.restoreSnapshot(data);
    }
}

pub fn assertRuntimeState(comptime RuntimeT: type) void {
    requireDecl(RuntimeT, "serializable", "RuntimeState");
    if (RuntimeT.serializable != false) {
        @compileError("RuntimeState.serializable must be false");
    }
}

fn hasAnySerializableDecl(comptime StateT: type) bool {
    return @hasDecl(StateT, "Snapshot") or
        @hasDecl(StateT, "snapshot_version") or
        @hasDecl(StateT, "snapshot") or
        @hasDecl(StateT, "restoreSnapshot");
}

pub fn assertState(comptime StateT: type) void {
    if (comptime hasAnySerializableDecl(StateT)) {
        assertSerializableState(StateT);
    }
    if (comptime @hasDecl(StateT, "RuntimeState")) {
        assertRuntimeState(StateT.RuntimeState);
    }
}

pub fn assertPage(comptime PageT: type) void {
    requireDecl(PageT, "State", "Page");
    requireDecl(PageT, "Msg", "Page");
    requireDecl(PageT, "build", "Page");
    requireDecl(PageT, "update", "Page");
    assertState(PageT.State);
}

pub fn Runtime(comptime T: type) type {
    return struct {
        value: T,

        pub const serializable = false;

        pub fn init(value: T) @This() {
            return .{ .value = value };
        }

        pub fn get(self: *@This()) *T {
            return &self.value;
        }

        pub fn getConst(self: *const @This()) *const T {
            return &self.value;
        }
    };
}

pub const RuntimeState = struct {
    pub const serializable = false;
};

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

pub fn onTag(
    comptime MessageT: type,
    comptime tag: anytype,
    comptime ValueT: type,
) *const fn (ValueT, ?*const anyopaque) MessageT {
    return struct {
        fn handler(value: ValueT, _: ?*const anyopaque) MessageT {
            return @unionInit(MessageT, @tagName(tag), value);
        }
    }.handler;
}

pub fn staticTag(
    comptime MessageT: type,
    comptime tag: anytype,
    comptime ValueT: type,
    value: ValueT,
) MessageT {
    return @unionInit(MessageT, @tagName(tag), value);
}

pub fn Adapter(comptime ParentMessage: type, comptime parent_tag: anytype) type {
    return struct {
        pub fn wrapChild(child: anytype) ParentMessage {
            return wrap(ParentMessage, parent_tag, child);
        }

        pub fn wrapFn(comptime ChildMessage: type) *const fn (ChildMessage, ?*const anyopaque) ParentMessage {
            return wrapTag(ParentMessage, ChildMessage, parent_tag);
        }

        pub fn on(
            comptime ChildMessage: type,
            comptime child_tag: anytype,
            comptime ValueT: type,
        ) *const fn (ValueT, ?*const anyopaque) ParentMessage {
            return struct {
                fn handler(value: ValueT, _: ?*const anyopaque) ParentMessage {
                    const child = @unionInit(ChildMessage, @tagName(child_tag), value);
                    return wrap(ParentMessage, parent_tag, child);
                }
            }.handler;
        }

        pub fn constant(comptime child: anytype) ParentMessage {
            return wrap(ParentMessage, parent_tag, child);
        }
    };
}

pub fn adapter(comptime ParentMessage: type, comptime parent_tag: anytype) Adapter(ParentMessage, parent_tag) {
    return .{};
}

pub fn route(child_state: anytype, child_msg: anytype, comptime update_fn: anytype) UpdateAction {
    return update_fn(child_state, child_msg);
}

pub fn routeField(parent_state: anytype, comptime field_name: []const u8, child_msg: anytype, comptime update_fn: anytype) UpdateAction {
    return update_fn(&@field(parent_state, field_name), child_msg);
}

pub fn Page(comptime PageT: type) type {
    assertPage(PageT);
    return struct {
        pub const State = PageT.State;
        pub const Msg = PageT.Msg;
        pub const build = PageT.build;
        pub const update = PageT.update;
    };
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

test "isSerializable handles present and absent decls" {
    const Full = struct {
        pub const snapshot_version: SnapshotVersion = 1;
        pub const Snapshot = struct {};
        pub fn snapshot(_: *const @This()) Snapshot {
            return .{};
        }
        pub fn restoreSnapshot(_: *@This(), _: *const Snapshot) !void {}
    };
    const Bare = struct {};

    try std.testing.expect(isSerializable(Full));
    try std.testing.expect(!isSerializable(Bare));
    try std.testing.expectEqual(@as(SnapshotVersion, 1), snapshotVersionOf(Full));
    try std.testing.expectEqual(@as(SnapshotVersion, 1), snapshotVersionOf(Bare));

    var bare: Bare = .{};
    const bare_snap = snapshotOf(&bare);
    _ = bare_snap;
    try restoreSnapshotInto(&bare, &.{});

    var full: Full = .{};
    const full_snap = snapshotOf(&full);
    try restoreSnapshotInto(&full, &full_snap);
}

test "state contracts validate conventional modules" {
    const ChildPage = struct {
        pub const Msg = union(enum) { set: u32 };
        pub const State = struct {
            pub const snapshot_version: SnapshotVersion = 1;
            pub const Snapshot = struct { value: u32 = 0 };

            value: u32 = 0,

            pub fn snapshot(self: *const @This()) Snapshot {
                return .{ .value = self.value };
            }

            pub fn restoreSnapshot(self: *@This(), data: *const Snapshot) !void {
                self.value = data.value;
            }
        };

        pub fn build(_: *anyopaque, _: *const State) anyerror!*anyopaque {
            return error.NotImplemented;
        }

        pub fn update(state: *State, msg: Msg) UpdateAction {
            switch (msg) {
                .set => |value| state.value = value,
            }
            return .rebuild;
        }
    };

    comptime {
        assertSerializableState(ChildPage.State);
        assertPage(ChildPage);
    }
}

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
