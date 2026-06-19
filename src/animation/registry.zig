const std = @import("std");
const NodeId = @import("../ui/types.zig").NodeId;
const layout = @import("../ui/layout.zig");
const EasingFunction = @import("easing.zig").EasingFunction;

const Style = layout.Style;
const Transform = layout.Transform;
const Color = layout.Color;

pub const AnimatedProperty = enum {
    background_color,
    hover_color,
    text_color,
    border_color,
    outline_color,
    shadow_color,
    text_decoration_color,
    opacity,
    shadow_blur,
    shadow_offset,
    corner_radius,
    blur,
    backdrop_blur,
    translate,
    scale,
    rotate,
};

pub const AnimatedValue = union(AnimatedProperty) {
    background_color: ColorAnim,
    hover_color: ColorAnim,
    text_color: ColorAnim,
    border_color: ColorAnim,
    outline_color: ColorAnim,
    shadow_color: ColorAnim,
    text_decoration_color: ColorAnim,
    opacity: ScalarAnim,
    shadow_blur: ScalarAnim,
    shadow_offset: Vec2Anim,
    corner_radius: RadiiAnim,
    blur: ScalarAnim,
    backdrop_blur: ScalarAnim,
    translate: Vec2Anim,
    scale: ScalarAnim,
    rotate: ScalarAnim,

    pub const ColorAnim = struct { from: Color, to: Color };
    pub const ScalarAnim = struct { from: f32, to: f32 };
    pub const Vec2Anim = struct { from: [2]f32, to: [2]f32 };
    pub const RadiiAnim = struct { from: [4]f32, to: [4]f32 };

    pub fn property(self: AnimatedValue) AnimatedProperty {
        return std.meta.activeTag(self);
    }
};

pub const AnimationEntry = struct {
    node_id: NodeId,
    value: AnimatedValue,
    /// Absolute glfw.getTime() seconds. Animation begins at start_time + delay.
    start_time: f64,
    duration: f64,
    delay: f64,
    timing: EasingFunction,
    looping: bool = false,
};

/// True if both animations (same active tag) head to the same target.
fn targetsEqual(a: AnimatedValue, b: AnimatedValue) bool {
    return switch (a) {
        .background_color => |x| x.to.eql(b.background_color.to),
        .hover_color => |x| x.to.eql(b.hover_color.to),
        .text_color => |x| x.to.eql(b.text_color.to),
        .border_color => |x| x.to.eql(b.border_color.to),
        .outline_color => |x| x.to.eql(b.outline_color.to),
        .shadow_color => |x| x.to.eql(b.shadow_color.to),
        .text_decoration_color => |x| x.to.eql(b.text_decoration_color.to),
        .corner_radius => |x| std.mem.eql(f32, &x.to, &b.corner_radius.to),
        .shadow_offset => |x| std.mem.eql(f32, &x.to, &b.shadow_offset.to),
        .translate => |x| std.mem.eql(f32, &x.to, &b.translate.to),
        .opacity => |x| x.to == b.opacity.to,
        .shadow_blur => |x| x.to == b.shadow_blur.to,
        .blur => |x| x.to == b.blur.to,
        .backdrop_blur => |x| x.to == b.backdrop_blur.to,
        .scale => |x| x.to == b.scale.to,
        .rotate => |x| x.to == b.rotate.to,
    };
}

fn lerpF(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpColor(a: Color, b: Color, t: f32) Color {
    return Color.lerp(a, b, t);
}

fn lerpVec2(a: [2]f32, b: [2]f32, t: f32) [2]f32 {
    return .{ lerpF(a[0], b[0], t), lerpF(a[1], b[1], t) };
}

fn lerpRadii(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        lerpF(a[0], b[0], t),
        lerpF(a[1], b[1], t),
        lerpF(a[2], b[2], t),
        lerpF(a[3], b[3], t),
    };
}

