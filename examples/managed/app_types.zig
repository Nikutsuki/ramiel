//! Shared spec/types for the ManagedApp hot-reload demo.
const lib = @import("ramiel");
const pages = @import("pages.zig");

pub const Spec = struct {
    pub const Route = enum { home, counter };
    pub const Pages = .{
        .home = pages.HomePage,
        .counter = pages.CounterPage,
    };
    pub const initial_route = Route.home;
    pub const GlobalState = pages.GlobalState;
    pub const RuntimeState = pages.RuntimeState;
};

pub const Managed = lib.ManagedApp(Spec);
pub const App = Managed.App;
pub const State = Managed.State;
pub const Message = Managed.Message;
