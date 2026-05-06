const std = @import("std");
const UIContext = @import("context.zig").UIContext;
const Node = @import("node.zig").Node;
const FontData = @import("../renderer/font/font_registry.zig").FontData;
const layout = @import("layout.zig");
const node_mod = @import("node.zig");
const theme = @import("theme.zig");
const tw = @import("tw.zig");
const types = @import("types.zig");
const NodeId = types.NodeId;
const RenderPayload = node_mod.RenderPayload;
const AnimatedState = @import("../renderer/image_animation.zig").AnimatedState;

pub const Key = struct {
    id: NodeId,
    index: usize,

    pub fn child(self: Key, key_value: anytype) Key {
        return .{ .id = deriveId(self.id, key_value), .index = self.index };
    }

    pub fn childId(self: Key, key_value: anytype) NodeId {
        return deriveId(self.id, key_value);
    }
};

pub fn deriveId(base_id: NodeId, key_value: anytype) NodeId {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&base_id));
    hashValue(&hasher, key_value);
    return @truncate(hasher.final());
}

fn hashValue(hasher: *std.hash.Wyhash, key_value: anytype) void {
    const T = @TypeOf(key_value);
    const info = @typeInfo(T);
    switch (info) {
        .int, .float, .bool, .@"enum" => {
            const value = key_value;
            hasher.update(std.mem.asBytes(&value));
        },
        .comptime_int => {
            const value: i128 = key_value;
            hasher.update(std.mem.asBytes(&value));
        },
        .comptime_float => {
            const value: f64 = key_value;
            hasher.update(std.mem.asBytes(&value));
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                hasher.update(key_value);
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8) {
                hasher.update(key_value[0..]);
            } else {
                @compileError("uix keyed ids support strings, numbers, bools, and enums");
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                hasher.update(key_value[0..]);
            } else {
                @compileError("uix keyed ids support byte arrays, not arbitrary arrays");
            }
        },
        else => @compileError("uix keyed ids support strings, numbers, bools, and enums"),
    }
}

pub fn event(comptime MessageT: type, event_type: types.EventType, msg: MessageT) types.EventBinding(MessageT) {
    return .{ .event = event_type, .msg = msg };
}

pub fn handled(
    comptime MessageT: type,
    event_type: types.EventType,
    handler: *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT,
    userdata: ?*const anyopaque,
) types.EventBinding(MessageT) {
    return .{ .event = event_type, .handler = handler, .userdata = userdata };
}

pub fn click(comptime MessageT: type, msg: MessageT) types.EventBinding(MessageT) {
    return event(MessageT, .click, msg);
}

pub fn builder(comptime MessageT: type, ui: *UIContext(MessageT)) Builder(MessageT) {
    return .init(ui);
}

