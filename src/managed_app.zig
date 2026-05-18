const std = @import("std");
const app_mod = @import("app.zig");
const state_mod = @import("state.zig");
const UpdateAction = @import("ui/context.zig").UpdateAction;
const UIContext = @import("ui/context.zig").UIContext;
const Node = @import("ui/node.zig").Node;
const types = @import("ui/types.zig");
const uix = @import("ui/uix.zig");
const components = @import("ui/components/root.zig");
const runtime_mod = @import("runtime.zig");
const FontSource = @import("renderer/font/font_registry.zig").FontSource;
const AppBackendConfig = @import("platform/backend.zig").AppBackendConfig;

pub const FontSpec = struct {
    name: []const u8 = "JetBrains Mono",
    source: FontSource,
    base_resolution: u32 = 32,
};

pub fn RunContext(comptime AppT: type) type {
    return struct {
        app: *AppT,
        allocator: std.mem.Allocator,
        io: std.Io,
    };
}

fn hasField(comptime T: type, comptime name: []const u8) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and @hasField(T, name);
}

fn assertFalseSerializable(comptime T: type, comptime context: []const u8) void {
    if (!@hasDecl(T, "serializable")) {
        @compileError(context ++ " must declare `pub const serializable = false`");
    }
    if (@field(T, "serializable") != false) {
        @compileError(context ++ ".serializable must be false");
    }
}

fn initValue(comptime T: type, allocator: std.mem.Allocator) !T {
    if (comptime @hasDecl(T, "init")) return try T.init(allocator);
    if (comptime hasField(T, "allocator")) return T{ .allocator = allocator };
    return .{};
}

fn deinitValue(value: anytype) void {
    const PtrT = @TypeOf(value);
    const info = @typeInfo(PtrT);
    if (info != .pointer) @compileError("deinitValue expects a pointer");
    const T = info.pointer.child;
    if (@hasDecl(T, "deinit")) value.deinit();
}

fn windowConfig(comptime RunSpec: type) AppBackendConfig {
    return if (@hasDecl(RunSpec, "window")) RunSpec.window else .{ .title = "Ramiel" };
}

fn applyRunSpecBeforeSetup(comptime RunSpec: type, app: anytype) !void {
    if (@hasDecl(RunSpec, "default_font")) {
        const spec = RunSpec.default_font;
        _ = try app.loadDefaultFont(spec.name, spec.source, spec.base_resolution);
    }
    if (@hasDecl(RunSpec, "AssetEnum") != @hasDecl(RunSpec, "asset_manifest")) {
        @compileError("RunSpec must declare both AssetEnum and asset_manifest, or neither");
    }
    if (@hasDecl(RunSpec, "AssetEnum")) {
        try app.loadStaticAssets(RunSpec.AssetEnum, RunSpec.asset_manifest);
    }
    if (@hasDecl(RunSpec, "tick")) {
        app.tick_fn = RunSpec.tick;
    }
    if (@hasDecl(RunSpec, "tick_interval_s")) {
        app.tick_interval_s = RunSpec.tick_interval_s;
    }
}

fn callSetup(comptime RunSpec: type, ctx: anytype) !void {
    if (@hasDecl(RunSpec, "setup")) {
        try RunSpec.setup(ctx);
    }
}

fn callShutdown(comptime RunSpec: type, ctx: anytype) void {
    if (@hasDecl(RunSpec, "shutdown")) {
        RunSpec.shutdown(ctx);
    }
}

