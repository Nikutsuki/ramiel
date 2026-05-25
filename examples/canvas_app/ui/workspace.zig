const core = @import("../core.zig");
const tw = core.tw;

pub fn buildLeftCanvas(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const ux = ui.ux();
    return if (state.runtime.base_canvas) |canvas|
        ux.canvasAny(.{
            .class = .{ tw.w_pct(50), tw.h_full, tw.grow_1 },
            .target = canvas,
            .pan_x = state.pan_x,
            .pan_y = state.pan_y,
            .zoom = state.zoom,
        })
    else
        ux.divAny(.{
            .class = .{ tw.w_pct(50), tw.h_full },
        });
}

pub fn buildRightCanvas(ui: *core.AppUIContext, state: *const core.AppState) !*core.AppNode {
    const ux = ui.ux();
    return if (state.runtime.preview_canvas) |canvas|
        ux.canvasAny(.{
            .class = .{ tw.w_pct(50), tw.h_full, tw.grow_1 },
            .target = canvas,
            .pan_x = state.pan_x,
            .pan_y = state.pan_y,
            .zoom = state.zoom,
            .on_scroll = .{ .canvas_scrolled = {} },
            .on_pointer_move = .{ .canvas_pointer_move = {} },
        })
    else
        ux.divAny(.{
            .class = .{ tw.w_pct(50), tw.h_full },
        });
}
