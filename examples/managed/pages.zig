//! Swappable page logic for the ManagedApp hot-reload demo.
const std = @import("std");
const lib = @import("ramiel");
const tw = lib.tw;

pub const GlobalState = struct {
    clicks: u32 = 0,

    pub const snapshot_version: u32 = 1;
    pub const Snapshot = struct { clicks: u32 = 0 };
    pub fn snapshot(self: *const @This()) Snapshot {
        return .{ .clicks = self.clicks };
    }
    pub fn restoreSnapshot(self: *@This(), data: *const Snapshot) !void {
        self.clicks = data.clicks;
    }
};

pub const RuntimeState = struct {
    pub const serializable = false;
    font_data: *lib.FontData = undefined,
};

fn pageRoot(ctx: anytype, children: anytype) !*lib.Node(@TypeOf(ctx.*).Message) {
    return ctx.ux.div(.{
        .style = tw.style(.{
            tw.size_screen,
            tw.flex_col,
            tw.justify_center,
            tw.items_center,
            tw.gap_px(14.0),
            tw.bg_value(lib.layout.Color.from(.{ 0.08, 0.09, 0.12, 1.0 })),
        }),
        .children = children,
    });
}

fn label(ctx: anytype, content: []const u8) !*lib.Node(@TypeOf(ctx.*).Message) {
    return ctx.ux.text(.{
        .content = content,
        .font = ctx.runtime.font_data,
        .style = tw.style(.{tw.text_color_value(lib.layout.Color.from(.{ 0.86, 0.9, 0.98, 1.0 }))}),
    });
}

fn button(ctx: anytype, content: []const u8, on_click: anytype) !*lib.Node(@TypeOf(ctx.*).Message) {
    return ctx.ux.div(.{
        .style = tw.style(.{
            tw.px(16.0),
            tw.py(9.0),
            tw.bg_value(lib.layout.Color.from(.{ 0.30, 0.70, 0.5, 1.0 })),
            tw.rounded(8.0),
            tw.cursor_pointer,
        }),
        .on_click = on_click,
        .children = .{try ctx.ux.text(.{
            .content = content,
            .font = ctx.runtime.font_data,
            .style = tw.style(.{tw.text_color_value(lib.layout.Color.from(.{ 0.04, 0.06, 0.1, 1.0 }))}),
        })},
    });
}

pub const HomePage = struct {
    pub const Msg = union(enum) { noop };
    pub const State = struct {};

    pub fn build(ctx: anytype, _: *const State) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
        const arena = ctx.ui.build_arena.allocator();
        const clicks = try std.fmt.allocPrint(arena, "global clicks: {d}", .{ctx.global.clicks});
        return pageRoot(ctx, .{
            try label(ctx, "Home"),
            try label(ctx, clicks),
            try button(ctx, "Go to counter", ctx.goto(.counter)),
        });
    }

    pub fn update(_: anytype, _: *State, msg: Msg) lib.UpdateAction {
        switch (msg) {
            .noop => {},
        }
        return .none;
    }
};

pub const CounterPage = struct {
    pub const Msg = union(enum) { inc, dec };
    pub const State = struct {
        count: i32 = 0,

        pub const snapshot_version: u32 = 1;
        pub const Snapshot = struct { count: i32 = 0 };
        pub fn snapshot(self: *const @This()) Snapshot {
            return .{ .count = self.count };
        }
        pub fn restoreSnapshot(self: *@This(), data: *const Snapshot) !void {
            self.count = data.count;
        }
    };

    pub fn build(ctx: anytype, state: *const State) anyerror!*lib.Node(@TypeOf(ctx.*).Message) {
        const arena = ctx.ui.build_arena.allocator();
        const count = try std.fmt.allocPrint(arena, "count: {d}", .{state.count});
        return pageRoot(ctx, .{
            try label(ctx, "Counter"),
            try label(ctx, count),
            try button(ctx, "- 2", .{ .dec = {} }),
            try button(ctx, "+ 3", .{ .inc = {} }),
            try button(ctx, "Back home", ctx.goto(.home)),
        });
    }

    pub fn update(ctx: anytype, state: *State, msg: Msg) lib.UpdateAction {
        switch (msg) {
            .inc => state.count += 1,
            .dec => state.count -= 1,
        }
        ctx.global.clicks += 1;
        return .rebuild;
    }
};
