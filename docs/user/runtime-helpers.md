# Runtime Helpers

The "remove foot-guns" toolkit re-exported from `src/root.zig`. Reach for these before writing alternatives.

## `lib.Runtime`

Allocator wrapper. `DebugAllocator` in Debug, `smp_allocator` in Release.

```zig
var rt = lib.Runtime.init();
defer rt.deinit();

var app = try App.init(rt.allocator(), io, ...);
```

`rt.deinit()` reports leaks in Debug. Don't roll your own GPA.

## `lib.For(MessageT)`

Bundles parameterised types. Use this instead of repeating `UIContext(M)`, `Node(M)`, `InteractionMessage(M)` everywhere.

```zig
const T = lib.For(AppMessage);
const App = lib.Application(AppState, AppMessage);

fn build(ui: *T.UIContext, state: *const AppState) anyerror!*T.Node { ... }
fn update(app: *App, msg: T.InteractionMessage) lib.UpdateAction { ... }
```

Members: `Message`, `UIContext`, `Node`, `InteractionMessage`, `InteractionRegistry`, `EventBinding`.

## `lib.declareIds`

Comptime tuple of string literals → struct of stable `NodeId` fields. One hash, zero foot-guns.

```zig
const Ids = lib.declareIds(.{ "search_input", "submit_button", "results_list" });
const ids = Ids{};

try ui.textInput(.{ .id = ids.search_input, ... });
```

The hash is `Wyhash` over the literal — IDs are stable across builds.

## `lib.bindTag`

Comptime trampoline producing a callback that wraps `value` in a tagged-union variant. No more hand-written closures.

```zig
const AppMessage = union(enum) {
    volume_changed: f32,
    list_scrolled: f32,
};

try b.slider(.{
    .base_id = ids.volume,
    .value = state.volume,
    .on_change = lib.bindTag(AppMessage, f32, .volume_changed),
});
```

Signature returned: `*const fn (ValueT, ?*const anyopaque) MessageT`.

## `lib.bindStatic`

Same signature, ignores incoming value — fires a constant message regardless of slider value / scroll delta / etc.

```zig
.on_click_msg_dynamic = lib.bindStatic(AppMessage, void, .reset),
```

## `comp.deriveChildId`

Derives a child `NodeId` from a parent ID + key. Use inside custom components for stable per-child identity.

```zig
const row_id = comp.deriveChildId(ids.list, "row_3");
```

Hashes `parent ^ wyhash(key)` so collisions across components are unlikely.

## `dupeMessageBinding`

Clones an `EventBinding` into another allocator. Used internally by reconcile when promoting build-arena bindings into the retained tree.

## Reference

- `src/root.zig`
