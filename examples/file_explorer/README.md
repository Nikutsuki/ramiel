# File Explorer Example

Working file browser built on `ramiel`. Demonstrates idiomatic patterns for
**lazy filesystem trees**, **navigation history**, **grid views**, and the
**reducer-driven update loop** with real OS-level side effects.

Run:

```
zig build run-file-explorer
```

## Features

- Sidebar tree of the working-directory subtree, lazily expanded on click.
  Clicking the row (not just the chevron) loads children and navigates the
  grid.
- Drag and drop files between folders in the sidebar (real OS rename).
- Dense icon grid for the current directory: click a folder to enter it, click
  a file to select it. Bigger glyphs, more cells per row.
- Browser-style **Back / Forward / Up / Refresh** with full history stacks.
- Clickable breadcrumb path. Clicking the breadcrumb strip background turns it
  into an inline text input — type or paste an absolute path and press Enter.
  Esc cancels.
- **Typeahead jump:** with the grid focused, press a letter to select the
  first entry whose name starts with it.
- Sidebar tree stays in sync with the grid: every navigation expands the
  matching ancestor chain and selects the row.
- **+ Folder** creates a uniquely-named subdirectory in the current path.
- **Delete** removes the selected entry (recursive for directories).
- Status text surfaces filesystem errors inline instead of crashing.

## Layout of the example

```
examples/file_explorer/
├── main.zig            // bootstrap + asset/font wiring
├── core.zig            // AppState, AppMessage, FsNode, FsEntry
├── update.zig          // reducer: maps messages → state mutations
├── filesystem/
│   └── root.zig        // OS-level dir helpers (load, find, delete, name picker)
└── ui/
    ├── root.zig        // top-level layout: top-bar / sidebar / grid
    ├── top_bar.zig     // nav buttons + breadcrumbs + status
    ├── sidebar.zig     // tree component bound to FsNode
    ├── file_grid.zig   // grid of icon cells for current_path
    └── icons/          // SVG glyphs registered as static assets
```

## Reusable patterns

These patterns lift cleanly into other apps. Each is small enough to copy and
adapt.

### 1. Domain intents alongside library updates

`update.zig` shows the canonical pattern when wrapping a library component
that owns its own visual state (here: `comp.tree`).

```zig
.tree_msg => |t_msg| {
    switch (t_msg) {
        .toggle => |path| { /* lazy-load directory */ },
        .click  => |c|    { /* navigate current_path  */ },
        .drop   => |d|    {
            _ = comp.tree.applyDropMessage(...) catch {};
        },
        else => {},
    }
    // Visual state delegate. `comp.tree.update` defers drag-state reset
    // to the next `.tick`, so it's safe to call before or after any
    // `applyDropMessage` / domain handler that reads `state.dragged_id`.
    comp.tree.update([]const u8, core.FsNode, &state.tree_state, ..., t_msg) catch {};
    return .rebuild;
},
```

### 2. Lazy filesystem tree (`FsNode`)

`FsNode` is a plain recursive struct shaped to satisfy `comp.tree`'s
duck-typed contract (`id: []const u8`, `children: std.ArrayList(Self)`,
`is_group: bool`). Children are populated only when the user expands a node:

```zig
.toggle => |path| {
    if (!state.tree_state.isExpanded(path)) {
        if (filesystem.findFsNode(&state.root_node, path)) |node| {
            if (node.is_group and !node.is_loaded) {
                filesystem.loadDirectoryContents(state.fs_allocator, state.io, node) catch {};
            }
        }
    }
},
```

The whole tree shares one arena (`fs_arena`) which is freed on app exit.
Per-node `deinit` walks children for any test-time tear-downs.

### 3. Navigation history with two stacks

