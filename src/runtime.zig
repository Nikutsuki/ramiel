const std = @import("std");
const builtin = @import("builtin");

pub const Runtime = struct {
    debug_allocator: if (builtin.mode == .Debug)
        std.heap.DebugAllocator(.{})
    else
        void = if (builtin.mode == .Debug) undefined else {},

    pub fn init() Runtime {
        var rt: Runtime = .{};
        if (builtin.mode == .Debug) rt.debug_allocator = .{};
        return rt;
    }

    pub fn allocator(self: *Runtime) std.mem.Allocator {
        if (builtin.mode == .Debug) return self.debug_allocator.allocator();
        return std.heap.smp_allocator;
    }

    pub fn deinit(self: *Runtime) void {
        if (builtin.mode == .Debug) {
            if (self.debug_allocator.deinit() == .leak) {
                std.debug.print("Memory leak detected.\n", .{});
            }
        }
    }
};
