const std = @import("std");
pub const lib = @import("ramiel");
const glfw = @import("glfw");
const filters = @import("filters.zig");
const EditorState = @import("editor_state.zig").EditorState;

pub const Canvas = lib.Canvas;
pub const FontData = lib.FontData;
pub const PixelBuffer = lib.renderer.PixelBuffer;
pub const UpdateAction = lib.UpdateAction;
pub const WindowContext = lib.WindowContext;
pub const Color = lib.Color;

pub const AppMessage = union(enum) {
    rebuild_requested: void,
    open_dialog: void,
    file_selected: void,
    commit_preview: void,
    discard_preview: void,
    filter_done: void,
    palette_query_changed: void,
    palette_key_down: void,
    execute_palette_command: void,
    autocomplete_palette: void,
    close_palette: void,
    palette_consume_click: void,
    toggle_help: void,
    execute_active_filter: void,
    param_changed: struct { index: usize, value: f32 },
    palette_add: void,
    palette_remove: void,
    palette_select: usize,
    picker_hue: f32,
    picker_sv: [2]f32,
    mask_type_changed: usize,
    canvas_scrolled: void,
    canvas_pointer_move: void,
};

const T = lib.For(AppMessage);
pub const AppUIContext = T.UIContext;
pub const AppNode = T.Node;
pub const AppInteractionMessage = T.InteractionMessage;
pub const App = lib.Application(AppState, AppMessage);

pub const NodeIds = lib.declareIds(.{"palette_input"}){};

pub const ROOT_PADDING: f32 = 16.0;
pub const ROOT_GAP: f32 = 8.0;
pub const PAN_BUTTON: i32 = 2;
pub const FILE_FILTERS: [:0]const u8 = "png,jpg,jpeg,bmp,tga,gif";
pub const MAX_DYNAMIC_PARAMS = 16;

pub const ALL_COMMANDS = [_][]const u8{
    "invert",
    "dilate",
    "erode",
    "subtract",
    "glitch",
    "kuwahara",
    "dither",
    "sort",
    "restore",
    "aberration",
    "mask",
    "commit",
    "discard",
    "open",
    "saveas",
};

pub const Dispatch = struct {
    fn genParam(comptime idx: usize) fn (f32, ?*const anyopaque) AppMessage {
        return struct {
            fn handle(v: f32, _: ?*const anyopaque) AppMessage {
                return .{ .param_changed = .{ .index = idx, .value = v } };
            }
        }.handle;
    }

    fn genRadio(comptime idx: usize) fn (usize, ?*const anyopaque) AppMessage {
        return struct {
            fn handle(v: usize, _: ?*const anyopaque) AppMessage {
                return .{ .param_changed = .{ .index = idx, .value = @floatFromInt(v) } };
            }
        }.handle;
    }

    const param_funcs = blk: {
        var funcs: [MAX_DYNAMIC_PARAMS]*const fn (f32, ?*const anyopaque) AppMessage = undefined;
        for (&funcs, 0..) |*f, i| f.* = genParam(i);
        break :blk funcs;
    };

    const radio_funcs = blk: {
        var funcs: [MAX_DYNAMIC_PARAMS]*const fn (usize, ?*const anyopaque) AppMessage = undefined;
        for (&funcs, 0..) |*f, i| f.* = genRadio(i);
        break :blk funcs;
    };

    pub fn pickParamOnChange(index: usize) *const fn (f32, ?*const anyopaque) AppMessage {
        return param_funcs[@min(index, MAX_DYNAMIC_PARAMS - 1)];
    }

    pub fn pickRadioOnChange(index: usize) *const fn (usize, ?*const anyopaque) AppMessage {
        return radio_funcs[@min(index, MAX_DYNAMIC_PARAMS - 1)];
    }

    pub const pickerHue = lib.bindTag(AppMessage, f32, .picker_hue);
    pub const pickerSv = lib.bindTag(AppMessage, [2]f32, .picker_sv);
};

pub const AppState = struct {
    font_data: *FontData = undefined,
    base_canvas: ?*Canvas = null,
    preview_canvas: ?*Canvas = null,
    color_picker_canvas: ?*Canvas = null,
    worker: ?*anyopaque = null,
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    zoom: f32 = 1.0,
    is_panning: bool = false,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    canvas_screen_x: f32 = ROOT_PADDING,
    canvas_screen_y: f32 = ROOT_PADDING,
    canvas_screen_w: f32 = 1.0,
    canvas_screen_h: f32 = 1.0,
    brush_radius: f32 = 20.0,
    brush_color: [4]u8 = .{ 255, 255, 255, 255 },
    brush_stroke_active: bool = false,
    editor: EditorState = undefined,
};

pub fn isMaskFilter(kind: ?filters.FilterKind) bool {
    const k = kind orelse return false;
    return switch (k) {
        .mask_luma, .mask_r, .mask_g, .mask_b, .mask_contrast, .mask_edge => true,
        else => false,
    };
}

pub fn maskFilterToIndex(kind: filters.FilterKind) usize {
    return switch (kind) {
        .mask_luma => 0,
        .mask_r => 1,
        .mask_g => 2,
        .mask_b => 3,
        .mask_edge => 4,
        .mask_contrast => 5,
        else => 0,
    };
}

pub fn maskIndexToFilter(index: usize) filters.FilterKind {
    return switch (index) {
        0 => .mask_luma,
        1 => .mask_r,
        2 => .mask_g,
        3 => .mask_b,
        4 => .mask_edge,
        5 => .mask_contrast,
        else => .mask_luma,
    };
}

pub fn makeParamNodeId(kind: filters.FilterKind, param_idx: usize, salt: u8) lib.NodeId {
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(std.mem.asBytes(&kind));
    hasher.update(std.mem.asBytes(&param_idx));
    hasher.update(&.{salt});
    return hasher.final();
}
