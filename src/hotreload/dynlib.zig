//! Dynamic-loading wrapper for hot reload
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ LoadFailed, SymbolNotFound };

pub const Library = struct {
    handle: *anyopaque,

    // RTLD_NOW (eager resolution, so a broken .so fails here) | RTLD_LOCAL (default),
    // which lets two generations stay mapped during the ABI compare. Absolute path
    // skips the search list.
    pub fn open(path_z: [*:0]const u8) Error!Library {
        switch (builtin.os.tag) {
            .windows => @compileError("dynlib: Windows backend not yet implemented"),
            else => {
                const handle = std.c.dlopen(path_z, .{ .NOW = true }) orelse {
                    if (std.c.dlerror()) |msg| {
                        std.log.err("dlopen failed: {s}", .{std.mem.span(msg)});
                    }
                    return Error.LoadFailed;
                };
                return .{ .handle = handle };
            },
        }
    }

    pub fn lookup(self: Library, comptime T: type, name_z: [*:0]const u8) Error!T {
        const sym = std.c.dlsym(self.handle, name_z) orelse return Error.SymbolNotFound;
        return @ptrCast(@alignCast(sym));
    }

    pub fn close(self: Library) void {
        _ = std.c.dlclose(self.handle);
    }
};
