const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const NodeId = types.NodeId;
const deriveChildId = @import("id.zig").deriveChildId;
const destroyOwnedEventUserdata = @import("../node.zig").destroyOwnedEventUserdata;

pub const SliderSlot = struct { style: layout.Style = .{} };

pub const SliderDescriptor = struct {
    track: SliderSlot = .{},
    fill: SliderSlot = .{},
    handle: SliderSlot = .{},
};

pub fn SliderParams(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        value: f32,
        on_change: *const fn (f32, ?*const anyopaque) MessageT,
        userdata: ?*const anyopaque = null,

        track: SliderSlot = .{},
        fill: SliderSlot = .{},
        handle: SliderSlot = .{},
    };
}

fn sliderInteractionHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    const Payload = struct {
        cb: *const fn (f32, ?*const anyopaque) MessageT,
        data: ?*const anyopaque,
    };
    return struct {
        fn handle(userdata: ?*const anyopaque, layout_snap: types.EventLayoutSnapshot, event_data: types.EventData) ?MessageT {
            const w = layout_snap.width;
            if (w <= 0.0) return null;
            const payload: *const Payload = @ptrCast(@alignCast(userdata.?));

            switch (event_data) {
                .mouse => |m| {
                    const local_x = m.x - layout_snap.x;
                    const normalized = std.math.clamp(local_x / w, 0.0, 1.0);
                    return payload.cb(normalized, payload.data);
                },
                .drag => |d| {
                    const local_x = d.x - layout_snap.x;
                    const normalized = std.math.clamp(local_x / w, 0.0, 1.0);
                    return payload.cb(normalized, payload.data);
                },
                else => return null,
            }
        }
    }.handle;
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    params: SliderParams(MessageT),
) !*Node(MessageT) {
    const value = std.math.clamp(params.value, 0.0, 1.0);
    const visual_value = if (value <= 0.0) 0.0001 else value;

    const tokens = ctx.active_theme.tokens;

    var rail_style = params.track.style;
    switch (rail_style.width) {
        .Auto => rail_style.width = .Full,
        else => {},
    }
    switch (rail_style.height) {
        .Auto => rail_style.height = .{ .exact = 8.0 },
        else => {},
    }
    if (rail_style.background_color[3] == 0.0) {
        rail_style.background_color = tokens.bg_surface;
    }
    const rail_h = switch (rail_style.height) {
        .exact => |h| h,
        else => 8.0,
    };
    if (!rail_style.corner_radius.hasAny()) {
        rail_style.corner_radius = layout.CornerRadius.all(rail_h / 2.0);
    }
    rail_style.direction = .Row;
    rail_style.align_items = .Center;
    rail_style.pointer_events = .none;

    var handle_style = params.handle.style;
    switch (handle_style.width) {
        .Auto => handle_style.width = .{ .exact = 20.0 },
        else => {},
    }
    switch (handle_style.height) {
        .Auto => handle_style.height = .{ .exact = 20.0 },
        else => {},
    }

    const handle_dia = switch (handle_style.width) {
        .exact => |w| w,
        else => 20.0,
    };
    const handle_h = switch (handle_style.height) {
        .exact => |h| h,
        else => 20.0,
    };
    const half_handle = handle_dia * 0.5;

    if (handle_style.background_color[3] == 0.0) {
        handle_style.background_color = tokens.text_main;
    }
    if (!handle_style.corner_radius.hasAny()) {
        handle_style.corner_radius = layout.CornerRadius.all(half_handle);
    }
    const vertical_offset = (handle_h - rail_h) / 2.0;
    handle_style.margin.top = -vertical_offset;
    handle_style.margin.bottom = -vertical_offset;
    handle_style.margin.right = -half_handle;
    handle_style.pointer_events = .none;

    const handle_node = try ctx.div(.{
        .id = deriveChildId(params.base_id, "handle"),
        .style = handle_style,
    });

    var fill_style = params.fill.style;
    if (fill_style.background_color[3] == 0.0) {
        fill_style.background_color = tokens.action_default;
    }
    fill_style.width = .{ .percent = visual_value };
    fill_style.min_width = .{ .exact = half_handle };
    fill_style.max_width = .Full;
    fill_style.height = .Full;
    fill_style.direction = .Row;
    fill_style.align_items = .Center;
    fill_style.justify_content = .End;
    fill_style.pointer_events = .none;
    fill_style.corner_radius = rail_style.corner_radius;

    var track_style = params.track.style;
    switch (track_style.width) {
        .Auto => track_style.width = .Full,
        else => track_style.width = rail_style.width,
    }
    track_style.height = .{ .exact = @max(rail_h, handle_h) };
    track_style.direction = .Row;
    track_style.align_items = .Center;
    track_style.cursor = .pointer;
    track_style.background_color = .{ 0.0, 0.0, 0.0, 0.0 };
    track_style.corner_radius = .{};

    const Payload = struct {
        cb: *const fn (f32, ?*const anyopaque) MessageT,
        data: ?*const anyopaque,
    };
    const alloc = ctx.build_arena.allocator();
    const drag_payload = try ctx.gpa.create(Payload);
    drag_payload.* = .{ .cb = params.on_change, .data = params.userdata };
    const click_payload = try ctx.gpa.create(Payload);
    click_payload.* = .{ .cb = params.on_change, .data = params.userdata };
    const h = sliderInteractionHandler(MessageT);

    const events = try alloc.dupe(types.EventBinding(MessageT), &.{
        .{
            .event = .drag,
            .userdata = drag_payload,
            .destroy_userdata = destroyOwnedEventUserdata(Payload),
            .handler = h,
        },
        .{
            .event = .click,
            .userdata = click_payload,
            .destroy_userdata = destroyOwnedEventUserdata(Payload),
            .handler = h,
        },
    });

    const fill_node = try ctx.div(.{
        .id = deriveChildId(params.base_id, "fill"),
        .style = fill_style,
        .children = &.{handle_node},
    });

    const rail_node = try ctx.div(.{
        .id = deriveChildId(params.base_id, "rail"),
        .style = rail_style,
        .children = &.{fill_node},
    });

    return ctx.div(.{
        .id = deriveChildId(params.base_id, "track"),
        .style = track_style,
        .events = events,
        .children = &.{rail_node},
    });
}
