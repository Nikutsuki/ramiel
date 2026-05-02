const core = @import("../core.zig");

pub fn buildLeftCanvas(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    return if (state.base_canvas) |canvas|
        ui.canvas(.{
            .style = .{
                .width = .{ .percent = 50 },
                .height = .Full,
                .flex_grow = 1,
            },
            .target = canvas,
            .pan_x = state.pan_x,
            .pan_y = state.pan_y,
            .zoom = state.zoom,
        })
    else
        ui.div(.{
            .style = .{
                .width = .{ .percent = 50 },
                .height = .Full,
            },
        });
}

pub fn buildRightCanvas(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    return if (state.preview_canvas) |canvas|
        ui.canvas(.{
            .style = .{
                .width = .{ .percent = 50 },
                .height = .Full,
                .flex_grow = 1,
            },
            .target = canvas,
            .pan_x = state.pan_x,
            .pan_y = state.pan_y,
            .zoom = state.zoom,
            .events = &.{
                .{ .event = .scroll, .msg = .{ .canvas_scrolled = {} } },
                .{ .event = .pointer_move, .msg = .{ .canvas_pointer_move = {} } },
            },
        })
    else
        ui.div(.{
            .style = .{
                .width = .{ .percent = 50 },
                .height = .Full,
            },
        });
}

