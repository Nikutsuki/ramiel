const std = @import("std");
const lib = @import("ramiel");
const glfw = @import("glfw");
const core = @import("core.zig");
const filters = @import("filters.zig");
const worker_pool = @import("worker.zig");

const CmdDef = struct {
    kind: filters.FilterKind,
    p1_default: f32 = 0.0,
    p2_default: f32 = 0.0,
    status: []const u8,
};

const CommandMap = std.StaticStringMap(CmdDef).initComptime(.{
    .{ "invert", CmdDef{ .kind = .invert, .status = "Previewing: Invert" } },
    .{ "dilate", CmdDef{ .kind = .dilation, .status = "Previewing: Dilation" } },
    .{ "erode", CmdDef{ .kind = .erosion, .status = "Previewing: Erosion" } },
    .{ "subtract", CmdDef{ .kind = .subtract, .p1_default = 50.0, .status = "Previewing: Subtract" } },
    .{ "glitch", CmdDef{ .kind = .displacement, .p1_default = 100.0, .p2_default = 200.0, .status = "Previewing: Displacement (Glitch)" } },
    .{ "kuwahara", CmdDef{ .kind = .kuwahara, .p1_default = 3.0, .status = "Previewing: Kuwahara" } },
    .{ "dither", CmdDef{ .kind = .dither_bayer, .p1_default = 32.0, .status = "Previewing: Bayer Dither" } },
    .{ "sort", CmdDef{ .kind = .pixel_sort_h, .p1_default = 128.0, .p2_default = 1.0, .status = "Previewing: Pixel Sort" } },
    .{ "restore", CmdDef{ .kind = .restore, .p1_default = 1.0, .status = "Previewing: Restore" } },
    .{ "aberration", CmdDef{ .kind = .chromatic_aberration, .p1_default = 2.0, .p2_default = 0.0, .status = "Previewing: Chromatic Aberration" } },
});

var g_dialog_io: std.Io = std.Options.debug_io;
var g_dialog_path_mutex: std.Io.Mutex = .init;
var g_dialog_selected_path: ?[]const u8 = null;

fn onFileDialogResult(path: ?[]const u8) core.AppMessage {
    g_dialog_path_mutex.lockUncancelable(g_dialog_io);
    g_dialog_selected_path = path;
    g_dialog_path_mutex.unlock(g_dialog_io);
    return .{ .file_selected = {} };
}

