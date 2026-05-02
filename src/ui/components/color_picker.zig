const std = @import("std");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const Canvas = @import("../../renderer/canvas.zig").Canvas;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;
const color_math = @import("../color.zig");
const deriveChildId = @import("id.zig").deriveChildId;

pub fn ColorPickerContext(comptime MessageT: type) type {
    return struct {
        base_id: types.NodeId,
        hsv: [3]f32,
        alpha: f32 = 1.0,

        plane_canvas: *Canvas,

        on_sv_change: *const fn ([2]f32, ?*const anyopaque) MessageT,
        on_hue_change: *const fn (f32, ?*const anyopaque) MessageT,
        userdata: ?*const anyopaque = null,
    };
}

pub const ColorPickerDescriptor = struct {
    container_style: layout.Style = .{},
    plane_size: f32 = 200.0,
    hue_slider_style: layout.Style = .{},
    hex_font: ?*FontData = null,
    show_readout: bool = true,
    readout_background: ?[4]f32 = null,
};

fn PlanePayload(comptime MessageT: type) type {
    return struct {
        cb: *const fn ([2]f32, ?*const anyopaque) MessageT,
        data: ?*const anyopaque,
    };
}

fn planeInteractionHandler(comptime MessageT: type) *const fn (?*const anyopaque, types.EventLayoutSnapshot, types.EventData) ?MessageT {
    return struct {
        fn handle(userdata: ?*const anyopaque, layout_snap: types.EventLayoutSnapshot, event_data: types.EventData) ?MessageT {
            const w = layout_snap.width;
            const h = layout_snap.height;
            if (w <= 0.0 or h <= 0.0) return null;
            if (userdata == null) return null;

            const payload: *const PlanePayload(MessageT) = @ptrCast(@alignCast(userdata.?));

            switch (event_data) {
                .mouse => |m| {
                    const local_x = std.math.clamp(m.x - layout_snap.x, 0.0, w);
                    const local_y = std.math.clamp(m.y - layout_snap.y, 0.0, h);
                    return payload.cb(.{ local_x / w, local_y / h }, payload.data);
                },
                .drag => |d| {
                    const local_x = std.math.clamp(d.x - layout_snap.x, 0.0, w);
                    const local_y = std.math.clamp(d.y - layout_snap.y, 0.0, h);
                    return payload.cb(.{ local_x / w, local_y / h }, payload.data);
                },
                else => return null,
            }
        }
    }.handle;
}

pub fn updatePlaneTexture(canvas: *Canvas, hue: f32) void {
    if (canvas.width == 0 or canvas.height == 0) return;

    const pixels = canvas.getRawPixels();
    const w = canvas.width;
    const h = canvas.height;

    const w_denom = if (w > 1) @as(f32, @floatFromInt(w - 1)) else 1.0;
    const h_denom = if (h > 1) @as(f32, @floatFromInt(h - 1)) else 1.0;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const y_norm = @as(f32, @floatFromInt(y)) / h_denom;
        const v = 1.0 - y_norm;

        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const s = @as(f32, @floatFromInt(x)) / w_denom;
            const rgb = color_math.hsvToRgb(hue, s, v);

            const idx = (y * w + x) * 4;
            pixels[idx] = @intFromFloat(std.math.clamp(rgb[0] * 255.0, 0.0, 255.0));
            pixels[idx + 1] = @intFromFloat(std.math.clamp(rgb[1] * 255.0, 0.0, 255.0));
            pixels[idx + 2] = @intFromFloat(std.math.clamp(rgb[2] * 255.0, 0.0, 255.0));
            pixels[idx + 3] = 255;
        }
    }

    canvas.markDirty();
}

