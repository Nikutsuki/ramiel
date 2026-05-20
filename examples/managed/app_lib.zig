//! The swappable .so for the ManagedApp demo. Managed.build/update are the dispatchers.
const lib = @import("ramiel");
const types = @import("app_types.zig");

const App = types.App;

export fn ramiel_app_register(app_opaque: *anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(app_opaque));
    app.build_fn = types.Managed.build;
    app.update_fn = types.Managed.update;
}

export fn ramiel_app_abi_hash() callconv(.c) u64 {
    return lib.hotreload.abiHash(App, types.State, types.Message);
}

export fn ramiel_app_abi_version() callconv(.c) u32 {
    return lib.hotreload.abi_version;
}
