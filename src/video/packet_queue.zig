const std = @import("std");
const c = @import("c.zig").c;

pub const PacketQueue = struct {
    packets: []c.AVPacket,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !PacketQueue {
        const packets = try allocator.alloc(c.AVPacket, capacity);
        for (packets) |*pkt| {
            c.av_init_packet(pkt);
            pkt.data = null;
            pkt.size = 0;
        }
        return .{
            .packets = packets,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *PacketQueue, allocator: std.mem.Allocator) void {
        self.flush();
        allocator.free(self.packets);
    }

    pub fn push(self: *PacketQueue, src_pkt: *c.AVPacket) bool {
        const current_tail = self.tail.load(.acquire);
        const current_head = self.head.load(.monotonic);
        const next_head = (current_head + 1) % self.capacity;

        if (next_head == current_tail) return false; // Queue is full

        c.av_packet_move_ref(&self.packets[current_head], src_pkt);
        self.head.store(next_head, .release);
        return true;
    }

    pub fn pop(self: *PacketQueue, dst_pkt: *c.AVPacket) bool {
        const current_head = self.head.load(.acquire);
        const current_tail = self.tail.load(.monotonic);

        if (current_tail == current_head) return false; // Queue is empty

        c.av_packet_move_ref(dst_pkt, &self.packets[current_tail]);
        self.tail.store((current_tail + 1) % self.capacity, .release);
        return true;
    }

    pub fn flush(self: *PacketQueue) void {
        var current_tail = self.tail.load(.acquire);
        const current_head = self.head.load(.acquire);

        while (current_tail != current_head) : (current_tail = (current_tail + 1) % self.capacity) {
            c.av_packet_unref(&self.packets[current_tail]);
        }

        self.head.store(0, .release);
        self.tail.store(0, .release);
    }
};
