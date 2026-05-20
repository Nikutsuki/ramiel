//! The swappable .so: three C-ABI symbols the host resolves after dlopen.
const lib = @import("ramiel");
const types = @import("app_types.zig");
const logic = @import("logic.zig");

const App = types.App;

export fn ramiel_app_register(app_opaque: *anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(app_opaque));
    app.build_fn = logic.build;
    app.update_fn = logic.update;
}

export fn ramiel_app_abi_hash() callconv(.c) u64 {
    return lib.hotreload.abiHash(App, types.AppState, types.AppMessage);
}

export fn ramiel_app_abi_version() callconv(.c) u32 {
    return lib.hotreload.abi_version;
}
