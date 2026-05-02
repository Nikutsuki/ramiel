# Best Practices

When building complex applications with `ramiel` (such as the `canvas_app` example), following certain architectural patterns will keep your codebase scalable, performant, and maintainable.

## 1. Separate State, Logic, and UI

A standard pattern used in large applications is to break your codebase into distinct domains:

- **State & Core (`core.zig`)**: Define your `AppState`, message enum (`AppMessage`), and core types here. This avoids circular dependencies between UI components and update logic.
- **Reducer/Update (`update.zig`)**: Place your `update` function here. This function takes messages and mutates the state, keeping business logic out of UI rendering.
- **UI Components (`ui/` directory)**: Break your UI down into smaller functions or files. Each function takes the `UIContext` and `AppState` (or a slice of it) and returns a `Node`.
  - e.g., `ui/root.zig`, `ui/top_bar.zig`, `ui/workspace.zig`.

## 2. Granular Updates

Your reducer must return an `UpdateAction`:
- `.none`: Use when the message doesn't affect the visual state (e.g. processing a background task or ignoring redundant input).
- `.repaint`: Use when the layout hasn't changed but visual properties (like pixels on a canvas or a color) have.
- `.relayout`: Use when layout properties change but tree structure remains the same.
- `.rebuild`: Use when structural changes occur (e.g., adding/removing items, text changes, conditional UI).

*Tip*: Don't blindly return `.rebuild` for everything. For high-frequency events like painting on a canvas or hovering, modifying the underlying buffer and returning `.repaint` is much more efficient.

## 3. Effective Use of `NodeId`

`NodeId` is essential for the reconciliation engine to map new UI descriptions to the existing retained tree.

- **Stable IDs**: Always use a stable `NodeId` for stateful nodes like text inputs, scrollable areas, and animated elements. If you recreate a node with a different ID, it will lose its state (e.g., cursor position or scroll offset).
- **Dynamic IDs**: When generating nodes in a loop (like a list of items), generate IDs based on the data identity rather than the array index, or use hashing (`std.hash.Fnv1a_32`) combining a type enum and an index.

Example from `canvas_app`:
```zig
pub fn makeParamNodeId(kind: filters.FilterKind, param_idx: usize, salt: u8) lib.NodeId {
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(std.mem.asBytes(&kind));
    hasher.update(std.mem.asBytes(&param_idx));
    hasher.update(&.{salt});
    return hasher.final();
}
```

## 4. High-Performance Canvas & Workers

If you are building an app with complex image processing or custom pixel pushing:
- **Canvas Nodes**: Use `Canvas` nodes mapped to a `PixelBuffer`. You can manipulate the `PixelBuffer` off-thread or in the main loop, and then call `canvas.markDirty()` to signal to the renderer that the texture needs uploading.
- **Worker Pools**: Use Zig's threading or `std.Io` task abstractions to process heavy operations (like image filters) asynchronously. When the worker finishes, it can post a message via `app.ui.interaction_registry.postExternalMessage(msg)` to wake up the main loop and apply the result.

## 5. Event Handling & Keyboard Shortcuts

Global shortcuts or app-level keyboard handling shouldn't be scattered across components.
- Register an app shortcut handler that inspects native key events (via `glfw`) and posts semantic `AppMessage`s to the app queue.
- Use the `InteractionRegistry.shortcut_handler` hook or `Application.registerGlobalHotkey` for OS-level global hooks.
- Map low-level input to high-level actions: e.g., `Ctrl+Z` emits `.undo_requested` rather than performing the undo inline. This keeps state mutation confined to the `update` reducer.
