//! ABI fingerprint exported by the `.so` so the host can pick same-process swap vs warm restart.
const std = @import("std");

/// Bump when the `ramiel_app_register` C-ABI contract changes.
pub const abi_version: u32 = 1;

// Shallow by design: deep recursion through Application's self-referential UI-tree
// pointers would not terminate. App size/align catches its layout; one field level
// catches State/Msg field and union-variant changes.
pub fn abiHash(comptime App: type, comptime State: type, comptime Msg: type) u64 {
    return comptime hashValue(App, State, Msg);
}

fn hashValue(comptime App: type, comptime State: type, comptime Msg: type) u64 {
    @setEvalBranchQuota(100_000);
    var hasher = std.hash.Wyhash.init(0x5241_4d49_454c_0001);
    fingerprint(&hasher, App);
    fingerprint(&hasher, State);
    fingerprint(&hasher, Msg);
    return hasher.final();
}

fn fingerprint(hasher: *std.hash.Wyhash, comptime T: type) void {
    hasher.update(@typeName(T));
    updateInt(hasher, @sizeOf(T));
    updateInt(hasher, @alignOf(T));

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            for (info.fields) |f| {
                hasher.update(f.name);
                hasher.update(@typeName(f.type));
                updateInt(hasher, @sizeOf(f.type));
                updateInt(hasher, @alignOf(f.type));
                if (info.layout != .@"packed") updateInt(hasher, @offsetOf(T, f.name));
            }
        },
        .@"union" => |info| {
            if (info.tag_type) |tag| hasher.update(@typeName(tag));
            for (info.fields) |f| {
                hasher.update(f.name);
                hasher.update(@typeName(f.type));
                updateInt(hasher, @sizeOf(f.type));
            }
        },
        .@"enum" => |info| {
            hasher.update(@typeName(info.tag_type));
            for (info.fields) |f| {
                hasher.update(f.name);
                updateInt(hasher, f.value);
            }
        },
        else => {},
    }
}

fn updateInt(hasher: *std.hash.Wyhash, value: anytype) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @intCast(value), .little);
    hasher.update(&buf);
}