fn computeT(entry: *const AnimationEntry, current_time: f64) ?f32 {
    const elapsed = current_time - (entry.start_time + entry.delay);
    // Hold the start value during the delay (CSS transition-delay semantics).
    if (elapsed < 0.0) return 0.0;
    if (entry.duration <= 0.0) return 1.0;
    const raw = elapsed / entry.duration;
    if (entry.looping) {
        const wrapped = @mod(raw, 1.0);
        return entry.timing.apply(@floatCast(wrapped));
    } else {
        return entry.timing.apply(@floatCast(@min(1.0, raw)));
    }
}

fn applyEntry(entry: *const AnimationEntry, style: *Style, current_time: f64) bool {
    const t = computeT(entry, current_time) orelse return true;

    switch (entry.value) {
        .background_color => |a| style.background_color = lerpColor(a.from, a.to, t),
        .hover_color => |a| style.hover_color = lerpColor(a.from, a.to, t),
        .text_color => |a| style.text_color = lerpColor(a.from, a.to, t),
        .border_color => |a| {
            const c = lerpColor(a.from, a.to, t);
            style.border.top.color = c;
            style.border.right.color = c;
            style.border.bottom.color = c;
            style.border.left.color = c;
        },
        .outline_color => |a| {
            const c = lerpColor(a.from, a.to, t);
            style.outline.top.color = c;
            style.outline.right.color = c;
            style.outline.bottom.color = c;
            style.outline.left.color = c;
        },
        .shadow_color => |a| style.shadow_color = lerpColor(a.from, a.to, t),
        .text_decoration_color => |a| style.text_decoration.color = lerpColor(a.from, a.to, t),
        .opacity => |a| style.opacity = lerpF(a.from, a.to, t),
        .shadow_blur => |a| style.shadow_blur = lerpF(a.from, a.to, t),
        .shadow_offset => |a| style.shadow_offset = lerpVec2(a.from, a.to, t),
        .corner_radius => |a| {
            const r = lerpRadii(a.from, a.to, t);
            style.corner_radius.top_left = r[0];
            style.corner_radius.top_right = r[1];
            style.corner_radius.bottom_right = r[2];
            style.corner_radius.bottom_left = r[3];
        },
        .blur => |a| style.blur = lerpF(a.from, a.to, t),
        .backdrop_blur => |a| style.backdrop_blur = lerpF(a.from, a.to, t),
        .translate => |a| style.transform.translate = lerpVec2(a.from, a.to, t),
        .scale => |a| style.transform.scale = lerpF(a.from, a.to, t),
        .rotate => |a| style.transform.rotate = lerpF(a.from, a.to, t),
    }

    if (entry.looping) return true;
    const elapsed = current_time - (entry.start_time + entry.delay);
    return elapsed < entry.duration;
}

