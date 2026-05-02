const std = @import("std");

pub const FrameState = enum { free, decoding, ready };

pub const FrameSlot = struct {
    yuv_buffer: []u8,
    pts_us: i64 = 0,
    state: FrameState = .free,
};

pub const FrameQueue = struct {
    slots: []FrameSlot,
    read_idx: usize = 0,
    write_idx: usize = 0,

    mutex: std.Io.Mutex = .init,
    cond_free: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, slot_count: usize, buffer_size: usize) !FrameQueue {
        var slots = try allocator.alloc(FrameSlot, slot_count);
        errdefer allocator.free(slots);

        var initialized: usize = 0;
        errdefer {
            for (slots[0..initialized]) |*slot| {
                allocator.free(slot.yuv_buffer);
            }
        }

        for (slots) |*slot| {
            slot.* = .{
                .yuv_buffer = try allocator.alloc(u8, buffer_size),
                .pts_us = 0,
                .state = .free,
            };
            initialized += 1;
        }

        return .{ .slots = slots };
    }

    pub fn deinit(self: *FrameQueue, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| {
            allocator.free(slot.yuv_buffer);
        }
        allocator.free(self.slots);
        self.slots = &[_]FrameSlot{};
    }

    pub fn wakeAll(self: *FrameQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cond_free.broadcast(io);
    }

    pub fn clear(self: *FrameQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.slots) |*slot| {
            slot.state = .free;
            slot.pts_us = 0;
        }
        self.read_idx = 0;
        self.write_idx = 0;
        self.cond_free.broadcast(io);
    }

    pub fn acquireWriteSlot(self: *FrameQueue, io: std.Io, quit_flag: *const bool) ?*FrameSlot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.slots[self.write_idx].state != .free) {
            if (quit_flag.*) return null;
            self.cond_free.wait(io, &self.mutex) catch return null;
        }

        const slot = &self.slots[self.write_idx];
        slot.state = .decoding;
        return slot;
    }

    pub fn commitWriteSlot(self: *FrameQueue, io: std.Io, pts_us: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.slots[self.write_idx].pts_us = pts_us;
        self.slots[self.write_idx].state = .ready;
        self.write_idx = (self.write_idx + 1) % self.slots.len;
    }

    pub fn peekReadSlot(self: *FrameQueue, io: std.Io) ?*FrameSlot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const slot = &self.slots[self.read_idx];
        if (slot.state == .ready) return slot;
        return null;
    }

    pub fn releaseReadSlot(self: *FrameQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.slots[self.read_idx].state = .free;
        self.read_idx = (self.read_idx + 1) % self.slots.len;
        self.cond_free.signal(io);
    }

    pub fn getReadableCount(self: *FrameQueue, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var count: usize = 0;
        for (self.slots) |*slot| {
            if (slot.state == .ready) {
                count += 1;
            }
        }
        return count;
    }
};
