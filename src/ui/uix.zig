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
const paint_context = @import("paint_context.zig");

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

pub fn scopedBuilder(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    ui: *UIContext(AppMessageT),
) ScopedBuilder(AppMessageT, LocalMessageT, parent_tag) {
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
                .style = styleFrom(self.ui, opts),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn portal(self: Self, opts: anytype) !*AppNode {
            return self.ui.portal(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn text(self: Self, opts: anytype) !*AppNode {
            return self.ui.text(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .content = @field(opts, "content"),
                .font = optionalField(opts, "font", ?*FontData, null),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn button(self: Self, opts: anytype) !*AppNode {
            return self.ui.button(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .label = @field(opts, "label"),
                .font = optionalField(opts, "font", ?*FontData, null),
                .label_max_width = optionalField(opts, "label_max_width", f32, 0.0),
                .label_style = labelStyleFrom(self.ui, opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn asyncImage(self: Self, opts: anytype) !*AppNode {
            return self.ui.asyncImage(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .source = @field(opts, "source"),
                .tint = optionalField(opts, "tint", [4]f32, .{ 1.0, 1.0, 1.0, 1.0 }),
                .intrinsic_size = optionalField(opts, "intrinsic_size", [2]f32, .{ 0.0, 0.0 }),
                .custom_params = optionalField(opts, "custom_params", [4]f32, .{ 0.0, 0.0, 0.0, 0.0 }),
                .alt_text = optionalField(opts, "alt_text", []const u8, ""),
                .alt_font = optionalField(opts, "alt_font", ?*FontData, null),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn customPaint(self: Self, opts: anytype) !*AppNode {
            return self.ui.customPaint(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .paint_fn = @field(opts, "paint_fn"),
                .userdata = optionalField(opts, "userdata", ?*const anyopaque, null),
                .revision = optionalField(opts, "revision", u64, 0),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn image(self: Self, opts: anytype) !*AppNode {
            return self.ui.image(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
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
                .style = styleFrom(self.ui, opts),
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
                .style = styleFrom(self.ui, opts),
                .font = optionalField(opts, "font", ?*FontData, null),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .initial_text = optionalField(opts, "initial_text", []const u8, ""),
                .placeholder = optionalField(opts, "placeholder", []const u8, ""),
                .placeholder_color = optionalField(opts, "placeholder_color", ?[4]f32, null),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn textArea(self: Self, opts: anytype) !*AppNode {
            return self.ui.textArea(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .font = optionalField(opts, "font", ?*FontData, null),
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

        pub fn keyed(self: Self, base_id: NodeId, capacity: usize) !ScopedKeyedList(MessageT) {
            return ScopedKeyedList(MessageT).init(self.ui.build_arena.allocator(), base_id, capacity);
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
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .@"struct" and @typeInfo(ptr.child).@"struct".is_tuple) {
                return self.nodes(children.*);
            }
            @compileError("uix children pointers must contain *Node or ?*Node");
        }
    };
}

pub fn ScopedBuilder(comptime AppMessageT: type, comptime LocalMessageT: type, comptime parent_tag: anytype) type {
    return struct {
        ui: *UIContext(AppMessageT),

        const Self = @This();
        const AppNode = Node(AppMessageT);
        const EventBinding = types.EventBinding(AppMessageT);

        pub fn init(ui: *UIContext(AppMessageT)) Self {
            return .{ .ui = ui };
        }

        pub fn msg(_: Self, local: LocalMessageT) AppMessageT {
            return @unionInit(AppMessageT, @tagName(parent_tag), local);
        }

        pub fn div(self: Self, opts: anytype) !*AppNode {
            return self.ui.div(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn portal(self: Self, opts: anytype) !*AppNode {
            return self.ui.portal(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn text(self: Self, opts: anytype) !*AppNode {
            return self.ui.text(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .content = @field(opts, "content"),
                .font = optionalField(opts, "font", ?*FontData, null),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn button(self: Self, opts: anytype) !*AppNode {
            return self.ui.button(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .label = @field(opts, "label"),
                .font = optionalField(opts, "font", ?*FontData, null),
                .label_max_width = optionalField(opts, "label_max_width", f32, 0.0),
                .label_style = labelStyleFrom(self.ui, opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn asyncImage(self: Self, opts: anytype) !*AppNode {
            return self.ui.asyncImage(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .source = @field(opts, "source"),
                .tint = optionalField(opts, "tint", [4]f32, .{ 1.0, 1.0, 1.0, 1.0 }),
                .intrinsic_size = optionalField(opts, "intrinsic_size", [2]f32, .{ 0.0, 0.0 }),
                .custom_params = optionalField(opts, "custom_params", [4]f32, .{ 0.0, 0.0, 0.0, 0.0 }),
                .alt_text = optionalField(opts, "alt_text", []const u8, ""),
                .alt_font = optionalField(opts, "alt_font", ?*FontData, null),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn customPaint(self: Self, opts: anytype) !*AppNode {
            return self.ui.customPaint(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .paint_fn = @field(opts, "paint_fn"),
                .userdata = optionalField(opts, "userdata", ?*const anyopaque, null),
                .revision = optionalField(opts, "revision", u64, 0),
                .children = try self.childrenFrom(opts),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn image(self: Self, opts: anytype) !*AppNode {
            return self.ui.image(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
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
                .style = styleFrom(self.ui, opts),
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
                .style = styleFrom(self.ui, opts),
                .font = optionalField(opts, "font", ?*FontData, null),
                .max_width = optionalField(opts, "max_width", f32, 0.0),
                .initial_text = optionalField(opts, "initial_text", []const u8, ""),
                .placeholder = optionalField(opts, "placeholder", []const u8, ""),
                .placeholder_color = optionalField(opts, "placeholder_color", ?[4]f32, null),
                .events = try self.eventsFrom(opts),
            });
        }

        pub fn textArea(self: Self, opts: anytype) !*AppNode {
            return self.ui.textArea(.{
                .id = optionalField(opts, "id", ?NodeId, null),
                .style = styleFrom(self.ui, opts),
                .font = optionalField(opts, "font", ?*FontData, null),
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

        pub fn keyedList(self: Self, capacity: usize) !KeyedList(AppMessageT) {
            return KeyedList(AppMessageT).init(self.ui.build_arena.allocator(), capacity);
        }

        pub fn keyed(self: Self, base_id: NodeId, capacity: usize) !ScopedKeyedList(AppMessageT) {
            return ScopedKeyedList(AppMessageT).init(self.ui.build_arena.allocator(), base_id, capacity);
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
                copyScopedEvents(AppMessageT, LocalMessageT, parent_tag, out, &index, @field(opts, "events"));
            }
            appendScopedImplicitEvents(AppMessageT, LocalMessageT, parent_tag, opts, out, &index);
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
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .@"struct" and @typeInfo(ptr.child).@"struct".is_tuple) {
                return self.nodes(children.*);
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

pub fn ScopedKeyedList(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        list: KeyedList(MessageT),

        const Self = @This();
        const AppNode = Node(MessageT);

        pub fn init(allocator: std.mem.Allocator, base_id: NodeId, capacity: usize) !Self {
            return .{
                .base_id = base_id,
                .list = try KeyedList(MessageT).init(allocator, capacity),
            };
        }

        pub fn append(self: *Self, key_value: anytype, node: ?*AppNode) !void {
            try self.list.append(self.list.keyAt(self.list.len, self.base_id, key_value), node);
        }

        pub fn set(self: *Self, index: usize, key_value: anytype, node: ?*AppNode) !void {
            try self.list.set(index, self.list.keyAt(index, self.base_id, key_value), node);
        }

        pub fn put(self: *Self, index: usize, key_value: anytype, node: ?*AppNode) !void {
            try self.set(index, key_value, node);
        }

        pub fn key(self: *const Self, key_value: anytype) Key {
            return .{ .id = deriveId(self.base_id, key_value), .index = self.list.len };
        }

        pub fn childId(self: *const Self, key_value: anytype) NodeId {
            return deriveId(self.base_id, key_value);
        }

        pub fn slice(self: *const Self) []const ?*AppNode {
            return self.list.slice();
        }

        pub fn len(self: *const Self) usize {
            return self.list.len;
        }
    };
}

fn styleFrom(ui: anytype, opts: anytype) layout.Style {
    var result: layout.Style = if (@hasField(@TypeOf(opts), "style"))
        structFrom(layout.Style, @field(opts, "style"))
    else
        .{};
    if (@hasField(@TypeOf(opts), "class")) {
        result = tw.applyTheme(result, ui.active_theme.tokens, @field(opts, "class"));
    }
    return result;
}

fn labelStyleFrom(ui: anytype, opts: anytype) layout.Style {
    var result: layout.Style = if (@hasField(@TypeOf(opts), "label_style"))
        structFrom(layout.Style, @field(opts, "label_style"))
    else
        .{};
    if (@hasField(@TypeOf(opts), "label_class")) {
        result = tw.applyTheme(result, ui.active_theme.tokens, @field(opts, "label_class"));
    }
    return result;
}

fn structFrom(comptime T: type, value: anytype) T {
    if (@TypeOf(value) == T) return value;

    const info = @typeInfo(@TypeOf(value));
    if (info != .@"struct") {
        return @as(T, value);
    }

    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@hasField(@TypeOf(value), field.name)) {
            @field(result, field.name) = coerceValue(field.type, @field(value, field.name));
        } else if (field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else {
            @compileError("missing field '" ++ field.name ++ "' for " ++ @typeName(T));
        }
    }

    inline for (info.@"struct".fields) |field| {
        if (!@hasField(T, field.name)) {
            @compileError("unknown field '" ++ field.name ++ "' for " ++ @typeName(T));
        }
    }
    return result;
}

fn coerceValue(comptime T: type, value: anytype) T {
    if (@TypeOf(value) == T) return value;

    const dest_info = @typeInfo(T);
    const value_info = @typeInfo(@TypeOf(value));

    switch (dest_info) {
        .optional => |optional_info| {
            if (@TypeOf(value) == @TypeOf(null)) return null;
            return coerceValue(optional_info.child, value);
        },
        .float => {
            return switch (value_info) {
                .int, .comptime_int => @floatFromInt(value),
                .float, .comptime_float => @floatCast(value),
                else => @as(T, value),
            };
        },
        .@"struct" => {
            if (value_info == .@"struct") return structFrom(T, value);
        },
        .@"union" => |union_info| {
            if (value_info == .@"struct" and !value_info.@"struct".is_tuple and value_info.@"struct".fields.len == 1) {
                const field = value_info.@"struct".fields[0];
                inline for (union_info.fields) |union_field| {
                    if (comptime std.mem.eql(u8, union_field.name, field.name)) {
                        return @unionInit(T, field.name, coerceValue(union_field.type, @field(value, field.name)));
                    }
                }
                @compileError("unknown union field '" ++ field.name ++ "' for " ++ @typeName(T));
            }
        },
        else => {},
    }

    return @as(T, value);
}

fn optionalField(opts: anytype, comptime name: []const u8, comptime T: type, default_value: T) T {
    if (@hasField(@TypeOf(opts), name)) {
        return coerceValue(T, @field(opts, name));
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
    if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .@"struct" and @typeInfo(info.pointer.child).@"struct".is_tuple) {
        return @typeInfo(info.pointer.child).@"struct".fields.len;
    }
    return events.len;
}

fn copyEvents(comptime EventBinding: type, out: []EventBinding, index: *usize, events: anytype) void {
    const info = @typeInfo(@TypeOf(events));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            out[index.*] = eventBindingFrom(EventBinding, @field(events, field.name));
            index.* += 1;
        }
    } else if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .@"struct" and @typeInfo(info.pointer.child).@"struct".is_tuple) {
        copyEvents(EventBinding, out, index, events.*);
    } else {
        for (events) |binding| {
            out[index.*] = eventBindingFrom(EventBinding, binding);
            index.* += 1;
        }
    }
}

fn eventBindingFrom(comptime EventBinding: type, binding: anytype) EventBinding {
    if (@TypeOf(binding) == EventBinding) return binding;

    var result: EventBinding = .{ .event = @field(binding, "event") };
    if (@hasField(@TypeOf(binding), "msg")) result.msg = coerceValue(@TypeOf(result.msg), @field(binding, "msg"));
    if (@hasField(@TypeOf(binding), "userdata")) result.userdata = @field(binding, "userdata");
    if (@hasField(@TypeOf(binding), "destroy_userdata")) result.destroy_userdata = @field(binding, "destroy_userdata");
    if (@hasField(@TypeOf(binding), "handler")) result.handler = @field(binding, "handler");
    return result;
}

fn copyScopedEvents(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    out: []types.EventBinding(AppMessageT),
    index: *usize,
    events: anytype,
) void {
    const info = @typeInfo(@TypeOf(events));
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            out[index.*] = scopedEvent(AppMessageT, LocalMessageT, parent_tag, @field(events, field.name));
            index.* += 1;
        }
    } else if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .@"struct" and @typeInfo(info.pointer.child).@"struct".is_tuple) {
        copyScopedEvents(AppMessageT, LocalMessageT, parent_tag, out, index, events.*);
    } else {
        for (events) |binding| {
            out[index.*] = scopedEvent(AppMessageT, LocalMessageT, parent_tag, binding);
            index.* += 1;
        }
    }
}

fn scopedEvent(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    binding: anytype,
) types.EventBinding(AppMessageT) {
    const BindingT = @TypeOf(binding);
    if (BindingT == types.EventBinding(AppMessageT)) return binding;
    if (BindingT == types.EventBinding(LocalMessageT)) {
        var result: types.EventBinding(AppMessageT) = .{ .event = binding.event };
        if (binding.handler) |handler| {
            result.handler = scopedHandler(AppMessageT, LocalMessageT, parent_tag, handler);
            result.userdata = binding.userdata;
            result.destroy_userdata = binding.destroy_userdata;
        } else {
            result.msg = wrapScopedMessage(AppMessageT, LocalMessageT, parent_tag, binding.msg.?);
        }
        return result;
    }
    return .{
        .event = @field(binding, "event"),
        .msg = wrapScopedMessage(AppMessageT, LocalMessageT, parent_tag, @field(binding, "msg")),
    };
}

fn scopedHandler(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    handler: *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?LocalMessageT,
) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?AppMessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, layout_snapshot: types.EventLayoutSnapshot, data: types.EventData) ?AppMessageT {
            const local = handler(userdata, layout_snapshot, data) orelse return null;
            return wrapScopedMessage(AppMessageT, LocalMessageT, parent_tag, local);
        }
    }.handle;
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
    .{ .name = "on_context_menu", .event_type = .context_menu },
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

fn appendScopedImplicitEvents(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    opts: anytype,
    out: anytype,
    index: *usize,
) void {
    inline for (implicit_event_fields) |field| {
        if (@hasField(@TypeOf(opts), field.name)) {
            const msg = coerceScopedMessage(AppMessageT, LocalMessageT, parent_tag, @field(opts, field.name));
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

fn coerceScopedMessage(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    value: anytype,
) AppMessageT {
    const ValueT = @TypeOf(value);
    if (ValueT == AppMessageT) return value;
    if (ValueT == LocalMessageT) return wrapScopedMessage(AppMessageT, LocalMessageT, parent_tag, value);

    const value_info = @typeInfo(ValueT);
    if (value_info != .@"struct") {
        return @as(AppMessageT, value);
    }

    if (value_info.@"struct".is_tuple or value_info.@"struct".fields.len != 1) {
        @compileError("scoped uix event shorthand expects app message, local message, or a one-field union literal-shaped struct");
    }

    const field = value_info.@"struct".fields[0];
    if (@hasField(LocalMessageT, field.name)) {
        const local = @unionInit(LocalMessageT, field.name, @field(value, field.name));
        return wrapScopedMessage(AppMessageT, LocalMessageT, parent_tag, local);
    }
    if (@hasField(AppMessageT, field.name)) {
        return @unionInit(AppMessageT, field.name, @field(value, field.name));
    }
    @compileError("neither local page message nor app message has union field named '" ++ field.name ++ "'");
}

fn wrapScopedMessage(
    comptime AppMessageT: type,
    comptime LocalMessageT: type,
    comptime parent_tag: anytype,
    value: LocalMessageT,
) AppMessageT {
    return @unionInit(AppMessageT, @tagName(parent_tag), value);
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
        .class = .{ tw.text_lg, tw.text_muted },
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
    try std.testing.expectEqual(ui.active_theme.tokens.text_muted, child.style.text_color);
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

test "uix scoped keyed list removes manual key plumbing" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    const ux = builder(u32, &ui);
    var list = try ux.keyed(5678, 2);
    const node = try ux.div(.{});
    defer node.deinit();
    try list.append("alpha", node);

    try std.testing.expectEqual(@as(usize, 1), list.slice().len);
    try std.testing.expectEqual(deriveId(5678, "alpha"), node.id.?);
}

test "uix wraps async image and custom paint" {
    var ui = try UIContext(u32).init(std.testing.allocator, theme.Theme.init(.{ 0.6, 0.1, 250.0, 1.0 }, true));
    defer ui.deinit();

    const Resolver = struct {
        fn tex(_: *anyopaque, _: []const u8) u32 {
            return 42;
        }
        fn state(_: *anyopaque, _: []const u8) RenderPayload.ImageFallbackState {
            return .ready;
        }
        fn anim(_: *anyopaque, _: []const u8) ?*const AnimatedState {
            return null;
        }
        fn paint(_: *paint_context.PaintContext, _: ?*const anyopaque) anyerror!void {}
    };
    var resolver_ctx: u8 = 0;
    ui.image_resolver = .{
        .context = &resolver_ctx,
        .getTexId = Resolver.tex,
        .getResolvedState = Resolver.state,
        .getAnimation = Resolver.anim,
    };

    const ux = builder(u32, &ui);
    const image_node = try ux.asyncImage(.{ .source = "asset", .on_click = 1 });
    defer image_node.deinit();
    try std.testing.expectEqual(@as(u32, 42), image_node.payload.image.tex_id);
    try std.testing.expectEqual(@as(usize, 1), image_node.events.len);

    const paint_node = try ux.customPaint(.{ .paint_fn = Resolver.paint, .revision = 7 });
    defer paint_node.deinit();
    try std.testing.expectEqual(@as(u64, 7), paint_node.payload.custom_paint.revision);
}
