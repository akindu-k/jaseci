# Partial Updates Plan

Design for incremental, field-level anchor updates in Jaclang / Jaseci, building on
PR [#5387](https://github.com/jaseci-labs/jaseci/pull/5387) (`ref_mode` serializer) and
PR [#5554](https://github.com/jaseci-labs/jaseci/pull/5554) (custom `obj` types as walker /
`@restspec` body parameters).

---

## 1. Problem statement

Today the persistence layer treats an anchor as an atomic unit:

- [_anchor_to_row](jac/jaclang/runtimelib/impl/memory.impl.jac#L23) and
  [_anchor_to_doc](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L48) call
  `Serializer.serialize(anchor, include_type=True)` and dump the **entire** archetype
  (all `has` fields + edges + access + topology) into a single `data` JSON/BSON blob.
- [SqliteMemory.put](jac/jaclang/runtimelib/impl/memory.impl.jac#L550) issues
  `INSERT OR REPLACE INTO anchors … VALUES (?, …)` — the whole row is rewritten.
- [MongoBackend.put](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L225) issues
  `update_one({_id}, {$set: doc}, upsert=True)` where `doc` is the whole serialized anchor.
- [SqliteMemory.sync](jac/jaclang/runtimelib/impl/memory.impl.jac#L681) does dirty detection
  at *anchor* granularity (`_canonical_json(stored.archetype) != _canonical_json(anchor.archetype)`)
  and, on any diff, re-serializes + rewrites the full row.

Consequences:
1. Mutating `node.counter += 1` rewrites every other field, edge list, access entry, and
   topology blob on that node.
2. Large archetypes (long lists, nested objects, embedded binary in `topology_index_data`)
   pay O(size) write cost for any change.
3. Concurrent writes to disjoint fields of the same anchor race — last writer wins,
   silently clobbering the other field.
4. `@restspec` PATCH-style endpoints cannot express "update only these fields": the walker
   receives a *full* reconstructed archetype from the Pydantic body (PR 5554), so any field
   the client omitted defaults to the schema default and overwrites the stored value on
   flush.

## 2. What PR 5387 and PR 5554 give us

### PR 5387 — `ref_mode` serializer

- [Serializer.serialize(obj, ref_mode=True)](jac/jaclang/runtimelib/serializer.jac#L103)
  tracks visited archetype UUIDs in `_seen` and emits
  `{"$ref": "<uuid-hex>", "$type": "<kind>"}` for repeats instead of inlining.
- Each first-time Jac archetype encountered is registered via
  `Jac.get_context().mem.put(jac_anchor)` at
  [serializer.impl.jac#L141-L148](jac/jaclang/runtimelib/impl/serializer.impl.jac#L141-L148),
  so it persists *as its own row* rather than being embedded.
- [Serializer._deserialize_jac_ref](jac/jaclang/runtimelib/impl/serializer.impl.jac#L197)
  resolves `$ref` back to the live archetype on read, lazily populating stubs.

This is the primitive we need: **anchors can reference other anchors by UUID rather than
inline them**. A partial-update scheme can reuse this shape at the *field* level.

### PR 5554 — custom `obj` types at the HTTP boundary

- `APIParameter.type_obj` preserves the real Python type object alongside the stringified
  `data_type`.
- `_resolve_type(type_string, type_obj)` maps Jac archetypes → dynamic Pydantic models,
  handles `list[T]` / `dict[K,V]` / `T | None` recursively.
- `_build_pydantic_model(jac_cls)` mirrors a Jac archetype's `has` fields into a Pydantic
  `BaseModel`, with `ForwardRef` caching for self-referential types (`TreeNode`).
- `_pydantic_to_jac(...)` rebuilds actual Jac archetype instances from the validated body
  before the walker runs.

This gives us the round-trip machinery for typed, nested, validated JSON patches coming in
over HTTP. A partial-update endpoint can reuse `_resolve_type` / `_build_pydantic_model`
with all fields made `Optional` to express a PATCH body.

## 3. Design

Three layers. Each can ship independently; layer 1 is the hard requirement, layer 2
delivers most of the win, layer 3 is the HTTP surface.

### Layer 1 — dirty-field tracking on archetypes

Goal: at flush time, know *which fields* of an anchor were written since last persist.

1. **Per-archetype dirty set.**
   Add a non-persistent attribute on `Archetype` (parallel to `__jac__`):
   `_jac_dirty: set[str] | None`. It is `None` on a freshly-loaded anchor (everything is
   "clean"); becomes a `set` once any write happens.

2. **Instrument `__setattr__`.**
   Extend [Archetype.__setattr__](jac/jaclang/jac0core/impl/archetype.impl.jac#L289) so
   user-defined `has` fields (filtered via `dataclasses.fields(type(self))`) add their name
   to `self._jac_dirty` before delegating to `object.__setattr__`. Ignore writes to
   `__jac__`, `_jac_dirty`, and other dunder/internal names.

3. **Mutable-collection writes.**
   `list.append`, `dict[k] = v`, `set.add` do not go through `__setattr__`. Two options:
   - **(A) Coarse:** leave collection mutations as "replace whole field" — if the user
     assigned `self.items` at any point, mark `items` dirty and re-serialize that field.
     The existing `_compute_hash` in
     [memory.impl.jac](jac/jaclang/runtimelib/impl/memory.impl.jac) already catches
     mutations; we only need to *also* know *which* field changed. On mismatch, compare
     current vs. stored `_serialize_attrs` dict and derive the diff (one-shot, at sync
     time) — acceptable because the cost is still bounded by number of fields, not total
     payload.
   - **(B) Precise:** wrap `list` / `dict` / `set` collection values in jac-aware proxies
     that forward mutation events back to the owning archetype. More work, more invasive.
     Defer.

   Ship (A) first. Revisit (B) if profiling shows the diff step dominates.

4. **Clear on persist.**
   After a successful `put`/`sync`, set `anchor.archetype._jac_dirty = set()` and update
   `anchor.hash = Serializer._compute_hash(anchor)` as today. After a fresh load from L3,
   set `_jac_dirty = None` (absent-means-clean, distinguishable from "empty set after
   flush").

**Exit criteria.** `node.archetype._jac_dirty` reflects the set of `has` fields written
since load/flush. Existing tests in
[test_memory_hierarchy.jac](jac-scale/jac_scale/tests/test_memory_hierarchy.jac) still
pass (hash invariants unchanged).

### Layer 2 — partial persistence at the storage boundary

Goal: when only *k* of *n* fields are dirty, write O(k) to the backend, not O(n).

#### 2a. Serializer: produce a field-level delta

Add a new helper mirroring `_serialize_attrs`:

```jac
static def _serialize_delta(
    `obj: object,
    fields: set[str],              # names to include
    include_type: bool,
    ref_mode: bool = False,
    _seen: (tuple[set, set] | None) = None
) -> dict[str, object];
```

Returns `{field_name: serialized_value}` for just the named fields, reusing
`_serialize_value` per entry. `$ref` logic from PR 5387 works unchanged: a dirty field
whose value is an already-persisted Jac archetype emits `{"$ref": …}`.

#### 2b. SQLite backend — JSON patch via `json_set`

SQLite 3.38+ ships `json_set` / `jsonb_set`. Path map:

| Dirty kind             | JSON path                                            |
|------------------------|------------------------------------------------------|
| archetype field `name` | `$.archetype.name`                                   |
| `edges` (NodeAnchor)   | `$.edges`                                            |
| `access`               | `$.access`                                           |
| `topology_index_data`  | `$.topology_index_data`                              |

New method on `PersistentMemory`:

```jac
def patch(anchor: Anchor, fields: (set[str] | None) = None) -> None abs;
```

[SqliteMemory.patch](jac/jaclang/runtimelib/impl/memory.impl.jac) implementation sketch:

```jac
impl SqliteMemory.patch(anchor: Anchor, fields: (set[str] | None) = None) -> None {
    if anchor is None or not anchor.persistent { return; }
    dirty = fields if fields is not None else (
        anchor.archetype._jac_dirty if anchor.archetype else None
    );
    if not dirty {
        self.put(anchor);  # fallback: full rewrite (e.g. new anchor)
        return;
    }
    self._ensure_connection();
    delta = Serializer._serialize_delta(
        anchor.archetype, dirty, include_type=True
    );
    # Build a single json_set() call with alternating (path, value) pairs.
    path_value_pairs = [];
    for name in dirty {
        path_value_pairs.append(f"$.archetype.{name}");
        path_value_pairs.append(json.dumps(delta[name]));
    }
    # Edge-set / access changes hit top-level paths instead.
    ...
    self.__conn__.execute(
        "UPDATE anchors SET data = json_set(data, " + placeholders + "), "
        "updated_at = ? WHERE id = ?",
        tuple(path_value_pairs) + (now, str(anchor.id))
    );
    self.__conn__.commit();
    anchor.hash = Serializer._compute_hash(anchor);
    anchor.archetype._jac_dirty = set();
}
```

Row is rewritten on disk (SQLite MVCC cannot avoid that), but the serialization /
JSON-encode / IPC surface is proportional to dirty-field count. That is the measurable
win on large anchors.

**Schema drift.** If `fingerprint` changed (archetype schema bump), fall back to full
`put` — partial update cannot be reasoned about across drifts. Reuse the existing
quarantine path on deserialize errors.

#### 2c. Mongo backend — native `$set` on subpaths

Mongo is the bigger win: subdocument `$set` genuinely writes only the affected subtree.

```jac
impl MongoBackend.patch(anchor: Anchor, fields: (set[str] | None) = None) -> None {
    dirty = fields if fields is not None else (
        anchor.archetype._jac_dirty if anchor.archetype else None
    );
    if not dirty { self.put(anchor); return; }
    delta = Serializer._serialize_delta(
        anchor.archetype, dirty, include_type=True
    );
    set_doc = {f"data.archetype.{k}": v for (k, v) in delta.items()};
    set_doc["updated_at"] = datetime.now(timezone.utc).isoformat();
    self.collection.update_one({'_id': str(anchor.id)}, {'$set': set_doc});
    anchor.hash = Serializer._compute_hash(anchor);
    anchor.archetype._jac_dirty = set();
}
```

For edge / access / topology mutations, map to `data.edges`, `data.access`,
`data.topology_index_data` respectively.

#### 2d. Sync integration

Rewrite [SqliteMemory.sync](jac/jaclang/runtimelib/impl/memory.impl.jac#L681) and
[MongoBackend.sync](jac-scale/jac_scale/impl/memory_hierarchy.mongo.impl.jac#L343) to call
`patch(anchor)` instead of the full `put(anchor)` when
`anchor.archetype._jac_dirty` is a non-empty set. Fall back to `put` when:
- anchor row doesn't yet exist in backend (new anchor — full insert),
- `anchor.hash == 0` (first-time persist),
- serializer delta raises / schema fingerprint mismatches,
- `_jac_dirty is None` but `_compute_hash(anchor) != anchor.hash` (unknown dirty set —
  diff stored vs. current, treat that diff as the dirty set; see Layer 1 option A).

### Layer 3 — PATCH semantics at the HTTP / walker boundary

Goal: a REST call `PATCH /walker/UpdateUser {name: "new"}` updates *only* `name`, not
`age`, on the target node.

#### 3a. New `@restspec` verb: `patch` (or `partial=True`)

- Extend the existing registration path in jac-scale so `@restspec(method="PATCH", ...)`
  (or an equivalent marker) produces a walker whose body model is the **all-optional**
  variant of the archetype's Pydantic model.

#### 3b. Optional-model builder

Add to jac-scale (same module as `_build_pydantic_model`):

```python
def _build_pydantic_patch_model(jac_cls):
    """Mirror of _build_pydantic_model but wraps every field in Optional[T] with
    default=UNSET so '`missing` != explicit null'."""
```

Use Pydantic v2's `model.model_fields_set` on the parsed body to know exactly which
fields the caller *explicitly sent*. That set becomes the initial dirty set.

#### 3c. Apply to the live anchor

Instead of constructing a fresh archetype via `_pydantic_to_jac` and replacing
`anchor.archetype`, iterate `model.model_fields_set` and assign each field onto the
already-loaded anchor:

```python
for fname in body.model_fields_set:
    val = getattr(body, fname)
    # _pydantic_to_jac already handles nested archetype → Jac conversion per value.
    setattr(anchor.archetype, fname, _pydantic_value_to_jac(val, type_hint[fname]))
```

`Archetype.__setattr__` from Layer 1 populates `_jac_dirty` automatically. Walker flush
→ `patch(anchor)` from Layer 2 → backend-level partial write.

#### 3d. Nested partial updates (follow-up)

For a nested archetype field like `user.address`, a caller sending
`{"address": {"city": "X"}}` should patch only `city`, not clobber `address.street`.
Requires the patch model to be recursive: each nested `_build_pydantic_patch_model`
itself produces a patch model, and `_pydantic_to_jac` recurses similarly. Land this as a
follow-up once Layer 3a/b/c ship.

## 4. Public API summary

| Surface                                           | New / changed                                          |
|---------------------------------------------------|--------------------------------------------------------|
| `Serializer._serialize_delta(obj, fields, …)`     | new static helper                                      |
| `Archetype._jac_dirty: set[str] \| None`          | new non-persistent attribute                           |
| `Archetype.__setattr__`                           | updated to track dirty fields                          |
| `Memory.patch(anchor, fields=None)`               | new abstract method                                    |
| `SqliteMemory.patch` / `MongoBackend.patch`       | new concrete implementations                           |
| `SqliteMemory.sync` / `MongoBackend.sync`         | route dirty anchors through `patch` instead of `put`   |
| `@restspec(method="PATCH", …)` in jac-scale       | new verb, all-optional body model                      |
| `_build_pydantic_patch_model(cls)`                | new builder (jac-scale `parameters` module)            |

No on-disk schema changes. Existing `data` JSON blobs remain readable; the patch path
mutates them in place via `json_set` / dotted-`$set`.

## 5. Testing

### Unit (jaclang runtime)
1. `test_dirty_tracking` — assign a field, assert name appears in `_jac_dirty`; flush,
   assert cleared.
2. `test_serialize_delta` — given dirty set `{"name"}`, assert output keys are
   exactly `{"name"}` and shape matches `_serialize_attrs`' corresponding entry.
3. `test_setattr_ignored_fields` — assignments to `__jac__`, dunder names, and
   non-`has` attributes must NOT mark dirty.
4. `test_list_mutation_detected` — `self.items.append(x)` path: hash mismatch → sync
   derives dirty field via stored-vs-current diff (Layer 1 option A). Confirms
   correctness when `__setattr__` is bypassed.

### SQLite integration
5. `test_sqlite_patch_single_field` — persist anchor with 5 fields, patch 1, assert
   backend row's JSON has only that key changed, others byte-identical to prior
   serialization.
6. `test_sqlite_patch_edges` — patch `$.edges` independently of archetype fields.
7. `test_sqlite_patch_fingerprint_drift` — schema bump falls back to full `put`,
   logs at `info`.

### Mongo integration (jac-scale)
8. `test_mongo_partial_set` — watch the driver command log, assert
   `{$set: {"data.archetype.name": "x"}}` is issued (one key, not a wholesale doc
   replacement).
9. `test_mongo_patch_concurrent_disjoint_fields` — two clients patch disjoint fields of
   the same anchor concurrently; both writes survive (previously last-writer-wins).

### HTTP / walker (jac-scale)
10. `test_restspec_patch_omits_unspecified` — PATCH body `{name: "b"}` against node with
    `{name: "a", age: 30}` → `age == 30` after flush.
11. `test_restspec_patch_explicit_null` — body `{name: null}` actually writes `null`
    (present in `model_fields_set`), distinct from omission.
12. `test_restspec_patch_nested_obj_field` (Layer 3d, follow-up) — nested partial does
    not clobber sibling fields on the nested archetype.

## 6. Migration / compatibility

- No schema migration. `patch` paths coexist with `put` for new-anchor and
  fingerprint-drift cases.
- `ref_mode` from PR 5387 remains an opt-in serialize flag. Partial updates do not
  require `ref_mode=True`; however, the `$ref` discipline in `_serialize_value` (register
  archetype → `mem.put`) composes cleanly with per-field patches when a dirty field's
  value is itself a Jac archetype.
- Old clients calling `put` still get full-row rewrites — behavior unchanged for them.
- Pre-ref_mode anchors persisted as monolithic blobs remain loadable; partial updates
  apply to them directly (the JSON path targets exist in every blob shape we emit).

## 7. Phasing

1. **Phase 1 (prereq):** Layer 1 — `__setattr__` dirty tracking + serializer delta +
   unit tests 1–4. Low risk, no behavior change at the persistence layer.
2. **Phase 2:** Layer 2 — `patch()` on SQLite + Mongo; wire `sync` to prefer `patch`.
   Tests 5–9. Guarded by a runtime config flag (`jac.partial_updates = True`) so we can
   disable without reverting.
3. **Phase 3:** Layer 3 — `@restspec(method="PATCH")` + all-optional body models +
   `model_fields_set`-driven application. Tests 10–11.
4. **Phase 4 (follow-up):** recursive nested partial updates. Test 12.

## 8. Open questions

1. Do we want a user-facing `with jac.patch(node) as p: p.name = "x"` context manager as
   a first-class API, distinct from the implicit-via-`__setattr__` flow? Nice for
   auditability; adds API surface. Defer unless requested.
2. For L2 cache (`LocalCacheMemory`, Redis), do we also teach `patch` to do a
   subdocument update, or continue to invalidate-and-refetch on every write? Redis
   `JSON.SET` supports it; decide alongside Phase 2 once we see real cache hit patterns.
3. Access control granularity: today `check_write_access(anchor)` is per-anchor. Do we
   want per-field access lists? Out of scope here — if we ever do, the dirty set is the
   natural hook point.
