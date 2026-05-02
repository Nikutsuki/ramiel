const std = @import("std");

pub const IconId = u32;

pub const STATIC_MASK: u32 = 0x7FFFFFFF;
pub const DYNAMIC_FLAG: u32 = 0x80000000;

pub fn hashId(comptime namespace_str: []const u8) IconId {
    const raw_hash = std.hash.Fnv1a_32.hash(namespace_str);
    return raw_hash & STATIC_MASK;
}

pub fn makeDynamicId(sequence: u32) IconId {
    return sequence | DYNAMIC_FLAG;
}

pub fn isDynamic(id: IconId) bool {
    return (id & DYNAMIC_FLAG) != 0;
}
