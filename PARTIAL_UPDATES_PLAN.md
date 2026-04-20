# Partial Updates Plan

Design for incremental anchor updates in Jaclang / Jaseci, built on PR
[#5387](https://github.com/jaseci-labs/jaseci/pull/5387)'s `(type, jid)` identity model
and PR [#5554](https://github.com/jaseci-labs/jaseci/pull/5554)'s typed walker /
`@restspec` body handling.

Core idea: **the partial-update unit is an archetype row, keyed by `(type, jid)` — not
a field inside a blob.** Each archetype lives in its own row. A mutation anywhere in the
graph re-persists only the specific `(type, jid)` rows whose contents changed; their
parents and siblings are untouched.

---

## 1. Problem statement

Today the persistence layer stores a NodeAnchor / EdgeAnchor as a monolithic JSON blob
with the entire archetype (and all nested archetypes) inlined under `data.archetype`:

- [_anchor_to_row](jac/jaclang/runtimelib/impl/memory.impl.jac#L23) and
  [_anchor_to_doc](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L48) call
  `Serializer.serialize(anchor, include_type=True)` with no `ref_mode`. Nested archetypes
  inside the archetype are fully inlined.
- [SqliteMemory.put](jac/jaclang/runtimelib/impl/memory.impl.jac#L550) and
  [MongoBackend.put](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L225)
  rewrite the whole row on every change.

Consequences:
1. Mutating `root.profile.display_name` rewrites Root's full blob — including every
   edge, access entry, topology index, and every other inlined archetype.
2. A nested archetype has *two* representations on disk: inlined inside its parent's
   row, and (when `ref_mode=True`) as a standalone anchor row created by
   `mem.put(jac_anchor)` in
   [serializer.impl.jac#L141](jac/jaclang/runtimelib/impl/serializer.impl.jac#L141).
   They drift.
3. Graph traversals that touch N archetypes cost O(N × blob_size) to persist, when
   only O(N × local_fields) actually changed.

## 2. What PR 5387 gives us

PR 5387 introduces the primitive we need:

- Every Jac archetype has `(type, jid)` identity. Serialization can emit
  `{"$ref": jid.hex, "$type": "node" | "edge" | "walker" | "object"}` at
  [serializer.impl.jac#L136](jac/jaclang/runtimelib/impl/serializer.impl.jac#L136).
- Deserialization resolves refs back to live archetypes via
  [_deserialize_jac_ref](jac/jaclang/runtimelib/impl/serializer.impl.jac#L197) →
  `mem.get(uuid)` with lazy stub fallback.
- First-sighting of a Jac archetype in a given `serialize()` call registers it via
  `Jac.get_context().mem.put(jac_anchor)` — so the referenced archetype is persisted as
  its own standalone row.

But PR 5387's `ref_mode` is scoped per-call (`_seen` is reset every `serialize()`), so
it only dedupes *within* one serialization. Across the sync loop, each parent's
`serialize()` gets a fresh `_seen`, and the nested archetype is inlined again in every
parent that references it.

We extend this: a new serialization mode — **always-ref for nested archetypes** — that
makes each `(type, jid)` authoritative in exactly one row, referenced from elsewhere.

## 3. Approach: graph-flat persistence via always-ref

### 3.1 Current shape (inline-everything)

```
anchors table
  Root (NodeAnchor, uuid=R)
    data = { archetype: {
               profile: { __type__: Profile, display_name: "Alice", avatar: {...} },
               ...
             },
             edges: [e1, e2, e3] }
```

Mutating `profile.display_name` → rewrite the entire Root row.

### 3.2 Target shape (always-ref)

```
anchors table
  Root (NodeAnchor, uuid=R)
    data = { archetype: {
               profile: { $ref: P, $type: "object" },   ← pointer, not inline
               ...
             },
             edges: [e1, e2, e3] }
  Profile (ObjectAnchor, uuid=P)
    data = { archetype: { display_name: "Alice", avatar: { $ref: A, $type: "object" } } }
  Avatar (ObjectAnchor, uuid=A)
    data = { archetype: { url: "...", width: 128 } }
```

Mutating `profile.display_name`:
- Profile's archetype hash changes → Profile row (P) rewritten.
- Root's blob still says `{ $ref: P }` — byte-identical — so Root's hash does not
  change → Root row not touched. Same for Avatar.

This is the partial update. It is *per-archetype*, which is the right granularity for
this codebase because:
- `(type, jid)` is already the unit of identity at load time (`mem.get(uuid)`), access
  control (`anchor.access`), and drift detection (per-class `__jac_fingerprint__`).
- Existing dirty detection — `_compute_hash(anchor) == anchor.hash` in
  [MongoBackend.sync](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L353) —
  already skips unchanged anchors at exactly this granularity. The hash just happens to
  be too coarse today because *the blob is too large*. Shrinking the blob to own-fields
  only makes the existing mechanism effective.

No new dirty-field tracking, no JSON-path patches, no op logs. Just: make each
archetype's row contain only its own fields + refs, and the existing per-anchor
hash-diff sync becomes the partial-update mechanism for free.

## 4. Design

### Layer 1 — serializer: `storage_mode` (always-ref for nested archetypes)

Extend [Serializer.serialize](jac/jaclang/runtimelib/serializer.jac#L103) with a new
flag:

```jac
static def serialize(
    `obj: object,
    include_type: bool = False,
    api_mode: bool = False,
    ref_mode: bool = False,
    storage_mode: bool = False      # new
) -> object;
```

Semantics of `storage_mode=True` (in
[_serialize_value](jac/jaclang/runtimelib/impl/serializer.impl.jac#L37)):

1. Top-level Anchor branch (`isinstance(val, Anchor)`): unchanged — the Anchor's
   archetype is inlined in its own row's blob (otherwise the row would be empty).
2. **Nested Archetype branch (`isinstance(val, Archetype)`):** if `val` has a
   `__jac__` anchor (every user archetype does via `Archetype.__init_subclass__`):
   - Always emit `{"$ref": val.__jac__.id.hex, "$type": <kind>}`.
   - Call `Jac.get_context().mem.put(val.__jac__)` to ensure the referenced archetype
     is scheduled for its own row write.
   - Do NOT fall through to `_serialize_attrs(val)`. The referenced row is the
     authoritative copy.
3. Archetype without `__jac__` (rare — literal archetype subclass used as a value
   type, no identity): fall back to the current inline behavior.
4. Collections (list, tuple, dict, set) of archetypes: recurse; each element emits
   `$ref` by the above rule.
5. Primitives, UUIDs, enums, datetime, bytes, `Permission`, `Access`, plain
   `__dict__` objects: unchanged from today's `_serialize_value`.
6. **`set` / `frozenset`:** today's serializer lacks a `set` branch and falls through
   to the stringify fallback. Add a branch alongside `list`/`tuple`:
   ```jac
   if isinstance(val, (set, frozenset)) {
       items = [Serializer._serialize_value(v, ...) for v in val];
       items.sort(key=_stable_key);   # deterministic order for _compute_hash
       return {'__type__': 'set', 'items': items};
   }
   ```
   Deserializer dispatches `__type__: 'set'` back to `set(...)`. Uniform with
   `storage_mode=True`: a `set[Profile]` field becomes
   `{"__type__": "set", "items": [{"$ref": P1, …}, {"$ref": P2, …}]}`. Stable sort is
   required so mutations to unrelated fields don't perturb the hash via iteration
   reordering.

Deserialization needs no changes for `$ref`: `_deserialize_value` at
[serializer.impl.jac#L281](jac/jaclang/runtimelib/impl/serializer.impl.jac#L281) already
detects `$ref` and dispatches to `_deserialize_jac_ref`.

**Corner case — unpopulated parent.** When an archetype was loaded lazily and hasn't
been populated, `val.__jac__` exists but its archetype is a stub. `storage_mode` still
emits `$ref` for it (the jid is stable across populate/depopulate). No need to populate
solely to serialize a reference.

**Corner case — NodeAnchor.edges.** Edges are already a `list[str(uuid)]` of EdgeAnchor
UUIDs at
[serializer.impl.jac#L98](jac/jaclang/runtimelib/impl/serializer.impl.jac#L98) — already
ref-like, just via a bespoke format. Leave as-is. EdgeAnchors get their own rows via
the existing Anchor code path.

**Corner case — ref to archetype owned by another root.** `mem.put` handles
cross-root scheduling; access-control checks (`Jac.check_write_access`) still apply per
referenced anchor before each write.

### Layer 2 — persistence: use `storage_mode=True` and rely on per-anchor hash diff

One-line change in each backend helper:

```jac
# jac/jaclang/runtimelib/impl/memory.impl.jac  (_anchor_to_row)
data = Serializer.serialize(anchor, include_type=True, storage_mode=True);

# jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac  (_anchor_to_doc)
data = Serializer.serialize(anchor, include_type=True, storage_mode=True);
```

Then tighten the sync loops to lean on the hash diff we already compute:

- **MongoBackend.sync** at
  [memory_hierarchy.mongo.impl.jac#L343](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L343)
  already uses `if current_hash == anchor.hash { continue; }`. Nothing to change —
  once blobs shrink, this becomes a true partial-update skip for unchanged anchors.
- **SqliteMemory.sync** at
  [memory.impl.jac#L681](jac/jaclang/runtimelib/impl/memory.impl.jac#L681) currently
  does a more expensive `_canonical_json(stored.archetype) != _canonical_json(anchor.archetype)`
  diff. Replace with the same hash-short-circuit:
  ```jac
  if Serializer._compute_hash(anchor) == anchor.hash { continue; }
  ```
  Keep the edge/access/archetype branch logic for the cases that *do* need an update —
  but now those writes are scoped to the one anchor whose hash changed, not every
  anchor in the graph.

**What happens on a graph mutation:**

1. Walker runs, mutates `profile.display_name`.
2. Walker ends → `Jac.get_context().mem.sync()`.
3. Sync iterates `__mem__`:
   - Root: hash unchanged (its blob is still `{profile: {$ref: P}, edges: […]}`) →
     skip.
   - Profile: hash changed → re-serialize (`storage_mode=True` emits own fields only,
     plus `{$ref: A}` for avatar) → single-row write.
   - Avatar: hash unchanged → skip.
4. One row written, proportional to Profile's own field count.

### Layer 3 — HTTP / walker partial updates

PR 5554 already types walker / `@restspec` body parameters as real Jac archetypes via
`_build_pydantic_model` and reconstructs archetype instances via `_pydantic_to_jac`.
Partial updates at the HTTP boundary need two small pieces on top:

1. **All-optional body model for PATCH verbs.** New
   `_build_pydantic_patch_model(jac_cls)` in the same jac-scale parameters module that
   owns `_build_pydantic_model`. Mirrors the existing builder but wraps every field in
   `Optional[T]` with a sentinel default so "field absent in body" is distinguishable
   from "field explicitly sent as null".

2. **Apply only explicitly-sent fields.** After Pydantic validation, `body.model_fields_set`
   gives the set of fields the caller actually sent. Instead of calling
   `_pydantic_to_jac` to build a fresh archetype and assign it wholesale, iterate
   `model_fields_set` and assign each field onto the *existing loaded archetype*:

   ```python
   target = Jac.get_context().mem.get(target_id).archetype
   for fname in body.model_fields_set:
       setattr(target, fname, _pydantic_value_to_jac(getattr(body, fname), hints[fname]))
   ```

   `setattr` on a nested archetype field just rebinds that field on `target`; if the
   new value is itself an archetype with a `__jac__`, it participates in Layer 1's
   always-ref dance on next serialize.

3. **Nested PATCH (follow-up).** For `PATCH /user/{id} {"profile": {"display_name": "X"}}`
   we want to recurse: find the existing `target.profile`, `setattr` only
   `display_name` on it, don't touch `avatar`. Requires the patch model builder to be
   recursive and `_pydantic_value_to_jac` to locate-then-mutate instead of construct
   fresh. Ship after Layer 3.1 / 3.2.

### Layer 4 — concurrency on collection fields

Layers 1–3 shrink the write surface per mutation but don't serialize concurrent writes
to *the same* archetype row. The repro in
[#5451](https://github.com/jaseci-labs/jaseci/issues/5451) — two walkers both appending
to `Root.edges` — is one instance of the general problem: any concurrent mutation to a
shared list / dict / set field races the same way. Two walkers each doing
`self.tags.append("x")` will clobber each other exactly like edges do.

Layer 4 addresses this in three tiers. Tiers 4.2 and 4.3 are the fast path — they make
the race impossible at the backend level via atomic operators. Tier 4.4 is the escape
hatch when 4.2/4.3 can't express the mutation.

**4.1 Snapshot-based delta detection (shared primitive).**

On successful load or flush, record per-collection-field snapshots on the anchor —
shallow copies, not deep:

```jac
anchor._field_snapshots = {
    'tags':      list(anchor.archetype.tags),
    'edges':     list(anchor.edges),                 # NodeAnchor.edges
    'friends':   list(anchor.archetype.friends),
    'counts':    dict(anchor.archetype.counts),
    # … one entry per collection-typed `has` field
};
```

At flush time, per field:

```jac
curr   = current_value_of(field);
snap   = anchor._field_snapshots[field];
added  = elements_in(curr) - elements_in(snap);
removed = elements_in(snap) - elements_in(curr);
# for dict: changed_keys = {k for k in curr if curr[k] != snap.get(k)}
```

If *only* collection-field deltas changed (scalar fields and the archetype's own
hash-excluding-these-fields are unchanged), the backend takes the element-level path
(4.2 or 4.3). Otherwise, fall through to the full-row `put`. On success, refresh the
snapshots.

Memory cost: O(|collection|) per collection field per live anchor. Acceptable —
collections are the same shape as what's in `archetype.__dict__` already.

**4.2 Mongo element-level operators.**

Swap full-blob `$set` for targeted atomic ops by field semantics:

| Field typing / marker                             | Append / add                                  | Remove                                        |
|---------------------------------------------------|-----------------------------------------------|-----------------------------------------------|
| `set[T]`, `list[T]` + `@jac.set_semantics`, or `NodeAnchor.edges` | `$addToSet: {path: {$each: list(added)}}`     | `$pullAll: {path: list(removed)}`             |
| plain `list[T]` (ordered, dups allowed)           | `$push:     {path: {$each: list(added)}}`     | `$pullAll: {path: list(removed)}`             |
| `dict[str, V]` (scalar V)                         | `$set:      {"path.k": v}` per added/changed  | `$unset:    {"path.k": ""}` per removed       |
| `dict[str, Archetype]`                            | `$set:      {"path.k": {"$ref": …}}` per key  | `$unset:    {"path.k": ""}` per removed key   |

Example for a mixed append + remove on `NodeAnchor.edges`:

```jac
impl MongoBackend._put_collection_delta(anchor: Anchor, deltas: list) {
    ops: dict = {};
    for d in deltas {
        if d.op == 'addToSet' {
            ops.setdefault('$addToSet', {})[d.path] = {'$each': d.values};
        } elif d.op == 'push' {
            ops.setdefault('$push', {})[d.path] = {'$each': d.values};
        } elif d.op == 'pullAll' {
            ops.setdefault('$pullAll', {})[d.path] = d.values;
        } elif d.op == 'set' {
            ops.setdefault('$set', {})[d.path] = d.value;
        } elif d.op == 'unset' {
            ops.setdefault('$unset', {})[d.path] = "";
        }
    }
    self.collection.update_one({'_id': str(anchor.id)}, ops);
}
```

Two concurrent `tags.append("x")` / `tags.append("y")` both land via `$push` — no race,
no retry, no CAS. Same for `$addToSet`, `$set` on disjoint dict keys, `$pullAll` on
disjoint values.

**Ordering and duplicates — ordered `list[T]`.** Under `$push`, the final order is
"whichever Mongo applied first" — no client-visible guarantee across concurrent pushes.
For set-semantics fields, order doesn't matter and `$addToSet` also dedupes. For
ordered-list-with-position-matters (e.g., `log_entries[3] = …`), positional writes can't
be expressed atomically; fall through to 4.4 CAS.

**4.3 SQLite JSON1 element-level ops.**

SQLite has no native set operator, but it has JSON1 + single-writer semantics: any
single `UPDATE` statement runs under the write lock, so there's no Python-side
read-modify-write window. Emit:

```sql
-- Append (list, with duplicates allowed):
UPDATE anchors
   SET data = json_insert(data, '$.archetype.tags[#]', ?),
       updated_at = ?
 WHERE id = ?;

-- Set-semantics add (skip if present):
UPDATE anchors
   SET data = CASE
       WHEN NOT EXISTS (
           SELECT 1 FROM json_each(data, '$.archetype.tags')
            WHERE json_each.value = ?
       )
       THEN json_insert(data, '$.archetype.tags[#]', ?)
       ELSE data
   END,
   updated_at = ?
 WHERE id = ?;

-- Remove by value (drop all matches):
UPDATE anchors
   SET data = (
       SELECT json_group_array(value)
         FROM json_each(data, '$.archetype.tags')
        WHERE value != ?
   ) ... wrapped via json_set at the field path ...
 WHERE id = ?;

-- Dict key set:
UPDATE anchors
   SET data = json_set(data, '$.archetype.counts.k', ?)
 WHERE id = ?;

-- Dict key unset:
UPDATE anchors
   SET data = json_remove(data, '$.archetype.counts.k')
 WHERE id = ?;
```

Batched per anchor as a single statement (or a short chain in one transaction) so
concurrent writers serialize on SQLite's write lock rather than races in Python.

Requires SQLite 3.38+ for `->>` and modern `json_*` operators. Already present on every
platform we target (Python 3.11 bundles 3.40+).

**4.4 Optimistic version check — escape hatch.**

For mutations that don't fit 4.2/4.3 — positional list writes (`list[i] = v`, insert
at non-tail position), conflict-prone dict-value mutations, or anywhere the user wants
"fail on concurrent change" rather than "merge" semantics — add a version column and
retry:

- `anchors` gains `version INTEGER NOT NULL DEFAULT 0` (SQLite) / `version` field
  (Mongo).
- `put` writes `UPDATE … WHERE id=? AND version=?` / `update_one({_id, version:N}, …)`.
- On mismatch: reload from L3, re-apply the walker-side mutation against the reloaded
  anchor, retry up to `jac.cas_max_retries` (default 3). On exhaustion raise
  `ConcurrentWriteExhausted`.

Scoped narrowly — this is the rarely-hit fallback, not the main concurrency story.
Opt-in via `jac.optimistic_cas = true`. Default remains last-writer-wins for writes
that aren't covered by 4.2/4.3, which is fine now that the blob-overwrite problem is
gone.

**How #5451 is closed.**

- Mongo deployments (where the incident was reported): `NodeAnchor.edges` routes
  through 4.2 `$addToSet` / `$pullAll`. Concurrent `edges.append` calls land
  atomically, no retry. Test 12 in §6 is the direct repro.
- SQLite deployments: routes through 4.3's `json_insert` + set-semantics guard.
  Serialized on the write lock; no loss.
- Generalizes to any user-defined `set[T]` / `@jac.set_semantics list[T]` /
  `dict[K, V]` field — not just edges.

### Layer 5 — ownership on remove (opt-in)

Archetypes have independent identity. Removing a `$ref` from a list doesn't delete the
referenced archetype — by design: the same archetype may be referenced from elsewhere.
But some fields express true ownership: a `Post.comments` list where removing a
Comment means that Comment is gone. Make ownership opt-in at the field level.

**Default: reference semantics.** `self.friends.remove(p)` drops the `$ref` from the
parent; `p`'s own row remains until explicitly destroyed via `Jac.destroy(p)` /
`mem.delete(p.__jac__.id)`. This is the current behavior; just document it.

**Opt-in: `by owned` field modifier.** Extend the `has` field grammar:

```jac
node Post {
    has comments: list[Comment] by owned;     # removing from list → destroy
    has tags:     list[Tag];                   # default: reference
    has meta:     dict[str, Attachment] by owned;
}
```

`by owned` is a new clause alongside `by postinit`. Implementation:

1. Parser surface: accept `by owned` as a field modifier; store the flag in the
   generated dataclass field metadata.
2. Sync-time hook: when Layer 4.1's snapshot diff for an owned collection field shows
   `removed` elements that are Archetype refs, enqueue each for `mem.delete(jid)`
   after the parent's delta write succeeds.
3. Field-reassignment (`post.comments = new_list`): diff the old list vs. new list as
   above; destroy removed archetypes.
4. Access control: the destroy call still goes through `Jac.check_write_access` on the
   child. If the walker lacks permission, log and skip — the parent's delta still
   lands; the ownership cleanup is best-effort, surfaced via metrics.

The delete is ordered *after* the parent's element-level delta commits, so a crash
between the two leaves a dangling row rather than a dangling `$ref`. Dangling rows are
recoverable (Layer 5 deferred — reachability GC); dangling refs are not.

**Deferred: reachability GC.** Periodic mark-and-sweep from all roots to reap
unreachable archetypes (including cycles that reference counting can't handle). Exposed
as `jac db gc` plus an optional scheduled job in jac-scale. Large undertaking and
orthogonal to this plan — ship only when leaks are actually observed.

## 5. Public API summary

| Surface                                                 | New / changed                                              |
|---------------------------------------------------------|------------------------------------------------------------|
| `Serializer.serialize(..., storage_mode: bool = False)` | new flag, always-ref for nested archetypes                 |
| `_serialize_value` Archetype branch                     | emits `$ref` under `storage_mode` instead of inlining      |
| `_serialize_value` set/frozenset branch                 | new — `{"__type__": "set", "items": [...sorted...]}`       |
| `_anchor_to_row` / `_anchor_to_doc`                     | pass `storage_mode=True`                                   |
| `SqliteMemory.sync`                                     | hash-diff short-circuit (align with Mongo)                 |
| `_build_pydantic_patch_model(jac_cls)`                  | new, mirrors `_build_pydantic_model` with optional fields  |
| `@restspec(method="PATCH", …)` / PATCH verb on walkers  | new verb, uses patch body model                            |
| `anchor._field_snapshots: dict`                         | per-collection-field baseline for Layer 4.1 delta detection|
| `MongoBackend._put_collection_delta`                    | `$addToSet` / `$push` / `$pullAll` / `$set` / `$unset` routing (Layer 4.2) |
| `SqliteMemory._put_collection_delta`                    | `json_insert` / `json_remove` / `json_set` routing (Layer 4.3) |
| `@jac.set_semantics` field marker                       | treats `list[T]` as a set for 4.2/4.3 routing              |
| `anchor.version: int` (opt-in, Layer 4.4)               | CAS column/field, gated by `jac.optimistic_cas`            |
| `ConcurrentWriteExhausted` (opt-in, Layer 4.4)          | new exception, retry-exhaustion signal                     |
| `by owned` field modifier                               | opt-in ownership semantics; remove → `mem.delete` (Layer 5)|

No on-disk schema changes required for Layers 1–3. Existing rows — inlined blobs from
before this change — remain loadable: deserialization of an inlined nested archetype
still works (the old code path). Rows rewritten after the switch carry the `$ref`
shape; deserializer accepts both. Layer 4.4 adds a nullable `version` column as an
idempotent `ALTER` / lazy-default field.

## 6. Testing

### Serializer (Layer 1)
1. `test_storage_mode_emits_ref_for_nested_archetype` — parent archetype with a Jac
   object field; assert parent's serialization contains `{"$ref": …, "$type": "object"}`
   for that field, not an inlined dict.
2. `test_storage_mode_registers_nested_anchor` — after serializing a parent,
   `mem.get(nested_uuid)` returns the nested archetype's anchor.
3. `test_storage_mode_roundtrip` — serialize with `storage_mode=True`, then deserialize;
   reconstructed archetype `==` original; lazy stubs populate on first access.
4. `test_storage_mode_collections` — `list[Profile]`, `dict[str, Profile]`,
   `set[Profile]` all emit per-element `$ref`.
5. `test_storage_mode_cycle` — `self.parent = self`: emits one `$ref` back to self,
   deserializes to an identity cycle.

### Persistence (Layer 2)
6. `test_only_dirty_archetype_rewritten_sqlite` — build a 3-deep graph (Root → Profile
   → Avatar); mutate `avatar.url`; assert Avatar row's `updated_at` advanced; Root
   and Profile rows' `updated_at` unchanged.
7. Same as (6) for `test_only_dirty_archetype_rewritten_mongo` — inspect the command
   log, assert exactly one `update_one` fired for Avatar.
8. `test_inlined_legacy_row_still_loadable` — seed DB with an old-style inlined blob,
   load, mutate, flush, assert next load returns the `$ref`-shaped row.

### HTTP (Layer 3)
9. `test_restspec_patch_omits_unspecified` — PATCH `{name: "b"}` against node with
   `{name: "a", age: 30}`; `age == 30` post-flush; backend write touched only the
   affected archetype row.
10. `test_restspec_patch_explicit_null` — body `{name: null}` writes null (present in
    `model_fields_set`), distinct from omission.
11. `test_restspec_patch_nested_obj_field` (follow-up after Layer 3.3) — nested
    partial doesn't clobber sibling fields.

### Concurrency (Layer 4)
12. `test_5451_concurrent_edge_appends_mongo` — N concurrent walkers each append a
    distinct edge to Root; assert all N edges present after flush. Relies on 4.2
    `$addToSet`. Direct repro of #5451.
13. `test_5451_concurrent_edge_appends_sqlite` — N concurrent walkers append edges
    to Root via 4.3's `json_insert` set-semantics path; assert all N present.
14. `test_concurrent_list_append_user_field_mongo` — two walkers both do
    `self.tags.append(…)` on the same User; assert both appends land (plain-list
    `$push` path).
15. `test_concurrent_set_add_mongo` — `set[T]` field; two walkers add distinct values;
    assert both present. Same value from two walkers → idempotent.
16. `test_concurrent_dict_set_disjoint_keys` — walker A sets `counts["a"]=1`, walker B
    sets `counts["b"]=2`; assert both keys survive (disjoint `$set` paths).
17. `test_snapshot_delta_detection` — unit test for Layer 4.1: given before/after
    field values, compute `added`/`removed` correctly for list/set/dict.
18. `test_full_blob_fallback_on_scalar_change` — if any scalar field changed alongside
    collection ops, backend falls back to full-row `put` rather than emitting partial
    element ops.
19. `test_cas_version_mismatch_retries` (Layer 4.4) — artificial conflict on a
    positional list write (`list[i] = v`); assert bounded retry and correct final
    state.
20. `test_cas_exhaustion_raises` (Layer 4.4) — sustained conflict beyond
    `cas_max_retries`; assert `ConcurrentWriteExhausted`.

### Ownership (Layer 5)
21. `test_owned_field_destroys_on_remove` — `by owned` field; remove an element from
    the collection; assert `mem.delete` was called on that archetype's jid after the
    parent's delta commit.
22. `test_reference_field_keeps_row_on_remove` — default (non-owned) field; remove an
    element; assert the archetype's row still exists and is loadable.
23. `test_owned_field_reassignment_destroys_prior` — `post.comments = new_list`;
    assert elements in old list but not new list are destroyed.
24. `test_owned_delete_honors_access_control` — walker lacks write access to owned
    child; assert parent delta still lands, child delete is skipped + logged, no
    exception.

## 7. Migration / compatibility

- **Layers 1–3: zero schema change.** The storage columns/fields are the same. The
  `data` blob shape for nested archetypes changes from inlined to `$ref`, but
  deserialization handles both. Old rows are migrated opportunistically: next time
  an old-shape row is loaded and re-persisted, it re-emits in the new shape.
- **Dependent ordering.** When sync writes multiple rows in one pass (Root changed +
  Avatar changed), order is irrelevant because each row carries `$ref`s that resolve
  lazily at load time via `mem.get`. No foreign-key constraints.
- **Fingerprint drift.** Orthogonal. Each archetype carries its own
  `__jac_fingerprint__`, and the existing quarantine path at
  [memory.impl.jac#L730](jac/jaclang/runtimelib/impl/memory.impl.jac#L730) handles a
  row whose class no longer resolves — unchanged.
- **`api_mode` / `ref_mode`.** Preserved as today. `storage_mode` is a third,
  independent flag; callers choose based on audience (wire vs. API vs. storage).
  The three are composable (though only `storage_mode` + `include_type` is used by
  the persistence layer).
- **Layer 4.2 / 4.3: no schema change.** Element-level operators target the same
  `data` column; only the query shape changes.
- **Layer 4.4 schema.** `version INTEGER NOT NULL DEFAULT 0` added idempotently by
  `_ensure_connection`; Mongo treats absent `version` as 0. Disable via
  `jac.optimistic_cas = false` in `jac.toml` for single-writer dev loops.
- **SQLite version.** Layer 4.3 uses JSON1 operators (`json_insert`, `json_remove`,
  `json_each`, `json_group_array`) present since SQLite 3.38. Python 3.11+ bundles
  3.40+, so covered on all supported platforms. Feature-detect on startup and warn if
  missing; fall through to full-row `put` in that case.
- **Layer 5 grammar.** `by owned` is a new optional modifier on `has` declarations.
  Parse-level addition only; omitting it preserves today's reference semantics.

## 8. Phasing

1. **Phase 1 (Layer 1).** Add `storage_mode` + `set` branch to the serializer. Tests
   1–5. No callers opt in yet — behavior unchanged for all existing paths.
2. **Phase 2 (Layer 2).** Flip `_anchor_to_row` and `_anchor_to_doc` to
   `storage_mode=True`. Add SQLite hash-diff short-circuit. Tests 6–8. This is where
   partial updates ship end-to-end.
3. **Phase 3 (Layer 3.1–3.2).** PATCH verb + all-optional body model +
   `model_fields_set` application. Tests 9–10.
4. **Phase 4 (Layer 4.1 + 4.2).** Snapshot-based delta detection + Mongo element-level
   operators for all collection types. Tests 12, 14, 15, 16, 17, 18. Closes #5451 for
   Mongo deployments and generalizes to all user-defined collection fields.
5. **Phase 5 (Layer 4.3).** SQLite JSON1 element-level operators. Test 13. Closes
   #5451 for SQLite deployments.
6. **Phase 6 (Layer 4.4).** Version column + CAS + retry escape hatch. Tests 19–20.
   Opt-in, ships only for mutations 4.2/4.3 can't express (positional writes).
7. **Phase 7 (Layer 5).** `by owned` field modifier + ownership cleanup at flush.
   Tests 21–24.
8. **Phase 8 (Layer 3.3, follow-up).** Recursive nested PATCH. Test 11.

## 9. Open questions

1. **Auto-`$ref` for Archetype values that happen to lack `__jac__`.** Every user
   archetype has `__jac__` via `Archetype.__init_subclass__`, so "missing `__jac__`"
   only happens for mid-construction / transient instances. Treat as bug / fall back
   to inline? Inline seems safer — a transient archetype without identity shouldn't
   force the caller to think about persistence.
2. **"Seen in this call" still useful?** The existing `_seen` dedupe inside a single
   `serialize()` call becomes redundant when `storage_mode=True` (every nested
   archetype is always `$ref`, whether seen or not). Keep `_seen` for `ref_mode=True`
   (wire format), drop for `storage_mode=True` (no behavior change, cleaner code).
3. **Access control on refs.** `Jac.check_write_access(anchor)` runs per anchor. When
   a parent `$ref`s a child the caller lacks write access to, and the child is
   independently writable, today's per-anchor check handles this correctly. Confirm
   with an explicit test in Phase 2.
4. **Positional list mutations.** `log[3] = v` or `log.insert(2, v)` can't be
   expressed as atomic element ops — the correct index depends on what other writers
   have done. Route through 4.4 CAS; document that positional writes under contention
   incur retries.
5. **`@jac.set_semantics` ergonomics.** Do we infer set semantics from `type ==
   set[T]` alone, or require an explicit marker on `list[T]` that should be treated as
   a set? Current plan: auto-infer for `set[T]` / `frozenset[T]`, require
   `@jac.set_semantics` on `list[T]`. Straightforward; revisit if users find it
   surprising.
6. **Owned-field interaction with refs from elsewhere.** If a Comment is owned by
   Post A but also `$ref`'d from an unrelated UserProfile.recent_comments list, removing
   it from Post A will destroy the row and leave a dangling ref in UserProfile. Options:
   (a) document "ownership implies exclusive reference", (b) refcount-on-destroy
   (expensive), (c) defer destroy to reachability GC (Layer 5 deferred). Recommend (a)
   — ownership is the user's declaration of exclusive lifetime.
