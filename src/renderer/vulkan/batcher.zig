const std = @import("std");
const vk = @import("../../vk.zig");
const Instance = @import("vertex.zig").Instance;
const assets = @import("../../assets.zig");
const EFFECT_BACKDROP_BLUR = assets.EFFECT_BACKDROP_BLUR;
const EFFECT_ELEMENT_BLUR = assets.EFFECT_ELEMENT_BLUR;
const EFFECT_SDF_ROUNDED = assets.EFFECT_SDF_ROUNDED;
const EFFECT_NOISE_DITHER = assets.EFFECT_NOISE_DITHER;
const EFFECT_DECORATION_LINE = assets.EFFECT_DECORATION_LINE;
const NO_TEXTURE = assets.NO_TEXTURE;

pub const DECORATION_MODE_WAVY: f32 = 0.0;
pub const DECORATION_MODE_DOTTED: f32 = 1.0;
pub const DECORATION_MODE_DASHED: f32 = 2.0;

/// Byte order matches GLSL unpackUnorm4x8 (R in LSB).
pub fn packColor(c: [4]f32) u32 {
    const r: u32 = @intFromFloat(@max(0.0, @min(255.0, c[0] * 255.0)));
    const g: u32 = @intFromFloat(@max(0.0, @min(255.0, c[1] * 255.0)));
    const b: u32 = @intFromFloat(@max(0.0, @min(255.0, c[2] * 255.0)));
    const a: u32 = @intFromFloat(@max(0.0, @min(255.0, c[3] * 255.0)));
    return (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24);
}

pub const LayerData = struct {
    instances: std.ArrayList(Instance),
    commands: std.ArrayList(DrawCommand),
    has_blur: bool,

    pub fn init() LayerData {
        return LayerData{
            .instances = std.ArrayList(Instance).empty,
            .commands = std.ArrayList(DrawCommand).empty,
            .has_blur = false,
        };
    }

    pub fn deinit(self: *LayerData, allocator: std.mem.Allocator) void {
        self.instances.deinit(allocator);
        self.commands.deinit(allocator);
    }
};

pub const DrawCommand = struct {
    instance_count: u32,
    instance_offset: u32,
    scissor: vk.Rect2D,
    params: [4]f32,
    uses_video_pipeline: bool = false,
    video_descriptor_set: vk.DescriptorSet = .null_handle,
};

pub const LayerEntry = struct {
    z: i32,
    data: LayerData,
};

pub const QuadProperties = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    uv_min: [2]f32 = .{ 0.0, 0.0 },
    uv_max: [2]f32 = .{ 1.0, 1.0 },
    color: [4]f32,
    tex_index: u32,
    effect_flags: u32 = 0,
    corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    outline_widths: [4]f32 = .{ 0, 0, 0, 0 },
    sdf_params: [4]f32 = .{ 0, 0, 0, 0 },
    border_colors: [4]u32 = .{ 0, 0, 0, 0 },
    outline_colors: [4]u32 = .{ 0, 0, 0, 0 },
    command_params: [4]f32 = .{ 0, 0, 0, 0 },
    noise: f32 = 0,
    video_descriptor_set: ?vk.DescriptorSet = null,
    expansion: f32 = 0.0,
    // CW radians around quad centre. Verts rotated CPU-side; UVs stay axis-aligned for SDF.
    rotation: f32 = 0.0,
};

pub const RoundedRectStyle = struct {
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    softness: f32 = 1.0,

    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    border_colors: [4]u32 = .{ 0, 0, 0, 0 },

    outline_widths: [4]f32 = .{ 0, 0, 0, 0 },
    outline_colors: [4]u32 = .{ 0, 0, 0, 0 },

    backdrop_blur: f32 = 0,
    element_blur: f32 = 0,
    noise: f32 = 0,
};

