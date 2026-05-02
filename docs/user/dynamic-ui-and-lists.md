# Dynamic UI and Large Lists

The recommended pattern for dynamic UI is:

1. keep app state in your own `StateType`
2. return `.rebuild` when state changes
3. rebuild tree declaratively in `build`
4. let reconcile patch the retained tree

## Dynamic list basics

For normal sized lists, build rows in a loop:

```zig
for (state.items, 0..) |item, i| {
    try children.append(allocator, try ui.button(.{
        .label = item.title,
        .font = font,
        .on_click_msg = Msg.item_click(i),
    }));
}
```

This style is used heavily in `examples/discord_client/main.zig`.

## Large datasets

For large datasets, keep the UI declarative and move scaling concerns into app state:

- query or page data incrementally in your backend/state layer
- render only the rows currently held in state
- use a scroll container for the rendered rows
- prefetch assets (for example thumbnails) from your app state logic

## Important rules

- Use stable `NodeId` values for stateful elements you need to read back (for example inputs and scroll containers).
- Return `.rebuild` when your state changes.
- Keep row construction deterministic so reconcile can patch efficiently.

## Hierarchical / tree data

The `comp.tree` component accepts any `ItemT` shaped like:

```zig
struct {
    id: []const u8,
    children: std.ArrayList(@This()),
    is_group: bool, // optional; inferred from children.len when absent
}
```

`comp.Builder(MessageT).treeFromSource(ItemT, &tree_state, root_items, logic, visuals)`
flattens the visible items, renders rows via your `build_row_content` callback,
and emits a `TreeMessage` union covering click/toggle/drag/drop/tick.

For lazy loading, reconcile the message **before** delegating to
`comp.tree.update`:

```zig
.toggle => |id| {
    if (!state.tree_state.isExpanded(id)) {
        // populate item.children here
    }
},
```

The `examples/file_explorer/` directory is the canonical end-to-end reference,
covering lazy directory loading, drag-and-drop with OS-level renames, and
cross-component navigation history. See [its README](../../examples/file_explorer/README.md)
for code snippets you can lift.

## References

- `examples/overlay/main.zig`
- `examples/tree/main.zig`
- `examples/file_explorer/`
- `src/ui/context.zig`
- `src/ui/components/tree.zig`