fn asWorker(state: *core.AppState) ?*worker_pool.FilterWorkerPool {
    const ptr = state.runtime.worker orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn syncPreviewEditorFromCanvas(state: *core.AppState) !void {
    const canvas = state.runtime.preview_canvas orelse return;
    const copy = try core.PixelBuffer.initBlank(state.editor.allocator, canvas.width, canvas.height);
    @memcpy(copy.pixels, canvas.getRawPixels());
    state.editor.setPreviewBuffer(copy);
}

fn applyBaseBufferToCanvas(state: *core.AppState) bool {
    const canvas = state.runtime.base_canvas orelse return false;
    const buffer = state.editor.base_buffer orelse return false;
    if (canvas.getRawPixels().len != buffer.pixels.len) return false;
    @memcpy(canvas.getRawPixels(), buffer.pixels);
    canvas.markDirty();
    return true;
}

fn applyPreviewBufferToCanvas(state: *core.AppState) bool {
    const canvas = state.runtime.preview_canvas orelse return false;
    const buffer = state.editor.preview_buffer orelse return false;
    if (canvas.getRawPixels().len != buffer.pixels.len) return false;
    @memcpy(canvas.getRawPixels(), buffer.pixels);
    canvas.markDirty();
    return true;
}

fn extractActiveMask(state: *core.AppState) void {
    const canvas = state.runtime.preview_canvas orelse return;
    const pixels = canvas.getRawPixels();
    const pixel_count = pixels.len / 4;

    if (state.editor.active_mask) |m| state.editor.allocator.free(m);
    state.editor.active_mask = state.editor.allocator.alloc(u8, pixel_count) catch null;
    if (state.editor.active_mask) |mask| {
        var i: usize = 0;
        while (i < pixel_count) : (i += 1) {
            mask[i] = pixels[i * 4];
        }
    }
}

fn applyBrush(pixels: []u8, width: u32, height: u32, px: i32, py: i32, radius: f32, color: [4]u8) void {
    const r2 = radius * radius;
    const ir = @as(i32, @intFromFloat(@ceil(radius)));
    const w = @as(i32, @intCast(width));
    const h = @as(i32, @intCast(height));

    var y = py - ir;
    while (y <= py + ir) : (y += 1) {
        if (y < 0 or y >= h) continue;
        var x = px - ir;
        while (x <= px + ir) : (x += 1) {
            if (x < 0 or x >= w) continue;
            const dx = @as(f32, @floatFromInt(x - px));
            const dy = @as(f32, @floatFromInt(y - py));
            if (dx * dx + dy * dy <= r2) {
                const idx = @as(usize, @intCast((y * w + x) * 4));
                pixels[idx] = color[0];
                pixels[idx + 1] = color[1];
                pixels[idx + 2] = color[2];
                pixels[idx + 3] = color[3];
            }
        }
    }
}

pub fn appShortcutHandler(
    state: *core.AppState,
    ir: *core.lib.For(core.AppMessage).InteractionRegistry,
    key: i32,
    action: i32,
    is_ctrl: bool,
    _: bool,
) bool {
    if (action != glfw.Press) return false;

    if (is_ctrl and key == glfw.KeyP) {
        state.editor.palette_open = !state.editor.palette_open;
        if (state.editor.palette_open) ir.requestFocus(core.NodeIds.palette_input);
        ir.postExternalMessage(.{ .id = .{ .rebuild_requested = {} } });
        return true;
    }
    if (is_ctrl and key == glfw.KeyZ) {
        if ((state.editor.undoCommit() catch false)) {
            _ = applyBaseBufferToCanvas(state);
            _ = applyPreviewBufferToCanvas(state);
            ir.postExternalMessage(.{ .id = .{ .rebuild_requested = {} } });
        }
        return true;
    }
    if (is_ctrl and key == glfw.KeyS) {
        ir.postExternalMessage(.{ .id = .{ .commit_preview = {} } });
        return true;
    }
    if (is_ctrl and key == glfw.KeyR) {
        ir.postExternalMessage(.{ .id = .{ .discard_preview = {} } });
        return true;
    }
    return false;
}

pub fn update(ctx: anytype, state: *core.AppState, msg: core.AppMessage) core.UpdateAction {
    const app = ctx.app;
    const allocator = app.allocator;
    const event_data = ctx.event_data;
    var action = lib.state.ActionAccumulator{};
    switch (msg) {
        .rebuild_requested => return .rebuild,
        .palette_query_changed => {
            {
                if (app.ui.getInputText(core.NodeIds.palette_input)) |text| {
                    state.editor.setPaletteQuery(text) catch {};
                }
            }
            return .rebuild;
        },
        .palette_key_down => {
            if (event_data == .key and event_data.key.action == glfw.Press) {
                if (event_data.key.key == glfw.KeyEnter) {
                    app.postMessageId(.{ .execute_palette_command = {} });
                } else if (event_data.key.key == glfw.KeyTab) {
                    app.postMessageId(.{ .autocomplete_palette = {} });
                } else if (event_data.key.key == glfw.KeyEscape) {
                    app.postMessageId(.{ .close_palette = {} });
                }
            }
            return .none;
        },
        .close_palette => {
            state.editor.palette_open = false;
            return .rebuild;
        },
        .palette_consume_click => return .none,
        .autocomplete_palette => {
            const query = state.editor.palette_query.items;
            var cmd_it = std.mem.splitScalar(u8, query, ' ');
            const typed_cmd = cmd_it.next() orelse return .none;
            for (core.ALL_COMMANDS) |cmd| {
                if (std.mem.startsWith(u8, cmd, typed_cmd)) {
                    state.editor.setPaletteQuery(cmd) catch {};
                    break;
                }
            }
            return .rebuild;
        },
        .toggle_help => {
            state.editor.show_help = !state.editor.show_help;
            return .rebuild;
        },
        .param_changed => |param| {
            if (param.index < state.editor.filter_params.len) {
                const active = state.editor.active_filter orelse return .none;
                const meta = filters.getFilterMeta(active);
                if (param.index >= meta.params.len) return .none;
                const def = meta.params[param.index];
                const new_value: f32 = switch (def.kind) {
                    .slider => blk: {
                        const normalized = std.math.clamp(param.value, 0.0, 1.0);
                        var value = normalized * (def.max - def.min) + def.min;
                        if (active == .restore and param.index == 1) {
                            const max_hist: f32 = if (state.editor.history.items.len > 0) @as(f32, @floatFromInt(state.editor.history.items.len - 1)) else 0.0;
                            value = @round(normalized * @max(1.0, max_hist));
                        }
                        break :blk value;
                    },
                    .radio => @round(param.value),
                    .palette_editor => state.editor.filter_params[param.index],
                };
                state.editor.filter_params[param.index] = new_value;
                if (core.isMaskFilter(active) and def.kind == .radio and param.index == 0) {
                    const selected = @as(usize, @intFromFloat(std.math.clamp(new_value, 0.0, 5.0)));
                    state.editor.active_filter = core.maskIndexToFilter(selected);
                }
                app.postMessageId(.{ .execute_active_filter = {} });
            }
            return .rebuild;
        },
        .palette_add => {
            const max_colors = (state.editor.filter_params.len - 2) / 3;
            if (state.editor.dither_palette_hsv.items.len < max_colors) {
                state.editor.dither_palette_hsv.append(state.editor.allocator, .{ 0.0, 1.0, 1.0 }) catch {};
                state.editor.dither_selected_color = state.editor.dither_palette_hsv.items.len - 1;
                if (state.runtime.color_picker_canvas) |picker_canvas| lib.components.updateColorPickerPlaneTexture(picker_canvas, 0.0);
                app.postMessageId(.{ .execute_active_filter = {} });
            }
            return .rebuild;
        },
        .palette_remove => {
            if (state.editor.dither_palette_hsv.items.len > 1) {
                _ = state.editor.dither_palette_hsv.orderedRemove(state.editor.dither_selected_color);
                state.editor.dither_selected_color = @min(state.editor.dither_selected_color, state.editor.dither_palette_hsv.items.len - 1);
                if (state.runtime.color_picker_canvas) |picker_canvas| {
                    const new_hue = state.editor.dither_palette_hsv.items[state.editor.dither_selected_color][0];
                    lib.components.updateColorPickerPlaneTexture(picker_canvas, new_hue);
                }
                app.postMessageId(.{ .execute_active_filter = {} });
            }
            return .rebuild;
        },
        .palette_select => |idx| {
            if (idx >= state.editor.dither_palette_hsv.items.len) return .none;
            state.editor.dither_selected_color = idx;
            if (state.runtime.color_picker_canvas) |picker_canvas| {
                const new_hue = state.editor.dither_palette_hsv.items[idx][0];
                lib.components.updateColorPickerPlaneTexture(picker_canvas, new_hue);
            }
            return .rebuild;
        },
        .picker_hue => |v| {
            if (state.editor.dither_selected_color >= state.editor.dither_palette_hsv.items.len) return .none;
            const hue = std.math.clamp(v, 0.0, 1.0) * 360.0;
            state.editor.dither_palette_hsv.items[state.editor.dither_selected_color][0] = hue;
            if (state.runtime.color_picker_canvas) |picker_canvas| lib.components.updateColorPickerPlaneTexture(picker_canvas, hue);
            app.postMessageId(.{ .execute_active_filter = {} });
            return .rebuild;
        },
        .picker_sv => |v| {
            if (state.editor.dither_selected_color >= state.editor.dither_palette_hsv.items.len) return .none;
            state.editor.dither_palette_hsv.items[state.editor.dither_selected_color][1] = std.math.clamp(v[0], 0.0, 1.0);
            state.editor.dither_palette_hsv.items[state.editor.dither_selected_color][2] = std.math.clamp(1.0 - v[1], 0.0, 1.0);
            app.postMessageId(.{ .execute_active_filter = {} });
            return .rebuild;
        },
        .execute_active_filter => {
            const base = state.editor.base_buffer orelse return .none;
            const kind = state.editor.active_filter orelse return .none;
            const meta = filters.getFilterMeta(kind);
            var aux_buffer: ?[]const u8 = null;
            if (kind == .restore) {
                const history_idx = @as(usize, @intFromFloat(@max(0.0, state.editor.filter_params[1])));
                if (history_idx < state.editor.history.items.len) aux_buffer = state.editor.history.items[history_idx].pixels else if (state.editor.history.items.len > 0) aux_buffer = state.editor.history.items[0].pixels;
            }
            var worker_params: [64]f32 = [_]f32{0.0} ** 64;
            const param_count: usize = if (meta.serializeFn) |serialize|
                @min(serialize(&state.editor, worker_params[0..]), worker_params.len)
            else blk: {
                const count = @min(meta.params.len, worker_params.len);
                @memcpy(worker_params[0..count], state.editor.filter_params[0..count]);
                break :blk count;
            };
            if (asWorker(state)) |worker| {
                _ = worker.submit(base.pixels, state.editor.active_mask, aux_buffer, base.width, base.height, kind, worker_params[0..param_count]) catch {};
            }
            return .none;
        },
        .execute_palette_command => {
            if (state.editor.base_buffer == null) return .none;
            const query = state.editor.palette_query.items;
            if (query.len == 0) return .none;
            var it = std.mem.splitScalar(u8, query, ' ');
            const raw_cmd = it.next() orelse return .none;
            var resolved_cmd: []const u8 = raw_cmd;
            for (core.ALL_COMMANDS) |cmd| if (std.mem.startsWith(u8, cmd, raw_cmd)) {
                resolved_cmd = cmd;
                break;
            };

            var kind: ?filters.FilterKind = null;
            var p1: f32 = 0.0;
            var p2: f32 = 0.0;

            if (CommandMap.get(resolved_cmd)) |def| {
                kind = def.kind;
                p1 = if (it.next()) |s| std.fmt.parseFloat(f32, s) catch def.p1_default else def.p1_default;
                p2 = if (it.next()) |s| std.fmt.parseFloat(f32, s) catch def.p2_default else def.p2_default;
                state.editor.setStatusText(def.status);
            } else if (std.mem.eql(u8, resolved_cmd, "mask")) {
                const mask_type = it.next() orelse "luma";
                if (std.mem.eql(u8, mask_type, "r")) {
                    kind = .mask_r;
                    state.editor.setStatus("Generating: Red Mask", .{});
                } else if (std.mem.eql(u8, mask_type, "g")) {
                    kind = .mask_g;
                    state.editor.setStatus("Generating: Green Mask", .{});
                } else if (std.mem.eql(u8, mask_type, "b")) {
                    kind = .mask_b;
                    state.editor.setStatus("Generating: Blue Mask", .{});
                } else if (std.mem.eql(u8, mask_type, "edge")) {
                    kind = .mask_edge;
                    state.editor.setStatus("Generating: Edge Mask", .{});
                } else if (std.mem.eql(u8, mask_type, "contrast")) {
                    kind = .mask_contrast;
                    p1 = if (it.next()) |s| std.fmt.parseFloat(f32, s) catch 128.0 else 128.0;
                    state.editor.setStatus("Generating: Contrast Mask", .{});
                } else {
                    kind = .mask_luma;
                    p1 = if (it.next()) |s| std.fmt.parseFloat(f32, s) catch 128.0 else 128.0;
                    state.editor.setStatus("Generating: Luma Mask", .{});
                }
            } else if (std.mem.eql(u8, resolved_cmd, "commit")) {
                app.postMessageId(.{ .commit_preview = {} });
            } else if (std.mem.eql(u8, resolved_cmd, "discard")) {
                app.postMessageId(.{ .discard_preview = {} });
            } else if (std.mem.eql(u8, resolved_cmd, "open")) {
                app.postMessageId(.{ .open_dialog = {} });
            } else if (std.mem.eql(u8, resolved_cmd, "saveas")) {
                const rest = if (query.len > raw_cmd.len) std.mem.trim(u8, query[raw_cmd.len..], " \t\r\n") else "";
                if (rest.len == 0) state.editor.setStatus("Usage: saveas <file.png|jpg|bmp|tga>", .{}) else {
                    const save_buf: ?*const core.PixelBuffer = if (state.editor.preview_buffer) |*b| b else if (state.editor.base_buffer) |*b| b else null;
                    if (save_buf) |buf| {
                        buf.exportToFile(rest) catch |err| {
                            state.editor.setStatus("Save failed: {s}", .{@errorName(err)});
                            state.editor.palette_open = false;
                            state.editor.palette_query.clearRetainingCapacity();
                            return .rebuild;
                        };
                        state.editor.setStatus("Saved: {s}", .{rest});
                    } else state.editor.setStatus("Nothing to save", .{});
                }
            }

            if (kind) |k| {
                state.editor.active_filter = k;
                const meta = filters.getFilterMeta(k);
                if (meta.params.len > 0) state.editor.filter_params[0] = p1;
                if (meta.params.len > 1) state.editor.filter_params[1] = p2;
                if (core.isMaskFilter(k)) {
                    state.editor.filter_params[0] = @floatFromInt(core.maskFilterToIndex(k));
                    if (k == .mask_luma or k == .mask_contrast) state.editor.filter_params[1] = p1;
                } else if (k == .pixel_sort_h and meta.params.len > 1) {
                    state.editor.filter_params[1] = if (p2 > 0.5) 1.0 else 0.0;
                } else if (k == .restore and meta.params.len > 1) {
                    state.editor.filter_params[1] = @max(0.0, @round(p2));
                }
                if (k == .dither_bayer) {
                    if (state.runtime.color_picker_canvas) |picker_canvas| {
                        const selected = @min(state.editor.dither_selected_color, state.editor.dither_palette_hsv.items.len - 1);
                        state.editor.dither_selected_color = selected;
                        const hue = state.editor.dither_palette_hsv.items[selected][0];
                        lib.components.updateColorPickerPlaneTexture(picker_canvas, hue);
                    }
                }
                app.postMessageId(.{ .execute_active_filter = {} });
            }
            state.editor.palette_open = false;
            state.editor.palette_query.clearRetainingCapacity();
            return .rebuild;
        },
        .canvas_pointer_move => {
            if (event_data != .mouse) return action.finish();
            if (state.runtime.preview_canvas == null) return action.finish();
            const canvas = state.runtime.preview_canvas.?;
            const fb = app.window.getFramebufferSize();
            const inner_w = @max(1.0, @as(f32, @floatFromInt(fb.width)) - core.ROOT_PADDING * 2.0);
            const workspace_w = @max(1.0, inner_w - 250.0 - core.ROOT_GAP * 2.0);
            const workspace_h = @max(1.0, @as(f32, @floatFromInt(fb.height)) - core.ROOT_PADDING * 2.0);
            const per_canvas_w = @max(1.0, (workspace_w - core.ROOT_GAP) * 0.5);
            state.canvas_screen_x = core.ROOT_PADDING + per_canvas_w + core.ROOT_GAP;
            state.canvas_screen_y = core.ROOT_PADDING;
            state.canvas_screen_w = per_canvas_w;
            state.canvas_screen_h = workspace_h;
            const cx = event_data.mouse.x;
            const cy = event_data.mouse.y;
            const local_sx = cx - state.canvas_screen_x;
            const local_sy = cy - state.canvas_screen_y;
            const cursor_on_canvas = local_sx >= 0 and local_sx < state.canvas_screen_w and local_sy >= 0 and local_sy < state.canvas_screen_h;
            if (app.window.isMouseButtonDown(core.PAN_BUTTON) and cursor_on_canvas) {
                if (!state.is_panning) {
                    state.is_panning = true;
                    state.last_mouse_x = cx;
                    state.last_mouse_y = cy;
                } else {
                    const dx = cx - state.last_mouse_x;
                    const dy = cy - state.last_mouse_y;
                    if (dx != 0.0 or dy != 0.0) {
                        state.pan_x += dx;
                        state.pan_y += dy;
                        action.add(.rebuild);
                    }
                    state.last_mouse_x = cx;
                    state.last_mouse_y = cy;
                }
            } else {
                state.is_panning = false;
                if (!app.window.isMouseButtonDown(0) and !app.window.isMouseButtonDown(1)) state.brush_stroke_active = false;
                if ((app.window.isMouseButtonDown(0) or app.window.isMouseButtonDown(1)) and cursor_on_canvas) {
                    const half_w = state.canvas_screen_w / 2.0;
                    const half_h = state.canvas_screen_h / 2.0;
                    const img_w = @as(f32, @floatFromInt(canvas.width));
                    const img_h = @as(f32, @floatFromInt(canvas.height));
                    const ix = (local_sx - half_w - state.pan_x) / state.zoom + (img_w / 2.0);
                    const iy = (local_sy - half_h - state.pan_y) / state.zoom + (img_h / 2.0);
                    const px = @as(i32, @intFromFloat(ix));
                    const py = @as(i32, @intFromFloat(iy));
                    const image_radius = state.brush_radius / state.zoom;
                    const masking = core.isMaskFilter(state.editor.active_filter);
                    const brush_color: [4]u8 = if (masking) if (app.window.isMouseButtonDown(1)) .{ 0, 0, 0, 255 } else .{ 255, 255, 255, 255 } else state.brush_color;
                    applyBrush(canvas.getRawPixels(), canvas.width, canvas.height, px, py, image_radius, brush_color);
                    canvas.markDirty();
                    syncPreviewEditorFromCanvas(state) catch {};
                    if (masking) extractActiveMask(state);
                }
            }
        },
        .canvas_scrolled => {
            if (event_data == .scroll) {
                const dy = event_data.scroll.dy;
                if (dy != 0.0) {
                    var cx: f32 = 0.0;
                    var cy: f32 = 0.0;
                    {
                        const cursor = app.window.getCursorPos();
                        cx = @floatCast(cursor.x);
                        cy = @floatCast(cursor.y);
                    }
                    const local_sx = cx - state.canvas_screen_x;
                    const local_sy = cy - state.canvas_screen_y;
                    const prev_zoom = state.zoom;
                    const next_zoom = std.math.clamp(prev_zoom * std.math.pow(f32, 1.1, dy), 0.05, 64.0);
                    if (@abs(next_zoom - prev_zoom) > 0.0001) {
                        const half_w = state.canvas_screen_w / 2.0;
                        const half_h = state.canvas_screen_h / 2.0;
                        const inv_ix = (local_sx - half_w - state.pan_x) / prev_zoom;
                        const inv_iy = (local_sy - half_h - state.pan_y) / prev_zoom;
                        state.zoom = next_zoom;
                        state.pan_x = local_sx - half_w - inv_ix * next_zoom;
                        state.pan_y = local_sy - half_h - inv_iy * next_zoom;
                        action.add(.rebuild);
                    }
                }
            }
        },
        .open_dialog => app.openFileDialog(core.FILE_FILTERS, onFileDialogResult),
        .file_selected => {
            app.finalizeFileDialog();
            g_dialog_path_mutex.lockUncancelable(g_dialog_io);
            const maybe_path = g_dialog_selected_path;
            g_dialog_selected_path = null;
            g_dialog_path_mutex.unlock(g_dialog_io);
            if (maybe_path) |path| {
                defer allocator.free(path);
                const path_z = allocator.dupeZ(u8, path) catch return .none;
                defer allocator.free(path_z);
                const buffer = core.PixelBuffer.loadFromFile(allocator, path_z) catch return .none;
                const base_copy = buffer.clone() catch {
                    var owned = buffer;
                    owned.deinit();
                    return .none;
                };
                const preview_copy = buffer.clone() catch {
                    var owned = buffer;
                    owned.deinit();
                    var b = base_copy;
                    b.deinit();
                    return .none;
                };
                {
                    if (state.runtime.base_canvas) |old_canvas| app.destroyCanvas(old_canvas);
                    if (state.runtime.preview_canvas) |old_preview| app.destroyCanvas(old_preview);
                    state.runtime.base_canvas = app.createCanvasFromBuffer(buffer) catch return .none;
                    const preview_canvas_buf = preview_copy.clone() catch return .none;
                    state.runtime.preview_canvas = app.createCanvasFromBuffer(preview_canvas_buf) catch return .none;
                    state.editor.clearHistory();
                    state.editor.setBaseBuffer(base_copy);
                    state.editor.setPreviewBuffer(preview_copy);
                    state.editor.active_filter = null;
                    state.editor.filter_params = [_]f32{0.0} ** 64;
                    state.editor.setStatus("Loaded image", .{});
                    state.zoom = 1.0;
                    state.pan_x = 0.0;
                    state.pan_y = 0.0;
                    state.brush_stroke_active = false;
                    return .rebuild;
                }
            }
        },
        .filter_done => {
            if (state.runtime.preview_canvas) |canvas| {
                if (asWorker(state)) |worker| {
                    var completed_kind: ?filters.FilterKind = null;
                    if (worker.copyCompletedInto(canvas.getRawPixels(), &completed_kind)) {
                        canvas.markDirty();
                        syncPreviewEditorFromCanvas(state) catch {};
                        const ck = completed_kind orelse return .repaint;
                        if (core.isMaskFilter(ck)) extractActiveMask(state);
                        return .repaint;
                    }
                }
            }
        },
        .commit_preview => {
            state.editor.commitPreview() catch return .none;
            _ = applyBaseBufferToCanvas(state);
            state.editor.setStatus("Committed preview to base", .{});
            return .repaint;
        },
        .discard_preview => {
            state.editor.discardPreview() catch return .none;
            _ = applyPreviewBufferToCanvas(state);
            state.editor.setStatus("Discarded preview changes", .{});
            return .repaint;
        },
        else => {},
    }
    return action.finish();
}
