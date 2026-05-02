# Extending Components

How to add a new component. Pattern: logic struct + descriptor struct, state lives in app, callbacks via `bindTag`. One file under `src/ui/components/`, re-exported from `src/ui/components/root.zig`.

## Shape

```zig
const std = @import("std");
const layout = @import("../layout.zig");
const types = @import("../types.zig");
const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;
const NodeId = types.NodeId;
const Style = layout.Style;
const FontData = @import("../../renderer/font/font_registry.zig").FontData;

pub const ProgressBarDescriptor = struct {
    style: Style = .{},
    track_color: [4]f32 = .{ 0.15, 0.17, 0.22, 1.0 },
    fill_color: [4]f32 = .{ 0.4, 0.7, 1.0, 1.0 },
    height: f32 = 6.0,
    label: ?[]const u8 = null,
    font: ?*FontData = null,
};

pub fn ProgressBarContext(comptime MessageT: type) type {
    return struct {
        base_id: NodeId,
        value: f32, // 0..1
        on_complete: ?MessageT = null,
    };
}

pub fn build(
    comptime MessageT: type,
    ui: *UIContext(MessageT),
    logic: ProgressBarContext(MessageT),
    desc: ProgressBarDescriptor,
) !*Node(MessageT) {
    const v = std.math.clamp(logic.value, 0.0, 1.0);

    const fill = try ui.div(.{
        .style = .{
            .width = .{ .percent = v },
            .height = .Full,
            .background_color = desc.fill_color,
            .corner_radius = .all(desc.height * 0.5),
        },
    });

    const track = try ui.div(.{
        .id = logic.base_id,
        .style = .{
            .width = .Full,
            .height = .{ .exact = desc.height },
            .background_color = desc.track_color,
            .corner_radius = .all(desc.height * 0.5),
            .overflow_x = .hidden,
        },
        .children = &.{ fill },
    });

    if (desc.label) |label| {
        const font = desc.font orelse return track;
        var wrap_style = desc.style;
        wrap_style.direction = .Column;
        wrap_style.gap = 4;
        const wrap = try ui.div(.{
            .style = wrap_style,
            .children = &.{
                try ui.text(.{ .content = label, .font = font, .style = .{} }),
                track,
            },
        });
        return wrap;
    }
    return track;
}
```

## Wire into the Builder

`src/ui/components/root.zig`:

```zig
const progress_bar_impl = @import("progress_bar.zig");
pub const ProgressBarDescriptor = progress_bar_impl.ProgressBarDescriptor;
pub const ProgressBarContext = progress_bar_impl.ProgressBarContext;

// inside Builder(MessageT):
pub inline fn progressBar(
    self: Self,
    logic: ProgressBarContext(MessageT),
    desc: ProgressBarDescriptor,
) !*Node(MessageT) {
    return progress_bar_impl.build(MessageT, self.ui, logic, desc);
}
```

## Use site

```zig
const Ids = lib.declareIds(.{ "progress" });
const ids = Ids{};

try b.progressBar(.{
    .base_id = ids.progress,
    .value = state.progress,
}, .{
    .label = "Loading",
    .font = state.font,
    .height = 8,
});
```

## Rules

- State lives in `AppState`, not in the component. Pass state through the logic struct.
- All callbacks use `*const fn(ValueT, ?*const anyopaque) MessageT`. Use `lib.bindTag` on the call site.
- Stable IDs: take a `base_id: NodeId`; for sub-elements use `comp.deriveChildId(base_id, "key")`.
- Style overrides go on the descriptor struct with sane defaults. New optional fields keep call sites untouched.
- Use the build arena (`ui.build_arena.allocator()`) for any per-frame allocations.
- Don't read `node.layout_result` from inside `build` — it reflects last frame, not this one. If you need fresh geometry, register a post-layout hook.

## References

- `src/ui/components/`
- `src/ui/components/root.zig`
- existing components for shape templates: `slider.zig`, `checkbox.zig`, `dropdown.zig`
