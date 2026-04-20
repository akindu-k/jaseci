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

### Layer 4 — concurrency control (optimistic CAS + unit-of-work)

Goal: eliminate lost-update races like [#5451](https://github.com/jaseci-labs/jaseci/issues/5451) and address the broader concurrent-correctness concerns CAS alone does not: retry correctness, cross-anchor transactions, L2 coherence, livelock, semantic conflicts, idempotency.

Layer 4 extends Layers 1–2 rather than replacing them. Field-level dirty tracking from Layer 1 keeps CAS cheap (version check per anchor, delta scoped per field); the op log from §4b is a strict superset of Layer 1's `_jac_dirty` set.

#### 4a. Anchor version column / field

Add `version: int` to every anchor row/document. Monotonically increments on each successful write. Default 0 for new anchors.

- **SQLite:** `ALTER TABLE anchors ADD COLUMN version INTEGER NOT NULL DEFAULT 0` (idempotent, run from `_ensure_connection`).
- **Mongo:** new field `version`; treat missing as 0 during rollout.

All `put`/`patch` paths read current `anchor.version`, write with `version = N+1`, and condition the UPDATE on `version = N`:

```sql
UPDATE anchors
   SET data = json_set(data, …), version = ?, updated_at = ?
 WHERE id = ? AND version = ?
```

```python
collection.update_one(
    {'_id': str(anchor_id), 'version': N},
    {'$set': delta, '$inc': {'version': 1}}
)
```

Success = `rowcount == 1` / `matched_count == 1`. Anything else routes to §4d. Access-control checks (`Jac.check_write_access`) stay in their current position, *before* the CAS attempt.

#### 4b. Op log — "replay the intent, not the state"

Blind retry of a stale in-memory anchor reintroduces the lost-update bug. Retry must re-apply *what the walker intended to do*, not *what the walker currently holds*.

Replace Layer 1's `_jac_dirty: set[str] | None` with a richer `_jac_ops: list[Op] | None`, where `Op` is a tagged variant:

| Variant                        | Captured by                                   | Idempotent on replay? |
|--------------------------------|-----------------------------------------------|-----------------------|
| `SetField(name, value)`        | `__setattr__` on a `has` field                | yes (LWW within window) |
| `ListAppend(field, value)`     | proxied `list.append`                         | yes (skip if equal element exists) |
| `ListExtend(field, values)`    | proxied `list.extend` / `+=`                  | per-element |
| `ListRemove(field, value)`     | proxied `list.remove`                         | yes (skip if absent) |
| `ListSetAt(field, idx, value)` | proxied `list.__setitem__`                    | no (position-dependent — see §8) |
| `DictSet(field, key, value)`   | proxied `dict.__setitem__`                    | yes (LWW per key) |
| `DictDel(field, key)`          | proxied `dict.__delitem__`                    | yes (skip if absent) |
| `SetAdd(field, value)`         | proxied `set.add`                             | yes |
| `SetDiscard(field, value)`     | proxied `set.discard`                         | yes |
| `ReadField(name, snapshot)`    | explicit `jac.observed(expr)` in walker       | read-set (§4e) |

Collection values on loaded archetypes are wrapped in thin proxy classes (`_JacTrackedList`, `_JacTrackedDict`, `_JacTrackedSet`) on first access; mutations record ops on the owning archetype. `NodeAnchor.edges` in particular becomes a `_JacTrackedList`.

- `SetField` for whole-collection assignment (`self.items = [...]`) emits a replace op, *not* per-element appends — opt-out for last-writer-wins semantics.
- Equality for `ListAppend`/`ListRemove` on archetype references is by UUID, not by `__eq__` on the archetype (which would recurse through `$ref` graphs).

#### 4c. Unit-of-work per walker execution

Today each `mem.put` / `mem.sync` call runs independently. Layer 4 introduces a per-walker-execution commit boundary.

- `ExecutionContext` tracks every anchor touched during the current walker run (populated as `_jac_ops` accumulates).
- At walker completion (or explicit `Jac.commit()`):
  1. Open a backend transaction — SQLite `BEGIN IMMEDIATE`; Mongo `session.with_transaction(...)`.
  2. For each touched anchor: produce delta from `_jac_ops`, issue version-checked UPDATE.
  3. All UPDATEs match → commit. Clear op logs; bump in-memory `anchor.version`.
  4. Any UPDATE fails on version → abort, proceed to §4d.

Per-anchor CAS without a transaction can land anchor A but fail anchor B, leaving partial state. SQLite transactions are cheap; Mongo transactions require a replica set and have modest overhead — acceptable at walker-flush granularity. Standalone Mongo falls back to per-anchor CAS with a startup warning (see §8).

#### 4d. Retry policy

On conflict, retry at *persistence* level first — not walker level:

1. Reload conflicting anchors from L3 (bypass L1/L2).
2. Re-apply each anchor's `_jac_ops` against the reloaded archetype (idempotent per §4b).
3. Recompute delta; re-open transaction; re-issue version-checked UPDATEs.
4. On repeated conflict: exponential backoff with jitter — `base_ms * 2^attempt + random(0, base_ms)`, `base_ms = 5`, capped at `max_delay_ms = 500`.
5. Bounded to `max_retries` (default `5`, via `jac.cas_max_retries`).
6. On exhaustion: raise `ConcurrentWriteExhausted(anchor_ids, attempts)`. The default `@restspec` error handler maps this to HTTP 409.

For walkers whose control flow branches on observed values (not just blind mutations), persistence-level replay is insufficient — the walker body must re-run:

```jac
@walker:pub(transactional=True, max_retries=3)
walker UpdateCounter { ... }
```

Transactional walkers re-execute their body on conflict, within the same retry budget. Non-idempotent side effects inside transactional walkers (external API calls, log emits, message sends) are the caller's responsibility; a linter check (§8) flags suspected cases at `jac check` time.

#### 4e. Semantic conflicts — read-set tracking

CAS prevents overwrites but not logic races: "I deleted e2 because I read that e2 existed" can still fire after someone else also deleted e2, rendering the precondition vacuous.

Two mechanisms:

1. **Explicit observation (available at all layers):** `jac.observed(expr)` records a `ReadField(name, snapshot)` op. On retry, each read op is re-checked against the reloaded anchor. If the snapshot has changed, escalate persistence-retry to walker-retry. If already at walker-retry, surface `ReadSetConflict` (409).
2. **Automatic read-set (opt-in via `@transactional`):** instrument attribute reads inside transactional walker bodies to auto-record `ReadField`. This is snapshot isolation. More overhead; opt-in for correctness-critical walkers only.

#### 4f. L2 (Redis) cache coherence

On successful transaction commit, publish `{id, new_version}` on the Redis pub/sub channel `jac:anchor:invalidate`. Every process subscribes on startup; on receipt:

- Drop the UUID from L1 (`VolatileMemory.__mem__`) if `cached.version < new_version`.
- Drop from L2 distributed cache.
- Do not pre-populate — lazy reload on next access.

Reads that populate caches carry `version` with the serialized anchor. Writers can *fast-fail* before opening a transaction: if `anchor.version < L1[id].version`, the local copy is known stale; force reload, re-replay ops, then commit. Fewer futile CAS attempts under high-read/low-write workloads.

For single-node deployments (SQLite, no Redis), the in-process dict is the only cache; invalidation is a direct `pop`. No pub/sub needed.

#### 4g. Hot-node livelock mitigation

Sustained concurrent writes on anchors like Root can livelock the optimistic loop. Mitigations:

- **Metrics:** retry-count histogram per anchor UUID + counter for `ConcurrentWriteExhausted`, exposed via the existing jac-scale Prometheus path. Hot spots surface as a heavy histogram tail.
- **Per-anchor pessimistic lock (opt-in):** `@jac.hot_path(lambda: Root, lock_ms=200)` acquires a Redis distributed lock keyed on the resolved anchor UUID before entering the CAS section. Serializes contenders on that specific anchor. Lock timeout → `ConcurrentWriteExhausted`.
- **Adaptive fallback:** if a given anchor UUID exceeds `jac.cas_hot_threshold_per_sec` conflicts (default 10/sec), auto-escalate subsequent writers on that UUID to the pessimistic path for `jac.cas_hot_cooldown_sec` (default 5s). Logged at `warning`.

Pessimistic lock is strictly the fallback; optimistic remains the default.

#### 4h. Edge-specific fast path (Mongo)

Even with Layer 4, every edge append on a hot Root incurs a CAS round-trip. For edges specifically — the exact case in #5451 — Mongo's array operators eliminate the race server-side:

- `ListAppend` on `NodeAnchor.edges` → `{'$addToSet': {'data.edges': edge_uuid}, '$inc': {'version': 1}}`
- `ListRemove` on edges → `{'$pull': {'data.edges': edge_uuid}, '$inc': {'version': 1}}`

`$addToSet` / `$pull` are atomic server-side — two concurrent edge appends both land, no retry. `$inc: {version: 1}` preserves the CAS invariant for other fields on the same anchor. Gated by the field having set-like semantics (declared via `@jac.set_semantics` on the `has` field, or inferred for `NodeAnchor.edges`).

SQLite has no atomic-array operator; falls through to the general CAS + op-replay path. This is a Mongo-only optimization.

#### 4i. Configuration summary

| Setting                            | Default | Purpose                                           |
|------------------------------------|---------|---------------------------------------------------|
| `jac.optimistic_cas`               | `True`  | Master switch for Layer 4                         |
| `jac.cas_max_retries`              | `5`     | Persistence-level retry bound                     |
| `jac.cas_base_delay_ms`            | `5`     | Backoff base                                      |
| `jac.cas_max_delay_ms`             | `500`   | Backoff cap                                       |
| `jac.cas_hot_threshold_per_sec`    | `10`    | Conflict-rate trigger for pessimistic fallback    |
| `jac.cas_hot_cooldown_sec`         | `5`     | Pessimistic cooldown window                       |
| `jac.walker_unit_of_work`          | `True`  | Wrap walker flush in backend transaction          |

All overridable via `jac.toml`.

#### 4j. How Layer 4 answers each concern from §CAS review

| Concern                                    | Covered by                                                  |
|--------------------------------------------|-------------------------------------------------------------|
| Retry correctness (replay intent)          | §4b op log + §4d step 2 (op-replay, not state-replay)       |
| Cross-anchor transactions                  | §4c backend transactions around multi-anchor delta          |
| L2 / Redis coherence                       | §4f pub/sub invalidation + version-tagged cache entries     |
| Hot-node livelock                          | §4g bounded retry + backoff + adaptive pessimistic fallback |
| Semantic conflicts (logic races)           | §4e `jac.observed` + `@transactional` snapshot isolation    |
| Idempotency on retry                       | §4b idempotent op variants + documented non-idempotent edge |

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
| `Archetype._jac_ops: list[Op] \| None`            | supersedes `_jac_dirty` once Layer 4 lands             |
| `_JacTrackedList` / `_JacTrackedDict` / `_JacTrackedSet` | collection proxies that capture mutation ops     |
| `anchor.version: int`                             | new CAS version field; persisted                       |
| `Memory.patch(anchor, fields, expected_version)`  | signature gains `expected_version`; returns `bool`     |
| `Jac.commit()`                                    | explicit end-of-unit-of-work flush                     |
| `jac.observed(expr)`                              | read-set annotation for snapshot isolation             |
| `@walker:pub(transactional=True, max_retries=N)`  | opt-in whole-walker retry                              |
| `@jac.hot_path(anchor_fn, lock_ms)`               | opt-in pessimistic lock for known-hot anchors          |
| `@jac.set_semantics` on a `has` field             | enables Mongo `$addToSet` / `$pull` fast path          |
| `ConcurrentWriteExhausted`, `ReadSetConflict`     | new exception types                                    |

SQLite anchors table gains a `version INTEGER NOT NULL DEFAULT 0` column; Mongo
documents gain a `version` field. Existing `data` JSON blobs remain readable; the patch
path mutates them in place via `json_set` / dotted-`$set`. Existing rows without
`version` are treated as `version = 0` on first access.

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

### Concurrency (Layer 4)
13. `test_cas_issue_5451_repro` — N concurrent walkers append one distinct edge each to
    the same Root anchor (Mongo + SQLite variants). Assert all N edges present after
    flush, zero losses. This is the direct repro of
    [#5451](https://github.com/jaseci-labs/jaseci/issues/5451).
14. `test_op_replay_on_conflict` — artificial conflict: winner writes field `name`;
    loser's retry must re-apply its own `counter += 1` op against the reloaded state
    (not re-submit its pre-winner snapshot). Assert `name == winner_value` and
    `counter == original + 1`.
15. `test_cas_transactional_walker_multi_anchor` — walker mutates anchors A and B;
    inject conflict on B only; assert A's write was rolled back (transactional
    atomicity), then both succeed on retry.
16. `test_cas_max_retries_exhausted` — force sustained conflict beyond `max_retries`;
    assert `ConcurrentWriteExhausted` raised and no partial write committed.
17. `test_cas_backoff_bounded` — monkeypatch clock; assert retry delays follow
    `base * 2^n + jitter` up to `max_delay_ms`.
18. `test_mongo_addtoset_edges_fast_path` — assert that `ListAppend` on
    `NodeAnchor.edges` emits `$addToSet` (not `$set`) by inspecting the Mongo command
    log. Concurrent append test: no CAS retries logged.
19. `test_l2_invalidation_cross_process` — two processes sharing Redis; P1 commits a
    write, P2 reads (cache-hit becomes miss), assert P2 sees P1's version.
20. `test_read_set_conflict_escalation` — walker with `jac.observed(node.status)`;
    concurrent write changes `status`; assert retry sees mismatch and either re-runs
    walker (transactional) or raises `ReadSetConflict`.
21. `test_hot_path_pessimistic_fallback` — drive conflict rate above
    `cas_hot_threshold_per_sec`; assert subsequent writers on that UUID take the
    pessimistic lock path, logged at `warning`.
22. `test_idempotent_append_on_replay` — partial-apply + retry scenario: ensure that
    re-replaying `ListAppend(edge_uuid)` against a state where the edge already exists
    does NOT produce a duplicate entry.

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
- **Layer 4 schema changes** are additive and idempotent:
  - SQLite: `_ensure_connection` runs `ALTER TABLE anchors ADD COLUMN version INTEGER
    NOT NULL DEFAULT 0` wrapped in a try/except `OperationalError` (already-exists is a
    no-op). Existing rows get `version = 0`.
  - Mongo: rollout treats absent `version` as 0. A background `$set: {version: 0}` on
    `{version: {$exists: false}}` normalizes the collection over time; not required for
    correctness.
- CAS can be disabled globally via `jac.optimistic_cas = false` in `jac.toml` — falls
  back to Layer 2's direct `patch()` without version check. Useful for single-writer
  dev loops and for deployments willing to accept last-writer-wins.
- Standalone Mongo (no replica set) cannot use multi-statement transactions — Layer 4
  degrades to per-anchor CAS with a startup warning. Cross-anchor atomicity is lost
  in this mode; `transactional=True` walkers log a warning on every invocation.

## 7. Phasing

1. **Phase 1 (prereq):** Layer 1 — `__setattr__` dirty tracking + serializer delta +
   unit tests 1–4. Low risk, no behavior change at the persistence layer.
2. **Phase 2:** Layer 2 — `patch()` on SQLite + Mongo; wire `sync` to prefer `patch`.
   Tests 5–9. Guarded by a runtime config flag (`jac.partial_updates = True`) so we can
   disable without reverting.
3. **Phase 3:** Layer 3 — `@restspec(method="PATCH")` + all-optional body models +
   `model_fields_set`-driven application. Tests 10–11.
4. **Phase 4 (follow-up):** recursive nested partial updates. Test 12.
5. **Phase 5 (Layer 4 core):** version column, op log + collection proxies, unit-of-work
   commit, persistence-level retry, Redis invalidation. Tests 13–19, 22. Ships
   alongside Phase 2 at minimum — partial updates without CAS is an anti-pattern
   (it narrows the race window but doesn't close it).
6. **Phase 6 (Layer 4 extensions):** Mongo `$addToSet` / `$pull` fast path,
   `jac.observed` + `@transactional` walker-retry, `@jac.hot_path` pessimistic opt-in,
   adaptive hot-path fallback. Tests 18, 20, 21. Each lands independently after
   Phase 5.

## 8. Open questions

1. Do we want a user-facing `with jac.patch(node) as p: p.name = "x"` context manager as
   a first-class API, distinct from the implicit-via-`__setattr__` flow? Nice for
   auditability; adds API surface. Defer unless requested.
2. For L2 cache (`LocalCacheMemory`, Redis), do we also teach `patch` to do a
   subdocument update, or continue to invalidate-and-refetch on every write? Redis
   `JSON.SET` supports it; decide alongside Phase 2 once we see real cache hit patterns.
3. Access control granularity: today `check_write_access(anchor)` is per-anchor. Do we
   want per-field access lists? Out of scope here — if we ever do, the op log from
   Layer 4 is the natural hook point (iterate ops, authorize each).
4. **Ordering guarantees under op-replay.** When walker A's `ListAppend(e4)` and
   walker B's `ListAppend(e5)` retry-interleave, is the final order `[…, e4, e5]` or
   `[…, e5, e4]`? For set-semantics fields (edges), order is irrelevant. For true
   list fields where order matters, document that op-replay provides no cross-retry
   ordering guarantee; callers who need order should use `SetField` (replace) or
   serialize via `@jac.hot_path`.
5. **`ListSetAt(idx, value)` under retry.** Position-dependent ops are inherently
   non-idempotent after a concurrent insert/remove shifts indices. Default: `ListSetAt`
   during replay raises `OpReplayConflict` and escalates to walker-retry. Alternative:
   translate position-based ops to id-based where possible (e.g., "set element with
   UUID=X to Y") — requires type information we may not have.
6. **Transactional-walker side-effect policy.** The docstring warning is informational
   only. Worth adding a `jac check` warning that flags calls to known non-idempotent
   APIs (`requests.*`, `boto3.*`, etc.) inside `transactional=True` walker bodies?
7. **Mongo standalone vs. replica set.** We degrade gracefully (per-anchor CAS only),
   but should jac-scale refuse to start in `transactional=True`-heavy deployments
   without a replica set, or merely warn? Decide before Phase 5.
