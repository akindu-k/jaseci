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

Deserialization needs no changes: `_deserialize_value` at
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

### Layer 4 — concurrency (edges race, #5451)

Layer 3 shrinks the write surface per mutation but does not serialize concurrent writes
to *the same* archetype row. The repro in
[#5451](https://github.com/jaseci-labs/jaseci/issues/5451) — two walkers both appending
an edge to Root — is a concurrent write to `Root.edges`, which is a single field on a
single row. Layers 1–3 do not fix this.

Two narrow mechanisms — neither requires field-level dirty tracking, neither requires a
walker-level transaction manager:

**4.1 Mongo `$addToSet` / `$pull` for edges.**

The `edges` field on NodeAnchor is semantically a set of EdgeAnchor UUIDs. Swap the
full `$set: {data.edges: [...]}` write for an atomic element-level operator:

```jac
# jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac
#
# When the only change on this anchor is additions/removals to edges,
# emit targeted array ops instead of a full $set.
impl MongoBackend._put_edges_delta(anchor: NodeAnchor, added: set, removed: set) {
    ops = {};
    if added   { ops['$addToSet'] = {'data.edges': {'$each': list(added)}}; }
    if removed { ops['$pull']     = {'data.edges': {'$in': list(removed)}}; }
    self.collection.update_one({'_id': str(anchor.id)}, ops);
}
```

Detecting "only edges changed" is cheap: compare `anchor.edges` vs. the previously
flushed snapshot (store `anchor._edges_flushed_snapshot` on every successful put — one
allocation per flush). If the archetype itself is unchanged and only edges differ, use
the delta path. Otherwise, fall through to the full-row `put`.

Two concurrent walkers each doing `root._jac_.edges.append(e)` both land via
`$addToSet` — no race, no retry, no CAS. This directly closes #5451.

**4.2 Optimistic version check for non-edges writes (opt-in).**

Edges cover #5451. For the general case of two walkers racing on the same scalar or
nested-object field, add a version column and a CAS:

- `anchors` gets `version INTEGER NOT NULL DEFAULT 0` (SQLite) / `version` field
  (Mongo).
- `put` writes `UPDATE ... SET data=?, version=? WHERE id=? AND version=?` (SQLite) or
  `update_one({_id, version: N}, {$set: {data, …}, $inc: {version: 1}})` (Mongo).
- On version mismatch: reload, re-serialize (still per-archetype), retry up to
  `jac.cas_max_retries` (default 3). On exhaustion raise `ConcurrentWriteExhausted`.

This is NOT needed to close #5451 — 4.1 alone closes it — and is NOT required for
partial updates to work. Ship it behind `jac.optimistic_cas` as a follow-up. Keep the
naive last-writer-wins behavior for scalar fields as the default; most deployments are
fine with it once the big-blob-overwrite problem is gone.

## 5. Public API summary

| Surface                                                 | New / changed                                              |
|---------------------------------------------------------|------------------------------------------------------------|
| `Serializer.serialize(..., storage_mode: bool = False)` | new flag, always-ref for nested archetypes                 |
| `_serialize_value` Archetype branch                     | emits `$ref` under `storage_mode` instead of inlining      |
| `_anchor_to_row` / `_anchor_to_doc`                     | pass `storage_mode=True`                                   |
| `SqliteMemory.sync`                                     | hash-diff short-circuit (align with Mongo)                 |
| `_build_pydantic_patch_model(jac_cls)`                  | new, mirrors `_build_pydantic_model` with optional fields  |
| `@restspec(method="PATCH", …)` / PATCH verb on walkers  | new verb, uses patch body model                            |
| `MongoBackend._put_edges_delta`                         | `$addToSet` / `$pull` fast path (Layer 4.1)                |
| `anchor.version: int` (optional, Layer 4.2)             | CAS column/field, opt-in via `jac.optimistic_cas`          |
| `ConcurrentWriteExhausted` (optional, Layer 4.2)        | new exception                                              |

No on-disk schema changes required for Layers 1–3. Existing rows — inlined blobs from
before this change — remain loadable: deserialization of an inlined nested archetype
still works (the old code path). Rows rewritten after the switch carry the `$ref` shape.
Deserializer accepts both. Layer 4.2 adds a nullable `version` column as an idempotent
`ALTER` / lazy-default field.

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
    distinct edge to Root; assert all N edges present after flush. With 4.1's
    `$addToSet` path, passes without any retry. Direct repro of #5451.
13. `test_5451_concurrent_edge_appends_sqlite` — same with SQLite; relies on 4.2 CAS.
    Under `jac.optimistic_cas = False`, documents the known last-writer-wins behavior.
14. `test_cas_version_mismatch_retries` (Layer 4.2) — artificial conflict; assert
    bounded retry and correct final state.

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
- **Layer 4.2 schema.** `version INTEGER NOT NULL DEFAULT 0` added idempotently by
  `_ensure_connection`; Mongo treats absent `version` as 0. Disable via
  `jac.optimistic_cas = false` in `jac.toml` for single-writer dev loops.

## 8. Phasing

1. **Phase 1 (Layer 1).** Add `storage_mode` to the serializer. Tests 1–5. No callers
   opt in yet — behavior unchanged for all existing paths.
2. **Phase 2 (Layer 2).** Flip `_anchor_to_row` and `_anchor_to_doc` to
   `storage_mode=True`. Add SQLite hash-diff short-circuit. Tests 6–8. This is where
   partial updates ship end-to-end.
3. **Phase 3 (Layer 3.1–3.2).** PATCH verb + all-optional body model + `model_fields_set`
   application. Tests 9–10.
4. **Phase 4 (Layer 4.1).** Mongo `$addToSet` / `$pull` edges fast path. Test 12.
   Closes #5451 on the deployment target that actually hits it (the reported incident
   was Mongo-backed).
5. **Phase 5 (Layer 4.2, follow-up).** Version column + CAS + retry. Tests 13–14.
   Opt-in, ships only when a concrete use-case outside of edges motivates it.
6. **Phase 6 (Layer 3.3, follow-up).** Recursive nested PATCH. Test 11.

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
3. **List-field ordering under concurrent writes (non-edges).** If two walkers append
   to a non-edges list on the same archetype, 4.1's set operators don't apply (list
   may have duplicates / care about order). Without 4.2 CAS, behavior is
   last-writer-wins on the list field. Document; offer CAS as the fix.
4. **Access control on refs.** `Jac.check_write_access(anchor)` runs per anchor. When
   a parent `$ref`s a child the caller lacks write access to, and the child is
   independently writable, today's per-anchor check handles this correctly. Confirm
   with an explicit test in Phase 2.
