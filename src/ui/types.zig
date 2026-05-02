const std = @import("std");
const Node = @import("node.zig").Node;

pub const NodeId = u32;

pub const EventLayoutSnapshot = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const EventData = union(enum) {
    none,
    scroll: struct { dx: f32, dy: f32, mods: i32 = 0 },
    drag: struct { x: f32, y: f32, dx: f32, dy: f32, mods: i32 = 0 },
    key: struct { key: i32, action: i32, mods: i32 },
    text: struct { codepoint: u21 },
    mouse: struct { x: f32, y: f32, mods: i32 = 0, cursor_index: usize = 0 },
};

pub fn InteractionMessage(comptime T: type) type {
    return struct {
        id: T,
        source: ?*Node(T) = null,
        data: EventData = .none,
    };
}

pub const EventType = enum(u8) {
    click,
    pointer_down,
    pointer_up,
    drag,
    hover_enter,
    hover_exit,
    key_down,
    key_up,
    text_input,
    scroll,
    pointer_move,
};

pub fn EventBinding(comptime MessageT: type) type {
    return struct {
        event: EventType,
        msg: ?MessageT = null,
        userdata: ?*const anyopaque = null,
        destroy_userdata: ?*const fn (userdata: ?*const anyopaque, allocator: std.mem.Allocator) void = null,
        handler: ?*const fn (
            userdata: ?*const anyopaque,
            layout_res: EventLayoutSnapshot,
            data: EventData,
        ) ?MessageT = null,
    };
}
