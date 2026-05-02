const std = @import("std");
const NodeId = @import("../types.zig").NodeId;

pub fn deriveChildId(base_id: NodeId, local_key: []const u8) NodeId {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&base_id));
    hasher.update(local_key);
    return @truncate(hasher.final());
}
