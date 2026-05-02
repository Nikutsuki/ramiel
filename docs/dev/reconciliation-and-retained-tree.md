# Reconciliation and the Retained Tree

`ui.reconcile(new_root)` (`src/ui/context.zig`) patches the retained tree from a fresh build-arena descriptor tree.

## Identity

`NodeId` is the stable identity:

- Anonymous nodes survive reconcile by structural position (within their parent's children).
- Nodes with explicit IDs survive by ID.
- `lib.declareIds` and `comp.deriveChildId` are the two ID-namespacing tools — use both, never hand-roll integer IDs.

## Match strategy

For each child descriptor, in `reconcileNode`:

1. Match by `NodeId` if present.
2. Otherwise positional match with matching payload tag.
3. Unmatched descriptor → promote into retained allocator (GPA).
4. Unmatched retained child → deinit + remove.

## Payload patching

- `text` — content replaced only when changed; layout dirty if metrics shift.
- `text_input` — live buffer + cursor preserved across reconcile when payload type stays `text_input`.
- `image` — texture id / tint / custom fields update in place.
- `canvas` — same target pointer kept; descriptor swaps trigger payload replacement.

## Style patching

`patchStyle` writes the full new style, then registers transition animations for properties whose `TransitionProperty` bit is set on the *new* style and whose value differs.

Nodes without `NodeId` cannot be addressed by the animation registry → property changes snap.

## Interaction safety

When a node is removed:

- `interaction_registry` clears focus/hover/selection/active_drag pointers if they referenced it.
- Pending node animations are cancelled.
- Children are recursed.

Same when reconcile replaces a payload type (e.g. `image` → `canvas`).

## Allocator regimes

- Build-arena nodes: created via `ui.div` etc. Bulk-freed after reconcile.
- Retained nodes: GPA-owned. `dupeMessageBinding` clones event bindings into the retained allocator on promotion.
- After reconcile: `build_arena.reset(.retain_capacity)`.

## Invariants

- No stale `*Node` pointers held outside the retained tree across rebuilds (build-arena nodes get freed).
- Stable IDs for stateful subtrees (text inputs, scroll containers, animated nodes).
- Payload type changes are payload-replacements, not in-place mutations — the old payload deinits.

## References

- `src/ui/context.zig::reconcile`
- `src/ui/context.zig::reconcileNode`
- `src/ui/node.zig::dupeMessageBinding`
- `src/root.zig::declareIds`, `bindTag`, `deriveChildId`