pub fn ManagedApp(comptime Spec: type) type {
    if (!@hasDecl(Spec, "Route")) @compileError("ManagedApp spec must declare Route");
    if (!@hasDecl(Spec, "Pages")) @compileError("ManagedApp spec must declare Pages");

    const Route = Spec.Route;
    const route_info = @typeInfo(Route);
    if (route_info != .@"enum") @compileError("ManagedApp.Route must be an enum");
    const route_fields = route_info.@"enum".fields;
    const page_count = route_fields.len;

    const GlobalState = if (@hasDecl(Spec, "GlobalState")) Spec.GlobalState else struct {
        pub const snapshot_version: state_mod.SnapshotVersion = 1;
        pub const Snapshot = struct {};
        pub fn snapshot(_: *const @This()) Snapshot {
            return .{};
        }
        pub fn restoreSnapshot(_: *@This(), _: *const Snapshot) !void {}
    };
    const RuntimeState = if (@hasDecl(Spec, "RuntimeState")) Spec.RuntimeState else state_mod.RuntimeState;
    const initial_route: Route = if (@hasDecl(Spec, "initial_route")) Spec.initial_route else @field(Route, route_fields[0].name);
    const flat_single_page_message = @hasDecl(Spec, "flat_single_page_message") and Spec.flat_single_page_message;

    comptime {
        if (flat_single_page_message and page_count != 1) {
            @compileError("ManagedApp.flat_single_page_message is only valid for one-route apps");
        }
        state_mod.assertState(GlobalState);
        assertFalseSerializable(RuntimeState, "ManagedApp.RuntimeState");
    }

    comptime var page_field_names: [page_count][]const u8 = undefined;
    comptime var page_state_types: [page_count]type = undefined;
    comptime var page_snapshot_types: [page_count]type = undefined;
    comptime var page_msg_types: [page_count]type = undefined;
    comptime var page_field_attrs: [page_count]std.builtin.Type.StructField.Attributes = undefined;
    comptime var page_snapshot_attrs: [page_count]std.builtin.Type.StructField.Attributes = undefined;
    comptime var msg_field_names: [page_count + 1][]const u8 = undefined;
    comptime var msg_field_types: [page_count + 1]type = undefined;
    comptime var msg_field_attrs: [page_count + 1]std.builtin.Type.UnionField.Attributes = undefined;

    comptime {
        msg_field_names[0] = "goto";
        msg_field_types[0] = Route;
        msg_field_attrs[0] = .{};

        for (route_fields, 0..) |route_field, i| {
            const name = route_field.name;
            if (!@hasField(@TypeOf(Spec.Pages), name)) {
                @compileError("ManagedApp.Pages is missing route field `" ++ name ++ "`");
            }
            const Page = @field(Spec.Pages, name);
            state_mod.assertPage(Page);

            page_field_names[i] = name;
            page_state_types[i] = Page.State;
            page_snapshot_types[i] = state_mod.snapshotTypeOf(Page.State);
            page_msg_types[i] = Page.Msg;
            page_field_attrs[i] = .{};
            page_snapshot_attrs[i] = .{};

            msg_field_names[i + 1] = name;
            msg_field_types[i + 1] = Page.Msg;
            msg_field_attrs[i + 1] = .{};
        }
    }

    const PagesState = @Struct(.auto, null, &page_field_names, &page_state_types, &page_field_attrs);
    const PagesSnapshot = @Struct(.auto, null, &page_field_names, &page_snapshot_types, &page_snapshot_attrs);
    const MsgTagInt = std.math.IntFittingRange(0, msg_field_names.len - 1);
    const MsgTag = @Enum(MsgTagInt, .exhaustive, &msg_field_names, &std.simd.iota(MsgTagInt, msg_field_names.len));
    const NestedMsg = @Union(.auto, MsgTag, &msg_field_names, &msg_field_types, &msg_field_attrs);
    const Msg = if (flat_single_page_message) page_msg_types[0] else NestedMsg;

    return struct {
        const Self = @This();

        pub const AppSpec = Spec;
        pub const RouteT = Route;
        pub const Global = GlobalState;
        pub const Runtime = RuntimeState;
        pub const Pages = Spec.Pages;
        pub const Message = Msg;
        pub const App = app_mod.Application(State, Msg);

        pub const Snapshot = struct {
            route: Route = initial_route,
            global: state_mod.snapshotTypeOf(GlobalState) = .{},
            pages: PagesSnapshot,
        };

        pub const State = struct {
            allocator: std.mem.Allocator,
            route: Route = initial_route,
            global: GlobalState,
            runtime: RuntimeState,
            pages: PagesState,

            pub const snapshot_version: state_mod.SnapshotVersion = 1;
            pub const Snapshot = Self.Snapshot;

            pub fn snapshot(self: *const @This()) Self.Snapshot {
                var pages_snapshot: PagesSnapshot = undefined;
                inline for (route_fields) |route_field| {
                    const name = route_field.name;
                    @field(pages_snapshot, name) = state_mod.snapshotOf(&@field(self.pages, name));
                }
                return .{
                    .route = self.route,
                    .global = state_mod.snapshotOf(&self.global),
                    .pages = pages_snapshot,
                };
            }

            pub fn restoreSnapshot(self: *@This(), data: *const Self.Snapshot) !void {
                self.route = data.route;
                try state_mod.restoreSnapshotInto(&self.global, &data.global);
                inline for (route_fields) |route_field| {
                    const name = route_field.name;
                    try state_mod.restoreSnapshotInto(&@field(self.pages, name), &@field(data.pages, name));
                }
            }

            pub fn snapshotJsonAlloc(self: *const @This(), allocator: std.mem.Allocator) ![]u8 {
                return state_mod.stringifyEnvelopeAlloc(Self.Snapshot, allocator, snapshot_version, self.snapshot(), .{});
            }

            pub fn restoreSnapshotJson(self: *@This(), bytes: []const u8) !void {
                var parsed = try state_mod.parseEnvelope(Self.Snapshot, self.allocator, bytes, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                try state_mod.expectEnvelopeVersion(Self.Snapshot, &parsed, snapshot_version);
                try self.restoreSnapshot(&parsed.value.data);
            }

            pub fn deinit(self: *@This()) void {
                inline for (route_fields) |route_field| {
                    deinitValue(&@field(self.pages, route_field.name));
                }
                deinitValue(&self.global);
                deinitValue(&self.runtime);
            }
        };

        pub fn BuildContext(comptime route_tag: Route) type {
            return struct {
                ui: *UIContext(Msg),
                app_state: *const State,
                global: *const GlobalState,
                runtime: *const RuntimeState,
                ux: if (flat_single_page_message)
                    uix.Builder(Msg)
                else
                    uix.ScopedBuilder(Msg, @field(Spec.Pages, @tagName(route_tag)).Msg, route_tag),
                components: components.Builder(Msg),

                pub const Message = Msg;
                pub const LocalMessage = @field(Spec.Pages, @tagName(route_tag)).Msg;

                pub fn init(ui: *UIContext(Msg), app_state: *const State) @This() {
                    return .{
                        .ui = ui,
                        .app_state = app_state,
                        .global = &app_state.global,
                        .runtime = &app_state.runtime,
                        .ux = if (flat_single_page_message)
                            uix.builder(Msg, ui)
                        else
                            uix.scopedBuilder(Msg, @field(Spec.Pages, @tagName(route_tag)).Msg, route_tag, ui),
                        .components = components.Builder(Msg){ .ui = ui },
                    };
                }

                pub fn msg(_: @This(), page_msg: @field(Spec.Pages, @tagName(route_tag)).Msg) Msg {
                    return if (flat_single_page_message) page_msg else @unionInit(Msg, @tagName(route_tag), page_msg);
                }

                pub fn goto(_: @This(), route: Route) Msg {
                    if (flat_single_page_message) @compileError("goto is unavailable when flat_single_page_message is enabled");
                    return .{ .goto = route };
                }

                pub fn on(
                    _: @This(),
                    comptime tag: anytype,
                    comptime ValueT: type,
                ) *const fn (ValueT, ?*const anyopaque) Msg {
                    const Page = @field(Spec.Pages, @tagName(route_tag));
                    return state_mod.Adapter(Msg, route_tag).on(Page.Msg, tag, ValueT);
                }
            };
        }

        pub fn UpdateContext(comptime route_tag: Route) type {
            return struct {
                app: *App,
                app_state: *State,
                global: *GlobalState,
                runtime: *RuntimeState,
                event_data: types.EventData,

                pub fn init(app: *App, event_data: types.EventData) @This() {
                    return .{
                        .app = app,
                        .app_state = &app.state,
                        .global = &app.state.global,
                        .runtime = &app.state.runtime,
                        .event_data = event_data,
                    };
                }

                pub fn msg(_: @This(), page_msg: @field(Spec.Pages, @tagName(route_tag)).Msg) Msg {
                    return if (flat_single_page_message) page_msg else @unionInit(Msg, @tagName(route_tag), page_msg);
                }

                pub fn post(self: @This(), page_msg: @field(Spec.Pages, @tagName(route_tag)).Msg) void {
                    self.app.postMessageId(if (flat_single_page_message) page_msg else @unionInit(Msg, @tagName(route_tag), page_msg));
                }

                pub fn goto(_: @This(), route: Route) Msg {
                    if (flat_single_page_message) @compileError("goto is unavailable when flat_single_page_message is enabled");
                    return .{ .goto = route };
                }
            };
        }

        pub fn initState(allocator: std.mem.Allocator) !State {
            var pages: PagesState = undefined;
            errdefer {
                inline for (route_fields) |route_field| {
                    if (@hasField(PagesState, route_field.name)) deinitValue(&@field(pages, route_field.name));
                }
            }
            inline for (route_fields) |route_field| {
                const Page = @field(Spec.Pages, route_field.name);
                @field(pages, route_field.name) = try initValue(Page.State, allocator);
            }

            return .{
                .allocator = allocator,
                .route = initial_route,
                .global = try initValue(GlobalState, allocator),
                .runtime = try initValue(RuntimeState, allocator),
                .pages = pages,
            };
        }

        pub fn deinitState(state: *State) void {
            state.deinit();
        }

        pub fn build(ui: *UIContext(Msg), state: *const State) anyerror!*Node(Msg) {
            return switch (state.route) {
                inline else => |route| blk: {
                    const Page = @field(Spec.Pages, @tagName(route));
                    var ctx = BuildContext(route).init(ui, state);
                    break :blk try Page.build(&ctx, &@field(state.pages, @tagName(route)));
                },
            };
        }

        pub fn update(app: *App, msg: types.InteractionMessage(Msg)) UpdateAction {
            if (flat_single_page_message) {
                const route = initial_route;
                const Page = @field(Spec.Pages, @tagName(route));
                var ctx = UpdateContext(route).init(app, msg.data);
                return Page.update(&ctx, &@field(app.state.pages, @tagName(route)), msg.id);
            }
            switch (msg.id) {
                .goto => |route| {
                    app.state.route = route;
                    // Tree is about to be rebuilt from a new root; the previous
                    // page's nodes will be freed during reconcile, so any
                    // interaction-state pointers (hover/drag/focus) into them
                    // are invalidated. Clear them before processInteractions runs again.
                    app.ui.interaction_registry.resetForNewTree();
                    return .rebuild;
                },
                inline else => |page_msg, tag| {
                    const route: Route = @field(Route, @tagName(tag));
                    const Page = @field(Spec.Pages, @tagName(tag));
                    var ctx = UpdateContext(route).init(app, msg.data);
                    return Page.update(&ctx, &@field(app.state.pages, @tagName(tag)), page_msg);
                },
            }
        }

        pub fn run(init: std.process.Init, comptime RunSpec: type) !void {
            var rt = runtime_mod.Runtime.init();
            defer rt.deinit();
            const allocator = rt.allocator();
            const io = init.io;

            var app = try App.init(
                allocator,
                io,
                windowConfig(RunSpec),
                try initState(allocator),
                update,
            );
            defer app.deinit();
            defer deinitState(&app.state);

            var ctx = RunContext(App){
                .app = &app,
                .allocator = allocator,
                .io = io,
            };
            var did_setup = false;
            defer if (did_setup) callShutdown(RunSpec, &ctx);

            try applyRunSpecBeforeSetup(RunSpec, &app);
            try callSetup(RunSpec, &ctx);
            did_setup = true;
            try app.setRootBuilder(build);
            try app.run();
        }
    };
}

/// Single-page app constructor. Use this when an app has exactly one screen and
/// does not need ManagedApp's Routes/Pages/Global/Runtime decomposition. State is
/// the user's `StateT` directly - no `app.state.pages.X` reach-through.
///
/// `build_fn` and `update_fn` accept `ctx: anytype` so they can reach `ctx.ui`,
/// `ctx.app`, `ctx.event_data`, `ctx.ux`, `ctx.components`. The same shape as
/// ManagedApp's BuildContext / UpdateContext.
pub fn SinglePageApp(
    comptime StateT: type,
    comptime MsgT: type,
    comptime build_fn: anytype,
    comptime update_fn: anytype,
) type {
    comptime {
        state_mod.assertState(StateT);
    }

    return struct {
        const Self = @This();

        pub const State = StateT;
        pub const Message = MsgT;
        pub const App = app_mod.Application(StateT, MsgT);

        pub const BuildContext = struct {
            ui: *UIContext(MsgT),
            app_state: *const StateT,
            ux: uix.Builder(MsgT),
            components: components.Builder(MsgT),

            pub const Message = MsgT;

            pub fn init(ui: *UIContext(MsgT), app_state: *const StateT) @This() {
                return .{
                    .ui = ui,
                    .app_state = app_state,
                    .ux = uix.builder(MsgT, ui),
                    .components = components.Builder(MsgT){ .ui = ui },
                };
            }
        };

        pub const UpdateContext = struct {
            app: *App,
            app_state: *StateT,
            event_data: types.EventData,

            pub fn init(app: *App, event_data: types.EventData) @This() {
                return .{
                    .app = app,
                    .app_state = &app.state,
                    .event_data = event_data,
                };
            }

            pub fn post(self: @This(), msg: MsgT) void {
                self.app.postMessageId(msg);
            }
        };

        pub fn initState(allocator: std.mem.Allocator) !StateT {
            return initValue(StateT, allocator);
        }

        pub fn deinitState(state: *StateT) void {
            deinitValue(state);
        }

        pub fn build(ui: *UIContext(MsgT), state: *const StateT) anyerror!*Node(MsgT) {
            var ctx = BuildContext.init(ui, state);
            return build_fn(&ctx, state);
        }

        pub fn update(app: *App, msg: types.InteractionMessage(MsgT)) UpdateAction {
            var ctx = UpdateContext.init(app, msg.data);
            return update_fn(&ctx, &app.state, msg.id);
        }

        pub fn snapshotJsonAlloc(state: *const StateT, allocator: std.mem.Allocator) ![]u8 {
            const SnapshotT = state_mod.snapshotTypeOf(StateT);
            const version = state_mod.snapshotVersionOf(StateT);
            return state_mod.stringifyEnvelopeAlloc(SnapshotT, allocator, version, state_mod.snapshotOf(state), .{});
        }

        pub fn restoreSnapshotJson(state: *StateT, allocator: std.mem.Allocator, bytes: []const u8) !void {
            const SnapshotT = state_mod.snapshotTypeOf(StateT);
            const version = state_mod.snapshotVersionOf(StateT);
            var parsed = try state_mod.parseEnvelope(SnapshotT, allocator, bytes, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try state_mod.expectEnvelopeVersion(SnapshotT, &parsed, version);
            try state_mod.restoreSnapshotInto(state, &parsed.value.data);
        }

        pub fn run(init: std.process.Init, comptime RunSpec: type) !void {
            var rt = runtime_mod.Runtime.init();
            defer rt.deinit();
            const allocator = rt.allocator();
            const io = init.io;

            var app = try App.init(
                allocator,
                io,
                windowConfig(RunSpec),
                try initState(allocator),
                update,
            );
            defer app.deinit();
            defer deinitState(&app.state);

            var ctx = RunContext(App){
                .app = &app,
                .allocator = allocator,
                .io = io,
            };
            var did_setup = false;
            defer if (did_setup) callShutdown(RunSpec, &ctx);

            try applyRunSpecBeforeSetup(RunSpec, &app);
            try callSetup(RunSpec, &ctx);
            did_setup = true;
            try app.setRootBuilder(build);
            try app.run();
        }
    };
}

test "single page app exposes flat state" {
    const Msg = union(enum) { inc: void };
    const TestState = struct {
        count: u32 = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }
    };

    const Page = struct {
        fn build(ctx: anytype, _: *const TestState) anyerror!*Node(Msg) {
            return ctx.ui.fragment(&.{});
        }
        fn update(_: anytype, state: *TestState, msg: Msg) UpdateAction {
            switch (msg) {
                .inc => state.count += 1,
            }
            return .rebuild;
        }
    };

    const Single = SinglePageApp(TestState, Msg, Page.build, Page.update);

    var state = try Single.initState(std.testing.allocator);
    defer Single.deinitState(&state);

    try std.testing.expectEqual(@as(u32, 0), state.count);
    try std.testing.expectEqual(TestState, Single.State);
    try std.testing.expectEqual(Msg, Single.Message);

    const RunSpec = struct {};
    const Gate = struct {
        fn never() bool {
            return false;
        }
    };
    if (Gate.never()) try Single.run(undefined, RunSpec);
}

test "managed app routes page messages and snapshots exclude runtime" {
    const PageA = struct {
        pub const Msg = union(enum) { inc: void };
        pub const State = struct {
            pub const snapshot_version: state_mod.SnapshotVersion = 1;
            pub const Snapshot = struct { count: u32 = 0 };
            count: u32 = 0,

            pub fn snapshot(self: *const @This()) Snapshot {
                return .{ .count = self.count };
            }

            pub fn restoreSnapshot(self: *@This(), data: *const Snapshot) !void {
                self.count = data.count;
            }
        };

        pub fn build(ctx: anytype, state: *const State) anyerror!*Node(@TypeOf(ctx.*).Message) {
            _ = state;
            return ctx.ui.fragment(&.{});
        }

        pub fn update(_: anytype, state: *State, msg: Msg) UpdateAction {
            switch (msg) {
                .inc => state.count += 1,
            }
            return .rebuild;
        }
    };

    const PageB = struct {
        pub const Msg = union(enum) { noop: void };
        pub const State = PageA.State;
        pub const build = PageA.build;

        pub fn update(_: anytype, _: *State, msg: Msg) UpdateAction {
            switch (msg) {
                .noop => {},
            }
            return .none;
        }
    };

    const Spec = struct {
        pub const Route = enum { a, b };
        pub const Pages = .{ .a = PageA, .b = PageB };
        pub const RuntimeState = struct {
            pub const serializable = false;
            handle: usize = 123,
        };
        pub const initial_route = Route.a;
    };

    const M = ManagedApp(Spec);
    var state = try M.initState(std.testing.allocator);
    defer M.deinitState(&state);

    try std.testing.expectEqual(Spec.Route.a, state.route);
    state.route = .b;
    const snap = state.snapshot();
    try std.testing.expectEqual(Spec.Route.b, snap.route);
    try std.testing.expect(!@hasField(M.Snapshot, "runtime"));

    const RunSpec = struct {};
    const Gate = struct {
        fn never() bool {
            return false;
        }
    };
    if (Gate.never()) try M.run(undefined, RunSpec);
}