pub const AnimationRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(AnimationEntry),

    pub fn init(allocator: std.mem.Allocator) AnimationRegistry {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(AnimationEntry).empty,
        };
    }

    pub fn deinit(self: *AnimationRegistry) void {
        self.entries.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const AnimationRegistry) bool {
        return self.entries.items.len == 0;
    }

    pub fn clear(self: *AnimationRegistry) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn register(self: *AnimationRegistry, entry: AnimationEntry, current_time: f64) !void {
        const prop = entry.value.property();

        for (self.entries.items) |*existing| {
            if (existing.node_id != entry.node_id) continue;
            if (existing.value.property() != prop) continue;

            // Same target already running: keep its timeline (don't restart on
            // an unrelated rebuild). Only redirect when the target changed.
            if (targetsEqual(existing.value, entry.value)) return;

            const new_entry = interpolateFrom(existing, entry, current_time);
            existing.* = new_entry;
            return;
        }

        try self.entries.append(self.allocator, entry);
    }

    pub fn cancelNode(self: *AnimationRegistry, node_id: NodeId) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].node_id == node_id) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn tick(self: *const AnimationRegistry, current_time: f64) bool {
        for (self.entries.items) |*entry| {
            if (entry.looping) return true;
            const elapsed = current_time - (entry.start_time + entry.delay);
            if (elapsed < entry.duration) return true;
            if (elapsed < 0.0) return true;
        }
        return false;
    }

    pub fn applyAnimatedValues(self: *AnimationRegistry, node: anytype, current_time: f64) void {
        const node_id = node.id orelse return;

        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.node_id != node_id) {
                i += 1;
                continue;
            }
            const keep = applyEntry(entry, &node.style, current_time);
            if (keep) {
                i += 1;
            } else {
                _ = self.entries.swapRemove(i);
            }
        }
    }

    pub fn applyAnimatedValuesToTree(self: *AnimationRegistry, root: anytype, current_time: f64) void {
        applyTreeRecursive(self, root, current_time);
    }

    pub fn applyAnimatedValuesFlat(self: *AnimationRegistry, nodes: anytype, current_time: f64) void {
        for (nodes, 0..) |node, i| {
            if (i + 1 < nodes.len) @prefetch(nodes[i + 1], .{});
            self.applyAnimatedValues(node, current_time);
        }
    }

    pub fn hasLayoutAnimations(self: *const AnimationRegistry) bool {
        _ = self;
        return false;
    }
};

fn applyTreeRecursive(registry: *AnimationRegistry, node: anytype, current_time: f64) void {
    registry.applyAnimatedValues(node, current_time);
    for (node.children.items) |child| {
        applyTreeRecursive(registry, child, current_time);
    }
}

fn interpolateFrom(
    existing: *const AnimationEntry,
    new_entry: AnimationEntry,
    current_time: f64,
) AnimationEntry {
    var result = new_entry;
    const t = computeT(existing, current_time) orelse return result;

    result.value = switch (existing.value) {
        .background_color => |a| .{ .background_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.background_color.to,
        } },
        .hover_color => |a| .{ .hover_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.hover_color.to,
        } },
        .text_color => |a| .{ .text_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.text_color.to,
        } },
        .border_color => |a| .{ .border_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.border_color.to,
        } },
        .outline_color => |a| .{ .outline_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.outline_color.to,
        } },
        .shadow_color => |a| .{ .shadow_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.shadow_color.to,
        } },
        .text_decoration_color => |a| .{ .text_decoration_color = .{
            .from = lerpColor(a.from, a.to, t),
            .to = new_entry.value.text_decoration_color.to,
        } },
        .opacity => |a| .{ .opacity = .{
            .from = lerpF(a.from, a.to, t),
            .to = new_entry.value.opacity.to,
        } },
        .shadow_blur => |a| .{ .shadow_blur = .{
            .from = lerpF(a.from, a.to, t),
            .to = new_entry.value.shadow_blur.to,
        } },
        .shadow_offset => |a| .{ .shadow_offset = .{
            .from = lerpVec2(a.from, a.to, t),
            .to = new_entry.value.shadow_offset.to,
        } },
        .corner_radius => |a| .{ .corner_radius = .{
            .from = lerpRadii(a.from, a.to, t),
            .to = new_entry.value.corner_radius.to,
        } },
        .blur => |a| .{ .blur = .{
            .from = lerpF(a.from, a.to, t),
            .to = new_entry.value.blur.to,
        } },
        .backdrop_blur => |a| .{ .backdrop_blur = .{
            .from = lerpF(a.from, a.to, t),
            .to = new_entry.value.backdrop_blur.to,
        } },
        .translate => |a| .{ .translate = .{
            .from = lerpVec2(a.from, a.to, t),
            .to = new_entry.value.translate.to,
        } },
        .scale => |a| .{ .scale = .{
            .from = lerpF(a.from, a.to, t),
            .to = new_entry.value.scale.to,
        } },
        .rotate => |a| .{ .rotate = .{
            .from = lerpF(a.from, a.to, t),
            .to = new_entry.value.rotate.to,
        } },
    };
    return result;
}