```zig
back_stack:    std.ArrayList([]const u8),
forward_stack: std.ArrayList([]const u8),

pub fn navigateTo(self: *AppState, target: []const u8) !void {
    const owned = try self.allocator.dupe(u8, target);
    try self.back_stack.append(self.allocator, self.current_path);
    self.current_path = owned;
    // New navigation invalidates redo history.
    for (self.forward_stack.items) |p| self.allocator.free(p);
    self.forward_stack.clearRetainingCapacity();
    try self.loadCurrentDir();
}
```

Browser-style. `goBack` / `goForward` swap one entry between stacks. Strings
are owned by `allocator` and only freed when popped from a stack without
re-use.

### 4. Arena-per-view for transient data

The grid's `current_entries` strings live in a dedicated `dir_arena` that is
**reset** (`reset(.retain_capacity)`) on every navigation:

```zig
pub fn loadCurrentDir(self: *AppState) !void {
    _ = self.dir_arena.reset(.retain_capacity);
    self.current_entries.clearRetainingCapacity();
    self.selected_path = null;
    // ...repopulate from std.Io.Dir.iterate...
}
```

This is the cheapest way to swap a "page" of data: no per-entry frees, just one
bulk reset. The trick generalizes to any view whose data has a clear lifetime
boundary (route changes, dialog opens, etc.).

### 5. Breadcrumb path splitter

`top_bar.zig` walks an absolute path once and emits `(label, prefix_slice)`
pairs that point back into the original buffer. No allocations per segment, no
copies — clicking a crumb just dispatches `.{ .navigate_to = prefix_slice }`
and the reducer does the rest.

### 6. Click handlers via static `EventBinding`

For simple buttons no closure capture is needed:

```zig
.events = &.{.{ .event = .click, .msg = .{ .navigate_to = target_path } }},
```

The slice contents must outlive the build pass — using `build_arena`
allocations or pointers into long-lived state both work.

## Reducer message catalogue

| Message            | Effect                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `tree_msg`         | All sidebar tree events (click, toggle, drag/drop, tick).           |
| `tick`             | Per-frame engine tick; forwarded to tree to clean up drag state.    |
| `navigate_to`      | Push current path to back stack, switch to target, reload entries.  |
| `navigate_back`    | Pop back stack, push current to forward stack.                      |
| `navigate_forward` | Inverse of back.                                                    |
| `navigate_up`      | Navigate to `dirname(current_path)` if not at root.                 |
| `refresh`          | Reload `current_entries` without changing path.                     |
| `grid_click`       | Folder → `navigateTo`. File → toggle `selected_path`.               |
| `new_folder`       | Create unique-named subdirectory and refresh.                       |
| `delete_selected`  | Recursively remove selected path, clear selection, refresh.         |

## Reducer message catalogue (added)

| Message            | Effect                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `begin_path_edit`  | Switch breadcrumb strip to a focused `textInput`.                   |
| `submit_path_edit` | Read the input buffer and `navigateTo` the trimmed value.           |
| `cancel_path_edit` | Drop edit mode without navigating.                                  |
| `path_input_event` | Forwards `key_down` from the input — submits on Enter, cancels Esc. |
| `search_letter`    | Posted by the global key shortcut; jumps grid selection by letter.  |

## Global key shortcut wiring

```zig
app.setShortcutHandler(&app.state, letterShortcut);
```

The handler runs **before** focus-aware key dispatch. It returns `false` while
`state.editing_path` is true so the path-input keeps receiving keystrokes;
otherwise letter keys are consumed and a `search_letter` message is posted via
`app.postMessageId`. This is the canonical pattern for app-wide shortcuts that
need access to mutable state — store an `app` pointer in a module-scope `var`,
post messages, and let the reducer mutate.

## Limitations / future work

- No file preview pane.
- Typeahead is single-letter; combining presses into a prefix with a debounce
  window would make it nicer.
- Sorting is hardcoded (folders first, then case-insensitive name).
- Sidebar tree only roots at startup `cwd`. Pinning arbitrary paths would
  require multiple `FsNode` roots and a list rendered above the tree.