pub const QuadBatcher = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayList(LayerEntry),
    current_layer: ?*LayerData,

    current_scissor: vk.Rect2D,
    current_round_clip_rect: [4]f32,
    current_round_clip_radii: [4]f32,
    current_params: [4]f32,
    current_uses_video_pipeline: bool,
    current_video_descriptor_set: vk.DescriptorSet,
    current_z: i32 = 0,
    extent: vk.Extent2D,

    scissor_stack: std.ArrayList(vk.Rect2D),
    round_clip_rect_stack: std.ArrayList([4]f32),
    round_clip_radii_stack: std.ArrayList([4]f32),

    const LayerSearchResult = struct {
        index: usize,
        found: bool,
    };

    pub fn init(allocator: std.mem.Allocator, extent: vk.Extent2D) !QuadBatcher {
        var stack = std.ArrayList(vk.Rect2D).empty;
        const root_scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        try stack.append(allocator, root_scissor);

        var round_rect_stack = std.ArrayList([4]f32).empty;
        var round_radii_stack = std.ArrayList([4]f32).empty;
        const root_round_rect: [4]f32 = .{ 0.0, 0.0, @floatFromInt(extent.width), @floatFromInt(extent.height) };
        const zero_radii: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
        try round_rect_stack.append(allocator, root_round_rect);
        errdefer round_rect_stack.deinit(allocator);
        try round_radii_stack.append(allocator, zero_radii);
        errdefer round_radii_stack.deinit(allocator);

        var self = QuadBatcher{
            .allocator = allocator,
            .layers = std.ArrayList(LayerEntry).empty,
            .current_layer = null,
            .current_scissor = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .current_round_clip_rect = root_round_rect,
            .current_round_clip_radii = zero_radii,
            .extent = extent,
            .current_uses_video_pipeline = false,
            .current_video_descriptor_set = .null_handle,
            .current_z = 0,
            .scissor_stack = stack,
            .round_clip_rect_stack = round_rect_stack,
            .round_clip_radii_stack = round_radii_stack,
            .current_params = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
        };
        try self.layers.append(allocator, .{ .z = 0, .data = LayerData.init() });
        self.current_layer = &self.layers.items[0].data;
        return self;
    }

    fn hasAnyRadius(radii: [4]f32) bool {
        return radii[0] > 0 or radii[1] > 0 or radii[2] > 0 or radii[3] > 0;
    }

    fn findLayerIndex(self: *const QuadBatcher, z: i32) LayerSearchResult {
        var low: usize = 0;
        var high: usize = self.layers.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.layers.items[mid].z < z) low = mid + 1 else high = mid;
        }
        const found = low < self.layers.items.len and self.layers.items[low].z == z;
        return .{ .index = low, .found = found };
    }

    pub fn setZIndex(self: *QuadBatcher, z: i32) !void {
        if (self.current_z == z) return;
        try self.finalizeCurrentCommand();
        const search = self.findLayerIndex(z);
        if (!search.found)
            try self.layers.insert(self.allocator, search.index, .{ .z = z, .data = LayerData.init() });
        self.current_z = z;
        self.current_layer = &self.layers.items[search.index].data;
    }

    pub fn pushScissor(self: *QuadBatcher, x: f32, y: f32, width: f32, height: f32, round_radii: [4]f32) !void {
        try self.finalizeCurrentCommand();

        const req_min_x: i32 = @intFromFloat(@round(x));
        const req_min_y: i32 = @intFromFloat(@round(y));
        const req_max_x: i32 = @intFromFloat(@round(x + @max(0.0, width)));
        const req_max_y: i32 = @intFromFloat(@round(y + @max(0.0, height)));

        const parent = self.scissor_stack.items[self.scissor_stack.items.len - 1];
        const p_min_x = parent.offset.x;
        const p_min_y = parent.offset.y;
        const p_max_x = p_min_x + @as(i32, @intCast(parent.extent.width));
        const p_max_y = p_min_y + @as(i32, @intCast(parent.extent.height));
        const i_min_x = @max(p_min_x, req_min_x);
        const i_min_y = @max(p_min_y, req_min_y);
        const i_max_x = @min(p_max_x, req_max_x);
        const i_max_y = @min(p_max_y, req_max_y);
        const intersected = vk.Rect2D{
            .offset = .{ .x = i_min_x, .y = i_min_y },
            .extent = .{
                .width = @intCast(@max(0, i_max_x - i_min_x)),
                .height = @intCast(@max(0, i_max_y - i_min_y)),
            },
        };

        var next_round_rect = self.round_clip_rect_stack.items[self.round_clip_rect_stack.items.len - 1];
        var next_round_radii = self.round_clip_radii_stack.items[self.round_clip_radii_stack.items.len - 1];
        if (hasAnyRadius(round_radii) and width > 0.0 and height > 0.0) {
            next_round_rect = .{ x, y, x + width, y + height };
            next_round_radii = .{
                @max(0.0, round_radii[0]),
                @max(0.0, round_radii[1]),
                @max(0.0, round_radii[2]),
                @max(0.0, round_radii[3]),
            };
        }

        try self.scissor_stack.append(self.allocator, intersected);
        errdefer _ = self.scissor_stack.pop();
        try self.round_clip_rect_stack.append(self.allocator, next_round_rect);
        errdefer _ = self.round_clip_rect_stack.pop();
        try self.round_clip_radii_stack.append(self.allocator, next_round_radii);
        self.current_scissor = intersected;
        self.current_round_clip_rect = next_round_rect;
        self.current_round_clip_radii = next_round_radii;
    }

    pub fn popScissor(self: *QuadBatcher) !void {
        if (self.scissor_stack.items.len <= 1) return;

        try self.finalizeCurrentCommand();

        _ = self.scissor_stack.pop();
        _ = self.round_clip_rect_stack.pop();
        _ = self.round_clip_radii_stack.pop();
        self.current_scissor = self.scissor_stack.items[self.scissor_stack.items.len - 1];
        self.current_round_clip_rect = self.round_clip_rect_stack.items[self.round_clip_rect_stack.items.len - 1];
        self.current_round_clip_radii = self.round_clip_radii_stack.items[self.round_clip_radii_stack.items.len - 1];
    }

    fn getCurrentClip(self: *const QuadBatcher) [4]f32 {
        const sc = self.current_scissor;
        return .{
            @floatFromInt(sc.offset.x),
            @floatFromInt(sc.offset.y),
            @floatFromInt(sc.offset.x + @as(i32, @intCast(sc.extent.width))),
            @floatFromInt(sc.offset.y + @as(i32, @intCast(sc.extent.height))),
        };
    }

    pub fn finalizeCurrentCommand(self: *QuadBatcher) !void {
        var layer = self.current_layer orelse return;
        const last_offset = if (layer.commands.items.len > 0)
            layer.commands.items[layer.commands.items.len - 1].instance_offset +
                layer.commands.items[layer.commands.items.len - 1].instance_count
        else
            0;
        const current_count = @as(u32, @intCast(layer.instances.items.len)) - last_offset;
        if (current_count > 0) {
            try layer.commands.append(self.allocator, DrawCommand{
                .instance_count = current_count,
                .instance_offset = last_offset,
                .scissor = self.current_scissor,
                .params = self.current_params,
                .uses_video_pipeline = self.current_uses_video_pipeline,
                .video_descriptor_set = self.current_video_descriptor_set,
            });
        }
    }

    pub fn setParams(self: *QuadBatcher, params: [4]f32) !void {
        if (std.mem.eql(f32, &self.current_params, &params)) return;
        try self.finalizeCurrentCommand();
        self.current_params = params;
    }

    fn addGenericQuad(self: *QuadBatcher, props: QuadProperties) !void {
        const is_backdrop_blur = (props.effect_flags & EFFECT_BACKDROP_BLUR) != 0;
        const uses_video_pipeline = props.video_descriptor_set != null;
        const video_descriptor_set = props.video_descriptor_set orelse .null_handle;

        if (uses_video_pipeline != self.current_uses_video_pipeline or
            (uses_video_pipeline and video_descriptor_set != self.current_video_descriptor_set))
        {
            try self.finalizeCurrentCommand();
            self.current_uses_video_pipeline = uses_video_pipeline;
            self.current_video_descriptor_set = video_descriptor_set;
        }

        if (is_backdrop_blur) try self.finalizeCurrentCommand();

        try self.setParams(props.command_params);

        var layer = self.current_layer orelse unreachable;
        if (is_backdrop_blur) layer.has_blur = true;

        const clip = self.getCurrentClip();
        const round_clip_rect = self.current_round_clip_rect;
        const round_clip_radii = self.current_round_clip_radii;

        // Decoration quads stash logical width/height in corner_radii; don't
        // let that flip them into the SDF_ROUNDED branch.
        const skip_auto_sdf = (props.effect_flags & EFFECT_DECORATION_LINE) != 0;
        const needs_sdf = !skip_auto_sdf and (
            props.corner_radii[0] > 0 or props.corner_radii[1] > 0 or
            props.corner_radii[2] > 0 or props.corner_radii[3] > 0 or
            props.border_widths[0] > 0 or props.border_widths[1] > 0 or
            props.border_widths[2] > 0 or props.border_widths[3] > 0 or
            props.outline_widths[0] > 0 or props.outline_widths[1] > 0 or
            props.outline_widths[2] > 0 or props.outline_widths[3] > 0);
        const combined_id = (if (needs_sdf) props.effect_flags | EFFECT_SDF_ROUNDED else props.effect_flags) |
            (props.tex_index & 0xFFFF);

        const ex = props.x - props.expansion * 0.5;
        const ey = props.y - props.expansion * 0.5;
        const ew = props.width + props.expansion;
        const eh = props.height + props.expansion;

        const uv_exp_u: f32 = if (props.expansion > 0.0 and props.tex_index != NO_TEXTURE and props.width > 0.0)
            (props.expansion * 0.5) / props.width
        else
            0.0;
        const uv_exp_v: f32 = if (props.expansion > 0.0 and props.tex_index != NO_TEXTURE and props.height > 0.0)
            (props.expansion * 0.5) / props.height
        else
            0.0;

        const base_u0 = props.uv_min[0];
        const base_v0 = props.uv_min[1];
        const base_u1 = props.uv_max[0];
        const base_v1 = props.uv_max[1];
        const du = base_u1 - base_u0;
        const dv = base_v1 - base_v0;

        const uv0: f32 = base_u0 - uv_exp_u * du;
        const vv0: f32 = base_v0 - uv_exp_v * dv;
        const uv1: f32 = base_u1 + uv_exp_u * du;
        const vv1: f32 = base_v1 + uv_exp_v * dv;

        var corners = [4][2]f32{
            .{ ex, ey },
            .{ ex + ew, ey },
            .{ ex + ew, ey + eh },
            .{ ex, ey + eh },
        };

        if (props.rotation != 0.0) {
            const cos_r = @cos(props.rotation);
            const sin_r = @sin(props.rotation);
            const cx = ex + ew * 0.5;
            const cy = ey + eh * 0.5;
            for (&corners) |*c| {
                const dx = c[0] - cx;
                const dy = c[1] - cy;
                c[0] = cx + dx * cos_r - dy * sin_r;
                c[1] = cy + dx * sin_r + dy * cos_r;
            }
        }

        try layer.instances.append(self.allocator, .{
            .corner01 = .{ corners[0][0], corners[0][1], corners[1][0], corners[1][1] },
            .corner23 = .{ corners[2][0], corners[2][1], corners[3][0], corners[3][1] },
            .uv_rect = .{ uv0, vv0, uv1, vv1 },
            .color = props.color,
            .tex_id = combined_id,
            .corner_radii = props.corner_radii,
            .clip_rect = clip,
            .clip_round_rect = round_clip_rect,
            .clip_round_radii = round_clip_radii,
            .border_widths = props.border_widths,
            .outline_widths = props.outline_widths,
            .sdf_params = props.sdf_params,
            .border_colors = props.border_colors,
            .outline_colors = props.outline_colors,
            .noise = props.noise,
        });

        if (is_backdrop_blur) try self.finalizeCurrentCommand();
    }

    pub fn addRect(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: [4]f32,
        tex_index: u32,
        effect_flags: u32,
        command_params: [4]f32,
    ) !void {
        const element_blur = if ((effect_flags & EFFECT_ELEMENT_BLUR) != 0) @max(0.0, command_params[1]) else 0.0;
        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .color = color,
            .tex_index = tex_index,
            .effect_flags = effect_flags,
            .command_params = command_params,
            .expansion = element_blur * 2.0,
        });
    }

    pub fn addRectUV(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        color: [4]f32,
        tex_index: u32,
        effect_flags: u32,
        command_params: [4]f32,
        rotation: f32,
    ) !void {
        const element_blur = if ((effect_flags & EFFECT_ELEMENT_BLUR) != 0) @max(0.0, command_params[1]) else 0.0;
        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .uv_min = uv_min,
            .uv_max = uv_max,
            .color = color,
            .tex_index = tex_index,
            .effect_flags = effect_flags,
            .command_params = command_params,
            .expansion = element_blur * 2.0,
            .rotation = rotation,
        });
    }

    pub fn addVideoRectUV(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        color: [4]f32,
        tex_index: u32,
        descriptor_set: vk.DescriptorSet,
        effect_flags: u32,
        command_params: [4]f32,
    ) !void {
        const element_blur = if ((effect_flags & EFFECT_ELEMENT_BLUR) != 0) @max(0.0, command_params[1]) else 0.0;
        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .uv_min = uv_min,
            .uv_max = uv_max,
            .color = color,
            .tex_index = tex_index,
            .effect_flags = effect_flags,
            .command_params = command_params,
            .video_descriptor_set = descriptor_set,
            .expansion = element_blur * 2.0,
        });
    }

    pub fn addRoundedRect(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: [4]f32,
        style: RoundedRectStyle,
        rotation: f32,
    ) !void {
        var effect_flags: u32 = EFFECT_SDF_ROUNDED;
        if (style.backdrop_blur > 0.0) effect_flags |= EFFECT_BACKDROP_BLUR;
        if (style.element_blur > 0.0) effect_flags |= EFFECT_ELEMENT_BLUR;
        if (style.noise > 0.0) effect_flags |= EFFECT_NOISE_DITHER;

        const sm = @max(style.softness, 1.0);
        const max_ow = @max(
            @max(style.outline_widths[0], style.outline_widths[1]),
            @max(style.outline_widths[2], style.outline_widths[3]),
        );
        const sdf_padding = max_ow + sm;
        const expansion = (sdf_padding + style.element_blur) * 2.0;

        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .color = color,
            .tex_index = NO_TEXTURE,
            .effect_flags = effect_flags,
            .corner_radii = style.radii,
            .border_widths = style.border_widths,
            .outline_widths = style.outline_widths,
            .sdf_params = .{ style.softness, width, height, sdf_padding },
            .border_colors = style.border_colors,
            .outline_colors = style.outline_colors,
            .command_params = .{ style.backdrop_blur, style.element_blur, 0.0, 0.0 },
            .noise = style.noise,
            .expansion = expansion,
            .rotation = rotation,
        });
    }

    /// Wavy/dotted/dashed only; solid + double use `addRect` directly.
    pub fn addDecorationLine(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: [4]f32,
        mode: f32,
        period_px: f32,
        amp_px: f32,
        thickness_px: f32,
    ) !void {
        if (width <= 0.0 or height <= 0.0 or color[3] <= 0.0) return;
        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .color = color,
            .tex_index = NO_TEXTURE,
            .effect_flags = EFFECT_DECORATION_LINE,
            .corner_radii = .{ width, height, 0, 0 },
            .sdf_params = .{ mode, period_px, amp_px, thickness_px },
        });
    }

    /// Rotated rounded-rect quad with rounded caps; reuses SDF AA + scissor + blur path.
    pub fn addLine(
        self: *QuadBatcher,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        thickness: f32,
        color: [4]f32,
    ) !void {
        if (thickness <= 0.0 or color[3] <= 0.0) return;
        const dx = x1 - x0;
        const dy = y1 - y0;
        const length = @sqrt(dx * dx + dy * dy);
        if (length <= 0.0001) {
            try self.addPoint((x0 + x1) * 0.5, (y0 + y1) * 0.5, thickness, color);
            return;
        }

        const half_t = thickness * 0.5;
        const cx = (x0 + x1) * 0.5;
        const cy = (y0 + y1) * 0.5;
        const rotation = std.math.atan2(dy, dx);

        const rx = cx - length * 0.5;
        const ry = cy - half_t;
        const radii: [4]f32 = .{ half_t, half_t, half_t, half_t };

        try self.addRoundedRect(
            rx,
            ry,
            length,
            thickness,
            color,
            .{ .radii = radii, .softness = 1.0 },
            rotation,
        );
    }

    pub fn addPoint(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        size: f32,
        color: [4]f32,
    ) !void {
        if (size <= 0.0 or color[3] <= 0.0) return;
        const r = size * 0.5;
        const radii: [4]f32 = .{ r, r, r, r };
        try self.addRoundedRect(
            x - r,
            y - r,
            size,
            size,
            color,
            .{ .radii = radii, .softness = 1.0 },
            0.0,
        );
    }

    pub fn addPolyline(
        self: *QuadBatcher,
        points: []const [2]f32,
        thickness: f32,
        color: [4]f32,
    ) !void {
        if (points.len < 2) return;
        var i: usize = 1;
        while (i < points.len) : (i += 1) {
            try self.addLine(
                points[i - 1][0],
                points[i - 1][1],
                points[i][0],
                points[i][1],
                thickness,
                color,
            );
        }
    }

    pub fn addText(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        atlas_id: u32,
        weight: f32,
        color: [4]f32,
    ) !void {
        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .color = color,
            .tex_index = atlas_id,
            .effect_flags = assets.EFFECT_MSDF_TEXT,
            // MSDF weight stored in corner_radii.x; shader reads it there for MSDF glyphs.
            .corner_radii = .{ weight, 0, 0, 0 },
        });
    }

    pub fn addGlyphQuad(
        self: *QuadBatcher,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        color: [4]f32,
        combined_id: u32,
        corner_radii: [4]f32,
    ) !void {
        const effect_flags = combined_id & 0xFFFF0000;
        const tex_index = combined_id & 0x0000FFFF;
        try self.addGenericQuad(.{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .uv_min = uv_min,
            .uv_max = uv_max,
            .color = color,
            .tex_index = tex_index,
            .effect_flags = effect_flags,
            .corner_radii = corner_radii,
        });
    }

    pub fn clear(self: *QuadBatcher, current_extent: vk.Extent2D) !void {
        for (self.layers.items) |*entry| {
            entry.data.instances.clearRetainingCapacity();
            entry.data.commands.clearRetainingCapacity();
            entry.data.has_blur = false;
        }
        self.extent = current_extent;
        self.scissor_stack.clearRetainingCapacity();
        self.round_clip_rect_stack.clearRetainingCapacity();
        self.round_clip_radii_stack.clearRetainingCapacity();
        const root_scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = current_extent };
        try self.scissor_stack.append(self.allocator, root_scissor);
        const root_round_rect: [4]f32 = .{ 0.0, 0.0, @floatFromInt(current_extent.width), @floatFromInt(current_extent.height) };
        const zero_radii: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
        try self.round_clip_rect_stack.append(self.allocator, root_round_rect);
        try self.round_clip_radii_stack.append(self.allocator, zero_radii);
        self.current_scissor = root_scissor;
        self.current_round_clip_rect = root_round_rect;
        self.current_round_clip_radii = zero_radii;
        self.current_params = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
        self.current_uses_video_pipeline = false;
        self.current_video_descriptor_set = .null_handle;
        self.current_z = 0;
        const search = self.findLayerIndex(0);
        if (search.found) {
            self.current_layer = &self.layers.items[search.index].data;
        } else {
            try self.layers.insert(self.allocator, 0, .{ .z = 0, .data = LayerData.init() });
            self.current_layer = &self.layers.items[0].data;
        }
    }

    pub fn resetScissorToRoot(self: *QuadBatcher) !void {
        try self.finalizeCurrentCommand();

        const root_scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        self.scissor_stack.clearRetainingCapacity();
        self.round_clip_rect_stack.clearRetainingCapacity();
        self.round_clip_radii_stack.clearRetainingCapacity();
        try self.scissor_stack.append(self.allocator, root_scissor);
        const root_round_rect: [4]f32 = .{ 0.0, 0.0, @floatFromInt(self.extent.width), @floatFromInt(self.extent.height) };
        const zero_radii: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
        try self.round_clip_rect_stack.append(self.allocator, root_round_rect);
        try self.round_clip_radii_stack.append(self.allocator, zero_radii);
        self.current_scissor = root_scissor;
        self.current_round_clip_rect = root_round_rect;
        self.current_round_clip_radii = zero_radii;
        self.current_uses_video_pipeline = false;
        self.current_video_descriptor_set = .null_handle;
    }

    pub fn deinit(self: *QuadBatcher) void {
        for (self.layers.items) |*entry| entry.data.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.scissor_stack.deinit(self.allocator);
        self.round_clip_rect_stack.deinit(self.allocator);
        self.round_clip_radii_stack.deinit(self.allocator);
    }
};
