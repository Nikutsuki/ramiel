# Events, Focus, Input

Events arrive as `InteractionMessage(MessageT)` and flow through the reducer.

## Message shape

`InteractionMessage` (`src/ui/types.zig`):

- `id: ?MessageT` — semantic id from a node descriptor field
- `source: NodeId` — origin node
- `data` — variant union (`mouse`, `scroll`, `key`, `char`, `cursor`)

## Hooking events

Common descriptor fields:

- `on_click_msg`
- `on_hover_enter_msg` / `on_hover_exit_msg`
- `on_pointer_move_msg` / `on_pointer_down_msg` / `on_pointer_up_msg`
- `on_scroll_msg`
- `TextInputDescriptor.on_key_down_msg` / `on_text_input_msg`

## Focus

- `textInput` nodes are focusable.
- `Tab` / `Shift+Tab` cycles focusables.
- Click outside clears focus.
- Tracked by `interaction_registry.focused_node`.

## Text input

`textInput` supports UTF-8 typing, cursor movement, selection (`Shift`+arrows), `Ctrl+A/C/V`, `Backspace`/`Delete`. Live buffer at `node.payload.text_input.buffer`.

## Static text selection

`.text` nodes support click-drag selection, `Ctrl+A`, `Ctrl+C`.

## Cursor

Auto fallback by hovered node kind: text → I-beam, clickable → pointer, else arrow. Override with `style.cursor`.

## Reducer pattern

```zig
fn update(app: *App, msg: T.InteractionMessage) lib.UpdateAction {
    if (msg.id) |id| switch (id) {
        .search_changed => return .none,
        .submit => {
            app.state.submitted = true;
            return .rebuild;
        },
        else => {},
    }
    return .none;
}
```

## Pointer/scroll payloads

```zig
.canvas_pointer_move => {
    if (msg.data == .mouse) {
        const cx = msg.data.mouse.x;
        const cy = msg.data.mouse.y;
        if (state.is_panning) {
            state.pan_x += cx - state.last_x;
            state.pan_y += cy - state.last_y;
            state.last_x = cx;
            state.last_y = cy;
            return .repaint;
        }
    }
    return .none;
},
.canvas_scrolled => {
    if (msg.data == .scroll) {
        state.zoom *= std.math.pow(f32, 1.1, msg.data.scroll.dy);
        return .relayout;
    }
    return .none;
},
```

## Global shortcuts

`app.setShortcutHandler(CtxT, ctx, handler)` installs a typed handler that intercepts native key events before per-node dispatch. Handler returns `true` to consume.

```zig
fn shortcuts(
    state: *AppState,
    ir: *T.InteractionRegistry,
    key: i32,
    action: i32,
    win: *const lib.WindowContext,
) bool {
    if (action != lib.glfw.Press) return false;
    const ctrl = win.isKeyDown(lib.glfw.KeyLeftControl) or win.isKeyDown(lib.glfw.KeyRightControl);
    if (ctrl and key == lib.glfw.KeyZ) {
        state.undo_pending = true;
        ir.rebuild_requested = true;
        return true;
    }
    return false;
}

// in main:
app.setShortcutHandler(AppState, &app.state, shortcuts);
```

The trampoline casts the opaque pointer back to `*CtxT` at comptime; no globals needed. See `src/app.zig:629`.

OS-level hotkeys (fire even when window is unfocused) use `app.registerGlobalHotkey(mod, vk, cb)` — Win32 + X11. See `docs/user/platform-overlay-and-hotkeys.md`.

## References

- `src/ui/interaction.zig`
- `src/ui/types.zig`
- `examples/canvas_app/update.zig:109`
- `examples/file_explorer/main.zig:70`
- `examples/audio_player/main.zig:1043`