pub fn build(
    comptime MessageT: type,
    ctx: *UIContext(MessageT),
    logic: ColorPickerContext(MessageT),
    visuals: ColorPickerDescriptor,
) !*Node(MessageT) {
    const alloc = ctx.build_arena.allocator();
    const tokens = ctx.active_theme.tokens;
    const plane_size = @max(1.0, visuals.plane_size);

    const Payload = PlanePayload(MessageT);
    const drag_payload = try ctx.gpa.create(Payload);
    drag_payload.* = .{ .cb = logic.on_sv_change, .data = logic.userdata };
    const click_payload = try ctx.gpa.create(Payload);
    click_payload.* = .{ .cb = logic.on_sv_change, .data = logic.userdata };
    const destroy = @import("../node.zig").destroyOwnedEventUserdata(Payload);
    const plane_events = try alloc.dupe(types.EventBinding(MessageT), &.{
        .{ .event = .drag, .userdata = drag_payload, .destroy_userdata = destroy, .handler = planeInteractionHandler(MessageT) },
        .{ .event = .click, .userdata = click_payload, .destroy_userdata = destroy, .handler = planeInteractionHandler(MessageT) },
    });

    const cursor_x = std.math.clamp(logic.hsv[1], 0.0, 1.0) * plane_size;
    const cursor_y = (1.0 - std.math.clamp(logic.hsv[2], 0.0, 1.0)) * plane_size;

    const inner_ring = try ctx.div(.{
        .id = deriveChildId(logic.base_id, "sv_cursor_inner"),
        .style = .{
            .position = .absolute,
            .left = -2.0,
            .top = -2.0,
            .width = .{ .exact = 8.0 },
            .height = .{ .exact = 8.0 },
            .background_color = .{ 0, 0, 0, 0 },
            .border = layout.Border.all(1.0, .{ 0.0, 0.0, 0.0, 0.65 }),
            .corner_radius = layout.CornerRadius.all(4.0),
            .pointer_events = .none,
        },
    });
    const plane_cursor = try ctx.div(.{
        .id = deriveChildId(logic.base_id, "sv_cursor"),
        .style = .{
            .position = .absolute,
            .left = cursor_x - 6.0,
            .top = cursor_y - 6.0,
            .width = .{ .exact = 12.0 },
            .height = .{ .exact = 12.0 },
            .background_color = .{ 0.0, 0.0, 0.0, 0.0 },
            .border = layout.Border.all(2.0, .{ 1.0, 1.0, 1.0, 1.0 }),
            .corner_radius = layout.CornerRadius.all(6.0),
            .pointer_events = .none,
        },
        .children = &.{inner_ring},
    });

    const sv_plane = try ctx.canvas(.{
        .id = deriveChildId(logic.base_id, "sv_plane"),
        .style = .{
            .position = .relative,
            .width = .{ .exact = plane_size },
            .height = .{ .exact = plane_size },
            .cursor = .crosshair,
            .corner_radius = layout.CornerRadius.all(6.0),
        },
        .target = logic.plane_canvas,
        .events = plane_events,
        .children = &.{plane_cursor},
    });

    const slider_mod = @import("slider.zig");
    const slider_hue = std.math.clamp(logic.hsv[0], 0.0, 360.0);
    const hue_rgb = color_math.hsvToRgb(slider_hue, 1.0, 1.0);

    var track_style = visuals.hue_slider_style;
    track_style.width = .{ .exact = plane_size };
    if (track_style.margin.top == 0.0) track_style.margin.top = 10.0;

    const hue_slider = try slider_mod.build(MessageT, ctx, .{
        .base_id = deriveChildId(logic.base_id, "hue_slider"),
        .value = slider_hue / 360.0,
        .on_change = logic.on_hue_change,
        .userdata = logic.userdata,
        .track = .{ .style = track_style },
        .fill = .{ .style = .{ .background_color = .{ hue_rgb[0], hue_rgb[1], hue_rgb[2], 1.0 } } },
    });

    const rgb = color_math.hsvToRgb(logic.hsv[0], logic.hsv[1], logic.hsv[2]);

    const readout_node: ?*Node(MessageT) = blk: {
        if (!visuals.show_readout) break :blk null;
        const font = visuals.hex_font orelse break :blk null;

        const hex_value = try color_math.rgbToHex(alloc, rgb[0], rgb[1], rgb[2]);

        const r_byte: u8 = @intFromFloat(std.math.clamp(rgb[0] * 255.0, 0.0, 255.0));
        const g_byte: u8 = @intFromFloat(std.math.clamp(rgb[1] * 255.0, 0.0, 255.0));
        const b_byte: u8 = @intFromFloat(std.math.clamp(rgb[2] * 255.0, 0.0, 255.0));
        const rgb_buf = try alloc.alloc(u8, 32);
        const rgb_text = try std.fmt.bufPrint(rgb_buf, "{d}, {d}, {d}", .{ r_byte, g_byte, b_byte });

        const lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        const readable_text: [4]f32 = if (lum > 0.55)
            .{ 0.05, 0.06, 0.08, 1.0 }
        else
            .{ 0.96, 0.97, 1.0, 1.0 };

        const swatch = try ctx.div(.{
            .id = deriveChildId(logic.base_id, "swatch"),
            .style = .{
                .width = .{ .exact = 28.0 },
                .height = .{ .exact = 28.0 },
                .background_color = .{ rgb[0], rgb[1], rgb[2], 1.0 },
                .corner_radius = layout.CornerRadius.all(4.0),
                .border = layout.Border.all(1.0, .{ 1.0, 1.0, 1.0, 0.15 }),
                .pointer_events = .none,
            },
        });

        const hex_text = try ctx.text(.{
            .id = deriveChildId(logic.base_id, "hex_text"),
            .content = hex_value,
            .font = font,
            .style = .{
                .text_color = readable_text,
                .font_size = 13,
                .pointer_events = .none,
            },
        });

        const rgb_text_node = try ctx.text(.{
            .id = deriveChildId(logic.base_id, "rgb_text"),
            .content = rgb_text,
            .font = font,
            .style = .{
                .text_color = .{ readable_text[0], readable_text[1], readable_text[2], readable_text[3] * 0.7 },
                .font_size = 11,
                .pointer_events = .none,
            },
        });

        const text_column = try ctx.div(.{
            .id = deriveChildId(logic.base_id, "readout_text"),
            .style = .{
                .direction = .Column,
                .gap = 2.0,
                .pointer_events = .none,
            },
            .children = &.{ hex_text, rgb_text_node },
        });

        const bg: [4]f32 = visuals.readout_background orelse blk2: {
            const mix: f32 = 0.18;
            break :blk2 .{
                tokens.bg_surface[0] * (1.0 - mix) + rgb[0] * mix,
                tokens.bg_surface[1] * (1.0 - mix) + rgb[1] * mix,
                tokens.bg_surface[2] * (1.0 - mix) + rgb[2] * mix,
                1.0,
            };
        };

        break :blk try ctx.div(.{
            .id = deriveChildId(logic.base_id, "readout"),
            .style = .{
                .direction = .Row,
                .align_items = .Center,
                .gap = 10.0,
                .padding = .{ .top = 8, .bottom = 8, .left = 10, .right = 10 },
                .margin = .{ .top = 10 },
                .width = .{ .exact = plane_size },
                .background_color = bg,
                .corner_radius = layout.CornerRadius.all(6.0),
                .pointer_events = .none,
            },
            .children = &.{ swatch, text_column },
        });
    };

    var container_style = visuals.container_style;
    container_style.direction = .Column;

    var children = std.ArrayList(?*Node(MessageT)).empty;
    defer children.deinit(alloc);
    try children.append(alloc, sv_plane);
    try children.append(alloc, hue_slider);
    if (readout_node) |r| try children.append(alloc, r);

    return ctx.div(.{
        .id = logic.base_id,
        .style = container_style,
        .children = children.items,
    });
}