pub fn Builder(comptime MessageT: type) type {
    return struct {
        ui: *UIContext(MessageT),

        const Self = @This();
        const AppNode = Node(MessageT);
        const EventBinding = types.EventBinding(MessageT);

        pub fn init(ui: *UIContext(MessageT)) Self {
            return .{ .ui = ui };
        }

        pub fn div(self: Self, opts: anytype) !*AppNode {
            return self.ui.div(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn portal(self: Self, opts: anytype) !*AppNode {
            return self.ui.portal(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn text(self: Self, opts: anytype) !*AppNode {
            return self.ui.text(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .content = @field(opts, "content"),
                .font = @field(opts, "font"),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn button(self: Self, opts: anytype) !*AppNode {
            return self.ui.button(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .label = @field(opts, "label"),
                .font = @field(opts, "font"),
                .label_max_width = optionalField(opts, "label_max_width", f32, 0.0),
                .label_style = labelStyleFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn image(self: Self, opts: anytype) !*AppNode {
            return self.ui.image(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .tex_id = @field(opts, "tex_id"),
                .tint = optionalField(opts, "tint", [4]f32, .{ 1.0, 1.0, 1.0, 1.0 }),
                .intrinsic_size = optionalField(opts, "intrinsic_size", [2]f32, .{ 0.0, 0.0 }),
                .custom_params = optionalField(opts, "custom_params", [4]f32, .{ 0.0, 0.0, 0.0, 0.0 }),
                .alt_text = optionalField(opts, "alt_text", []const u8, ""),
                .alt_font = optionalField(opts, "alt_font", ?*FontData, null),
                .fallback_state = optionalField(opts, "fallback_state", RenderPayload.ImageFallbackState, .ready),
                .animation = optionalField(opts, "animation", ?*const AnimatedState, null),
                .start_time = optionalField(opts, "start_time", f64, 0.0),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn canvas(self: Self, opts: anytype) !*AppNode {
            return self.ui.canvas(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .target = @field(opts, "target"),
                .tint = optionalField(opts, "tint", [4]f32, .{ 1.0, 1.0, 1.0, 1.0 }),
                .custom_params = optionalField(opts, "custom_params", [4]f32, .{ 0.0, 0.0, 0.0, 0.0 }),
                .pan_x = optionalField(opts, "pan_x", f32, 0.0),
                .pan_y = optionalField(opts, "pan_y", f32, 0.0),
                .zoom = optionalField(opts, "zoom", f32, 1.0),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn textInput(self: Self, opts: anytype) !*AppNode {
            return self.ui.textInput(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .font = @field(opts, "font"),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .initial_text = optionalField(opts, "initial_text", []const u8, ""),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn textArea(self: Self, opts: anytype) !*AppNode {
            return self.ui.textArea(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(opts),
                .font = @field(opts, "font"),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .initial_text = optionalField(opts, "initial_text", []const u8, ""),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn fragment(self: Self, children: anytype) !*AppNode {
            return self.ui.fragment(try self.nodes(children));
        }

        pub fn nodes(self: Self, children: anytype) ![]const ?*AppNode {
            const info = @typeInfo(@TypeOf(children));
            if (info == .@"struct" and info.@"struct".is_tuple) {
                const len = info.@"struct".fields.len;
                const out = try self.ui.build_arena.allocator().alloc(?*AppNode, len);
                inline for (info.@"struct".fields, 0..) |field, i| {
                    out[i] = @field(children, field.name);
                }
                return out;
            }
            if (info == .pointer) {
                return self.nodesFromPointer(children);
            }
            @compileError("uix children must be a tuple, slice, or pointer-to-array of nodes");
        }

        pub fn keyedList(self: Self, capacity: usize) !KeyedList(MessageT) {
            return KeyedList(MessageT).init(self.ui.build_arena.allocator(), capacity);
        }

        fn childrenFrom(self: Self, opts: anytype) ![]const ?*AppNode {
            if (@hasField(@TypeOf(opts), "children")) {
                return self.nodes(@field(opts, "children"));
            }
            return &.{};
        }

        fn eventsFrom(self: Self, opts: anytype) ![]const EventBinding {
            const implicit_count = implicitEventCount(opts);
            const explicit_count = explicitEventCount(opts);
            if (implicit_count == 0 and explicit_count == 0) return &.{};

            const out = try self.ui.build_arena.allocator().alloc(EventBinding, implicit_count + explicit_count);
            var index: usize = 0;
            if (@hasField(@TypeOf(opts), "events")) {
                copyEvents(EventBinding, out, &index, @field(opts, "events"));
            }
            appendImplicitEvents(MessageT, opts, out, &index);
            return out;
        }

        fn nodesFromPointer(self: Self, children: anytype) ![]const ?*AppNode {
            const ptr = @typeInfo(@TypeOf(children)).pointer;
            if (ptr.size == .slice) {
                if (ptr.child == ?*AppNode) return children;
                if (ptr.child == *AppNode) {
                    const out = try self.ui.build_arena.allocator().alloc(?*AppNode, children.len);
                    for (children, 0..) |child, i| out[i] = child;
                    return out;
                }
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
                const arr = @typeInfo(ptr.child).array;
                if (arr.child == ?*AppNode or arr.child == *AppNode) {
                    const out = try self.ui.build_arena.allocator().alloc(?*AppNode, arr.len);
                    for (0..arr.len) |i| out[i] = children[i];
                    return out;
                }
            }
            @compileError("uix children pointers must contain *Node or ?*Node");
        }
    };
}

pub fn KeyedList(comptime MessageT: type) type {
    return struct {
        items: []?*Node(MessageT),
        len: usize = 0,

        const Self = @This();
        const AppNode = Node(MessageT);

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const items = try allocator.alloc(?*AppNode, capacity);
            @memset(items, null);
            return .{ .items = items };
        }

        pub fn keyAt(_: *const Self, index: usize, base_id: NodeId, key_value: anytype) Key {
            return .{ .id = deriveId(base_id, key_value), .index = index };
        }

        pub fn append(self: *Self, key: Key, node: ?*AppNode) !void {
            if (self.len >= self.items.len) return error.KeyedListFull;
            try assignKey(key, node);
            self.items[self.len] = node;
            self.len += 1;
        }

        pub fn set(self: *Self, index: usize, key: Key, node: ?*AppNode) !void {
            if (index >= self.items.len) return error.KeyedListIndexOutOfBounds;
            try assignKey(key, node);
            self.items[index] = node;
            if (index >= self.len) self.len = index + 1;
        }

        pub fn put(self: *Self, index: usize, key: Key, node: ?*AppNode) !void {
            try self.set(index, key, node);
        }

        fn assignKey(key: Key, node: ?*AppNode) !void {
            if (node) |n| {
                if (n.id) |existing| {
                    if (existing != key.id) return error.ConflictingNodeId;
                } else {
                    n.id = key.id;
                }
            }
        }

        pub fn slice(self: *const Self) []const ?*AppNode {
            return self.items[0..self.len];
        }
    };
}

fn styleFrom(opts: anytype) layout.Style {
    var result = optionalField(opts, "style", layout.Style, .{});
    if (@hasField(@TypeOf(opts), "class")) {
        result = tw.apply(result, @field(opts, "class"));
    }
    return result;
}

fn labelStyleFrom(opts: anytype) layout.Style {
    var result = optionalField(opts, "label_style", layout.Style, .{});
    if (@hasField(@TypeOf(opts), "label_class")) {
        result = tw.apply(result, @field(opts, "label_class"));
    }
    return result;
}

fn optionalField(opts: anytype, comptime name: []const u8, comptime T: type, default_value: T) T {
    if (@hasField(@TypeOf(opts), name)) {
        return @field(opts, name);
    }
    return default_value;
}

fn implicitEventCount(opts: anytype) usize {
    var count: usize = 0;
    inline for (implicit_event_fields) |field| {
        if (@hasField(@TypeOf(opts), field.name)) count += 1;
    }
    return count;
}

fn explicitEventCount(opts: anytype) usize {
    if (!@hasField(@TypeOf(opts), "events")) return 0;
    const events = @field(opts, "events");
    const info = @typeInfo(@TypeOf(events));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        return info.@"struct".fields.len;
    }
    return events.len;
}

fn copyEvents(comptime EventBinding: type, out: []EventBinding, index: *usize, events: anytype) void {
    const info = @typeInfo(@TypeOf(events));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            out[index.*] = @field(events, field.name);
            index.* += 1;
        }
    } else {
        for (events) |binding| {
            out[index.*] = binding;
            index.* += 1;
        }
    }
}

const ImplicitEvent = struct {
    name: []const u8,
    event_type: types.EventType,
};

const implicit_event_fields = [_]ImplicitEvent{
    .{ .name = "on_click", .event_type = .click },
    .{ .name = "on_pointer_down", .event_type = .pointer_down },
    .{ .name = "on_pointer_up", .event_type = .pointer_up },
    .{ .name = "on_drag", .event_type = .drag },
    .{ .name = "on_hover_enter", .event_type = .hover_enter },
    .{ .name = "on_hover_exit", .event_type = .hover_exit },
    .{ .name = "on_key_down", .event_type = .key_down },
    .{ .name = "on_key_up", .event_type = .key_up },
    .{ .name = "on_text_input", .event_type = .text_input },
    .{ .name = "on_scroll", .event_type = .scroll },
    .{ .name = "on_pointer_move", .event_type = .pointer_move },
};

fn appendImplicitEvents(comptime MessageT: type, opts: anytype, out: anytype, index: *usize) void {
    inline for (implicit_event_fields) |field| {
        if (@hasField(@TypeOf(opts), field.name)) {
            const msg = coerceMessage(MessageT, @field(opts, field.name));
            out[index.*] = .{ .event = field.event_type, .msg = msg };
            index.* += 1;
        }
    }
}

fn coerceMessage(comptime MessageT: type, value: anytype) MessageT {
    const ValueT = @TypeOf(value);
    if (ValueT == MessageT) return value;

    const value_info = @typeInfo(ValueT);
    if (value_info != .@"struct") {
        return @as(MessageT, value);
    }

    if (value_info != .@"struct" or value_info.@"struct".is_tuple or value_info.@"struct".fields.len != 1) {
        @compileError("uix event shorthand expects MessageT or a one-field union literal-shaped struct");
    }

    const field = value_info.@"struct".fields[0];
    if (!@hasField(MessageT, field.name)) {
        @compileError("MessageT has no union field named '" ++ field.name ++ "'");
    }
    return @unionInit(MessageT, field.name, @field(value, field.name));
}

test "deriveId is stable and key scoped" {
    const a = deriveId(10, "row-a");
    const b = deriveId(10, "row-a");
    const c = deriveId(10, "row-b");

    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expect((Key{ .id = a, .index = 0 }).childId("label") != a);
}

test "uix builder creates nodes from style classes and tuple children" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    var font: FontData = undefined;
    const ux = builder(u32, &ui);
    const child = try ux.text(.{
        .content = "hello",
        .font = &font,
        .class = .{ tw.text_lg, tw.text_color(tw.white) },
        .on_click = 7,
    });

    const root = try ux.div(.{
        .class = .{ tw.flex_row, tw.items_center, tw.p(2) },
        .children = .{ child, null },
    });
    defer root.deinit();

    try std.testing.expectEqual(layout.FlexDirection.Row, root.style.direction);
    try std.testing.expectEqual(@as(f32, 8), root.style.padding.left);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), child.events.len);
    try std.testing.expectEqual(types.EventType.click, child.events[0].event);
}

test "uix keyed list assigns stable ids" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    const ux = builder(u32, &ui);
    var list = try ux.keyedList(2);
    const node = try ux.div(.{});
    defer node.deinit();
    const key = list.keyAt(0, 1234, "alpha");
    try list.append(key, node);

    try std.testing.expectEqual(@as(usize, 1), list.slice().len);
    try std.testing.expectEqual(key.id, node.id.?);
}
