# App Lifecycle

`Application(StateType, MessageType)` owns window, renderer, UI context, audio/video managers, font system, reducer.

## Core surface

`src/app.zig`:

- `init(allocator, io, WindowConfig, initial_state, update_fn) !Self`
- `setRootBuilder(build_fn) !void`
- `run() !void`
- `setVisibility(bool) void`
- `setShortcutHandler(CtxT, ctx, handler) void`
- `registerGlobalHotkey(modifier, key, callback) !void`
- `postMessageId(msg_id) void` / `postMessage(InteractionMessage) void` (cross-thread)
- `tick_fn: ?*const fn (*Self) UpdateAction` (optional per-frame hook)

Reducer:

```zig
fn update(app: *App, msg: T.InteractionMessage) lib.UpdateAction
```

Builder:

```zig
fn build(ui: *T.UIContext, state: *const AppState) anyerror!*T.Node
```

Both are sourced from `src/app.zig`. No allocator parameter — use `ui.build_arena.allocator()` for per-frame allocations inside the builder.

## UpdateAction semantics

- `.none` — frame ends, app sleeps until next event.
- `.repaint` — render pass only. Use for canvas pixel mutations or direct retained-node tweaks.
- `.relayout` — layout + paint. Use when sizes/text content changed but tree shape didn't.
- `.rebuild` — re-runs `build_fn`, reconciles, then layout + paint. Default for structural changes.

ORed across all messages drained in a frame. Prefer the lightest action that produces correct output.

## Frame loop

`Application.run` per frame, in order (`src/app.zig:734`):

1. `glfw.waitEventsTimeout` (or `waitEvents` if idle).
2. `processPendingTextureUploads` — sets paint dirty if anything landed.
3. `tick_fn` — optional hook, returns `UpdateAction`.
4. Drain `cross_thread_queue` into `interaction_registry.message_queue`.
5. `interaction_registry.processInteractions` — hit-test, dispatch events.
6. Reducer drain — every queued message goes through `update_fn`, return values ORed.
7. Conditional rebuild — calls `build_fn` into `build_arena`, then `ui.reconcile(new_root)`.
8. Animation tick + hover-blend tick.
9. Up to 2 layout passes (post-layout hooks may dirty layout for a second pass within the same frame).
10. `engine.draw` — submits Vulkan commands.

## Imperative access

`ui.getById(node_id)` returns a retained `*Node` for targeted mutation. Stable `NodeId` required — use `lib.declareIds`. Prefer `.rebuild` for anything structural.

## References

- `src/app.zig`
- `examples/box_sizing/main.zig`
- `examples/discord_client/main.zig`
