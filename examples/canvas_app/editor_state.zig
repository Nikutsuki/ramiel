const std = @import("std");
const PixelBuffer = @import("ramiel").renderer.PixelBuffer;
const FilterKind = @import("filters.zig").FilterKind;

pub const EditorState = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList(PixelBuffer),
    base_buffer: ?PixelBuffer = null,
    preview_buffer: ?PixelBuffer = null,
    active_mask: ?[]u8 = null,
    palette_open: bool = false,
    palette_query: std.ArrayList(u8),
    status_text: std.ArrayList(u8),
    show_help: bool = false,
    active_filter: ?FilterKind = null,
    filter_params: [64]f32 = [_]f32{0.0} ** 64,
    dither_palette_hsv: std.ArrayList([3]f32),
    dither_selected_color: usize = 0,

    pub fn init(allocator: std.mem.Allocator) EditorState {
        var status = std.ArrayList(u8).empty;
        status.appendSlice(allocator, "Ready") catch {};
        var palette = std.ArrayList([3]f32).empty;
        palette.append(allocator, .{ 0.0, 0.0, 0.0 }) catch {};
        palette.append(allocator, .{ 0.0, 0.0, 1.0 }) catch {};

        return .{
            .allocator = allocator,
            .history = .empty,
            .base_buffer = null,
            .preview_buffer = null,
            .active_mask = null,
            .palette_open = false,
            .palette_query = .empty,
            .status_text = status,
            .show_help = false,
            .active_filter = null,
            .filter_params = [_]f32{0.0} ** 64,
            .dither_palette_hsv = palette,
            .dither_selected_color = 0,
        };
    }

    pub fn setStatus(self: *EditorState, comptime fmt: []const u8, args: anytype) void {
        self.status_text.clearRetainingCapacity();
        const rendered = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(rendered);
        self.status_text.appendSlice(self.allocator, rendered) catch {};
    }

    pub fn setStatusText(self: *EditorState, text: []const u8) void {
        self.status_text.clearRetainingCapacity();
        self.status_text.appendSlice(self.allocator, text) catch {};
    }

    pub fn setBaseBuffer(self: *EditorState, buffer: PixelBuffer) void {
        if (self.base_buffer) |*existing| existing.deinit();
        self.base_buffer = buffer;
    }

    pub fn setPreviewBuffer(self: *EditorState, buffer: PixelBuffer) void {
        if (self.preview_buffer) |*existing| existing.deinit();
        self.preview_buffer = buffer;
    }

    pub fn commitPreview(self: *EditorState) !void {
        const preview = self.preview_buffer orelse return;
        if (self.base_buffer) |base| {
            try self.history.append(self.allocator, try base.clone());
        }

        if (self.base_buffer) |*base| base.deinit();
        self.base_buffer = try preview.clone();

        if (self.active_mask) |mask| {
            self.allocator.free(mask);
            self.active_mask = null;
        }
    }

    pub fn discardPreview(self: *EditorState) !void {
        if (self.preview_buffer) |*preview| preview.deinit();
        if (self.base_buffer) |base| {
            self.preview_buffer = try base.clone();
        } else {
            self.preview_buffer = null;
        }

        if (self.active_mask) |mask| {
            self.allocator.free(mask);
            self.active_mask = null;
        }
    }

    pub fn undoCommit(self: *EditorState) !bool {
        if (self.history.items.len == 0) return false;
        if (self.base_buffer) |*base| base.deinit();
        self.base_buffer = self.history.pop();
        try self.discardPreview();
        return true;
    }

    pub fn clearHistory(self: *EditorState) void {
        for (self.history.items) |*buf| buf.deinit();
        self.history.clearRetainingCapacity();
    }

    pub fn setPaletteQuery(self: *EditorState, query: []const u8) !void {
        self.palette_query.clearRetainingCapacity();
        try self.palette_query.appendSlice(self.allocator, query);
    }

    pub fn deinit(self: *EditorState) void {
        if (self.base_buffer) |*buf| buf.deinit();
        if (self.preview_buffer) |*buf| buf.deinit();
        for (self.history.items) |*buf| buf.deinit();
        self.history.deinit(self.allocator);
        if (self.active_mask) |mask| self.allocator.free(mask);
        self.palette_query.deinit(self.allocator);
        self.status_text.deinit(self.allocator);
        self.dither_palette_hsv.deinit(self.allocator);
    }
};
