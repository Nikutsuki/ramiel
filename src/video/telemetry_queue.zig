const std = @import("std");

pub const TelemetryQueue = struct {
    buffer: [64]f64 = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn push(self: *TelemetryQueue, time_s: f64) bool {
        const current_head = self.head.load(.monotonic);
        const next_head = (current_head + 1) % self.buffer.len;

        if (next_head == self.tail.load(.acquire)) return false;

        self.buffer[current_head] = time_s;
        self.head.store(next_head, .release);
        return true;
    }

    pub fn pop(self: *TelemetryQueue) ?f64 {
        const current_tail = self.tail.load(.monotonic);
        if (current_tail == self.head.load(.acquire)) return null;

        const value = self.buffer[current_tail];
        self.tail.store((current_tail + 1) % self.buffer.len, .release);
        return value;
    }
};
