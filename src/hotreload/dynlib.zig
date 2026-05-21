//! Dynamic-loading wrapper for hot reload
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Error = error{ LoadFailed, SymbolNotFound };

extern "kernel32" fn LoadLibraryA(lpLibFileName: windows.LPCSTR) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: windows.LPCSTR) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

pub const Library = struct {
    handle: *anyopaque,

    // RTLD_NOW (eager resolution, so a broken .so fails here) | RTLD_LOCAL (default),
    // which lets two generations stay mapped during the ABI compare. Absolute path
    // skips the search list.
    pub fn open(path_z: [*:0]const u8) Error!Library {
        switch (builtin.os.tag) {
            .windows => {
                const handle = LoadLibraryA(path_z) orelse {
                    std.log.err("LoadLibraryA failed for {s}: {t}", .{ std.mem.span(path_z), windows.GetLastError() });
                    return Error.LoadFailed;
                };
                return .{ .handle = @ptrCast(handle) };
            },
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
        switch (builtin.os.tag) {
            .windows => {
                const module: windows.HMODULE = @ptrCast(self.handle);
                const sym = GetProcAddress(module, name_z) orelse return Error.SymbolNotFound;
                return @as(T, @ptrCast(@alignCast(sym)));
            },
            else => {
                const sym = std.c.dlsym(self.handle, name_z) orelse return Error.SymbolNotFound;
                return @as(T, @ptrCast(@alignCast(sym)));
            },
        }
    }

    pub fn close(self: Library) void {
        switch (builtin.os.tag) {
            .windows => {
                const module: windows.HMODULE = @ptrCast(self.handle);
                if (FreeLibrary(module) == .FALSE) {
                    std.log.warn("FreeLibrary failed: {t}", .{windows.GetLastError()});
                }
            },
            else => _ = std.c.dlclose(self.handle),
        }
    }
};
