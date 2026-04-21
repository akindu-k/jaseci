"""MongoDB PersistenceBackend Implementation."""

"""Post-initialization: connect to MongoDB and load DB-resident aliases.

On connect we also ensure the companion collections exist as logical
concepts: `<collection>_quarantine` holds unloadable anchors, and
`<collection>_aliases` holds DB-resident class-rename aliases that the
Serializer consults on every class lookup. Mongo auto-creates
collections on first write, so all we do here is load any existing
aliases into the in-process Serializer map.
"""
impl MongoBackend.postinit -> None {
    if self.mongo_url is None {
        self.mongo_url = _get_db_config().get('mongodb_uri');
    }
    if self.client is None and self.mongo_url {
        try {
            self.client = MongoClient(self.mongo_url);
            self.db = self.client[self.db_name];
            self.collection = self.db[self.collection_name];
        } except Exception as e {
            logger.warning(f"MongoDB connection failed: {e}");
            self.client = None;
        }
    }
    if self.client is not None {
        try {
            self._load_db_aliases();
        } except Exception as e {
            logger.debug(f"MongoBackend: alias preload skipped: {e}");
        }
    }
}

"""Get the `_quarantine` companion collection."""
def _mongo_q_collection(backend: MongoBackend) -> Any {
    return backend.db[backend.collection_name + '_quarantine'];
}

"""Get the `_aliases` companion collection."""
def _mongo_a_collection(backend: MongoBackend) -> Any {
    return backend.db[backend.collection_name + '_aliases'];
}

"""Build a stored document for an anchor, including Layer 2 fingerprint
and Layer 1 archetype identity fields. Parallels _anchor_to_row in
SqliteMemory; kept here so schema evolution stays per-backend."""
def _anchor_to_doc(anchor: Anchor) -> dict {
    data = Serializer.serialize(anchor, include_type=True, storage_mode=True);
    anchor_type = type(anchor).__name__;
    arch_module: (str | None) = None;
    arch_type: (str | None) = None;
    fingerprint: (str | None) = None;
    if anchor.is_populated() and anchor.archetype is not None {
        arch = anchor.archetype;
        arch_module = type(arch).__module__;
        arch_type = type(arch).__name__;
        fp = getattr(type(arch), '__jac_fingerprint__', None);
        fingerprint = fp if isinstance(fp, str) and fp else None;
    }
    return {
        'type': anchor_type,
        'arch_module': arch_module,
        'arch_type': arch_type,
        'fingerprint': fingerprint,
        'data': data,
        'format_version': 1,
        'updated_at': datetime.now(timezone.utc).isoformat()
    };
}

"""Stable JSON string key for comparing two serialized values.

Used to check membership in a list/set snapshot without relying on
Python object identity — two separately-serialized `{$ref: uuid}` dicts
that are equal by value will hash to the same key here.
"""
def _json_key(val: object) -> str {
    import from json { dumps }
    return dumps(val, sort_keys=True, default=str);
}

"""Return {field_name: kind} for all collection-typed `has` fields on `arch_cls`.

`kind` is one of 'list', 'set', 'dict'. Only top-level collection origins
are inspected; nested generics (e.g. `list[list[int]]`) are classified by
their outermost container.
"""
def _get_collection_fields(arch_cls: type) -> dict[str, str] {
    import dataclasses;
    import from typing { get_type_hints, get_origin }
    if not dataclasses.is_dataclass(arch_cls) {
        return {};
    }
    try {
        hints = get_type_hints(arch_cls);
    } except Exception {
        hints = getattr(arch_cls, '__annotations__', {}) or {};
    }
    result: dict[str, str] = {};
    for f in dataclasses.fields(arch_cls) {
        ann = hints.get(f.name);
        if ann is None {
            continue;
        }
        origin = get_origin(ann);
        if origin is list {
            result[f.name] = 'list';
        } elif origin is set or origin is frozenset {
            result[f.name] = 'set';
        } elif origin is dict {
            result[f.name] = 'dict';
        }
    }
    return result;
}

"""Record a shallow snapshot of all collection-typed fields on `anchor`.

The snapshot uses `Serializer._serialize_attrs` with `storage_mode=True`
so archetype-valued elements are stored as `{$ref: …}` pointers — the
same representation used on disk. This means delta comparison is stable:
we compare serialized forms, not live Python objects.

Stored in `anchor._field_snapshots` as:
  {
    '__arch__':  full serialized archetype attrs dict  (for scalar diff),
    '__edges__': [uuid_str, …]  (NodeAnchor only),
  }
"""
def _snapshot_anchor_collections(anchor: Anchor) -> None {
    import from jaclang.jac0core.archetype { NodeAnchor }
    import from jaclang.runtimelib.serializer { Serializer }
    snaps: dict[str, object] = {};
    if isinstance(anchor, NodeAnchor) {
        snaps['__edges__'] = [str(e.id) for e in anchor.edges];
    }
    if anchor.is_populated() and anchor.archetype is not None {
        snaps['__arch__'] = Serializer._serialize_attrs(
            anchor.archetype,
            include_type=False,
            api_mode=False,
            storage_mode=True
        );
    }
    anchor._field_snapshots = snaps;
}

"""Compute per-field collection deltas between the live anchor and its last snapshot.

Returns `(field_deltas, scalars_unchanged)`.

`field_deltas` maps field names to delta dicts:
  list/set field:  {'kind': 'list'|'set', 'set_semantics': bool,
                    'added': [...], 'removed': [...], 'mongo_path': str}
  dict field:      {'kind': 'dict',
                    'added_or_changed': {k: v}, 'removed': [k],
                    'mongo_path': str}

`scalars_unchanged` is True when no non-collection field changed since the
last snapshot. Only when this is True (and `field_deltas` is non-empty) can
we use element-level Mongo ops instead of a full-row replace.

Special key '__edges__' covers NodeAnchor.edges with set semantics.
"""
def _compute_anchor_deltas(anchor: Anchor) -> tuple {
    import from jaclang.jac0core.archetype { NodeAnchor }
    import from jaclang.runtimelib.serializer { Serializer }
    snaps: dict = getattr(anchor, '_field_snapshots', None) or {};
    if not snaps {
        return ({}, False);
    }
    field_deltas: dict[str, object] = {};
    scalars_unchanged: bool = True;

    # --- NodeAnchor.edges ---
    if isinstance(anchor, NodeAnchor) {
        current_edges = [str(e.id) for e in anchor.edges];
        snap_edges: list = snaps.get('__edges__', []);
        snap_edge_set = set(snap_edges);
        curr_edge_set = set(current_edges);
        if snap_edge_set != curr_edge_set {
            added   = [e for e in current_edges if e not in snap_edge_set];
            removed = [e for e in snap_edges   if e not in curr_edge_set];
            if added or removed {
                field_deltas['__edges__'] = {
                    'kind': 'list',
                    'set_semantics': True,
                    'added': added,
                    'removed': removed,
                    'mongo_path': 'data.edges'
                };
            }
        }
    }

    # --- Archetype fields ---
    snap_arch: dict = snaps.get('__arch__', {});
    if anchor.is_populated() and anchor.archetype is not None {
        arch = anchor.archetype;
        coll_kinds = _get_collection_fields(type(arch));
        curr_arch: dict = Serializer._serialize_attrs(
            arch, include_type=False, api_mode=False, storage_mode=True
        );

        # Fields present in current serialization
        for (fname, curr_val) in curr_arch.items() {
            snap_val = snap_arch.get(fname);
            if curr_val == snap_val {
                continue;
            }
            kind: (str | None) = coll_kinds.get(fname);
            if kind is None {
                scalars_unchanged = False;
                continue;
            }
            mongo_path = f'data.archetype.{fname}';
            if kind == 'list' {
                snap_list: list = snap_val if isinstance(snap_val, list) else [];
                curr_list: list = curr_val if isinstance(curr_val, list) else [];
                snap_keys = set(_json_key(x) for x in snap_list);
                curr_keys = set(_json_key(x) for x in curr_list);
                added   = [x for x in curr_list if _json_key(x) not in snap_keys];
                removed = [x for x in snap_list if _json_key(x) not in curr_keys];
                if added or removed {
                    field_deltas[fname] = {
                        'kind': 'list',
                        'set_semantics': False,
                        'added': added,
                        'removed': removed,
                        'mongo_path': mongo_path
                    };
                }
            } elif kind == 'set' {
                snap_items: list = (
                    snap_val.get('items', []) if isinstance(snap_val, dict) else []
                );
                curr_items: list = (
                    curr_val.get('items', []) if isinstance(curr_val, dict) else []
                );
                snap_keys = set(_json_key(x) for x in snap_items);
                curr_keys = set(_json_key(x) for x in curr_items);
                added   = [x for x in curr_items if _json_key(x) not in snap_keys];
                removed = [x for x in snap_items if _json_key(x) not in curr_keys];
                if added or removed {
                    field_deltas[fname] = {
                        'kind': 'set',
                        'set_semantics': True,
                        'added': added,
                        'removed': removed,
                        'mongo_path': mongo_path
                    };
                }
            } elif kind == 'dict' {
                snap_dict: dict = snap_val if isinstance(snap_val, dict) else {};
                curr_dict: dict = curr_val if isinstance(curr_val, dict) else {};
                added_or_changed = {
                    k: v for (k, v) in curr_dict.items() if snap_dict.get(k) != v
                };
                removed = [k for k in snap_dict if k not in curr_dict];
                if added_or_changed or removed {
                    field_deltas[fname] = {
                        'kind': 'dict',
                        'added_or_changed': added_or_changed,
                        'removed': removed,
                        'mongo_path': mongo_path
                    };
                }
            }
        }

        # Fields present in snapshot but removed from current → scalar check
        for fname in snap_arch {
            if fname not in curr_arch and coll_kinds.get(fname) is None {
                scalars_unchanged = False;
                break;
            }
        }
    }

    return (field_deltas, scalars_unchanged);
}

"""Move an unreadable document into the quarantine collection.

Never raises: we'd rather fail loud on load (caller quarantines + None)
than leak exceptions into walker traversal.
"""
def _mongo_quarantine(
    backend: MongoBackend,
    id_str: str,
    anchor_type: (str | None),
    arch_module: (str | None),
    arch_type: (str | None),
    fingerprint: (str | None),
    data: Any,
    error: str,
    from_format_version: (int | None) = None
) {
    try {
        _mongo_q_collection(backend).update_one(
            {'_id': id_str},
            {
                '$set': {
                    'type': anchor_type,
                    'arch_module': arch_module,
                    'arch_type': arch_type,
                    'fingerprint': fingerprint,
                    'data': data,
                    'error': error,
                    'quarantined_at': datetime.now(timezone.utc).isoformat(),
                    'from_format_version': from_format_version
                }
            },
            upsert=True
        );
        backend.collection.delete_one({'_id': id_str});
    } except Exception as e {
        logger.error(f"MongoBackend: failed to quarantine {id_str}: {e}");
    }
}

"""Set reference to parent TieredMemory's __mem__ for sync()."""
impl MongoBackend.set_memory_ref(mem: dict[UUID, Anchor]) -> None {
    self._mem_ref = mem;
}

"""Check if MongoDB is available and connected."""
impl MongoBackend.is_available -> bool {
    if not self.mongo_url {
        self.mongo_url = _get_db_config().get('mongodb_uri');
    }
    if not self.mongo_url {
        return False;
    }
    client = None;
    try {
        client = MongoClient(self.mongo_url);
        client.admin.command('ping', maxTimeMS=100);
        return True;
    } except ConnectionFailure {
        return False;
    } except Exception as e {
        logger.debug(f"MongoDB availability check failed: {e}");
        return False;
    } finally {
        if client {
            try {
                client.close();
            } except Exception { }
        }
    }
}

"""Get anchor by UUID from MongoDB.

On any deserialization failure or unresolvable archetype class, the row
is moved to the `_quarantine` collection (never silently dropped) so an
operator can inspect and recover with `jac db` — parallel to the
SqliteMemory contract.
"""
impl MongoBackend.get(id: UUID) -> (Anchor | None) {
    if self.client is None {
        return None;
    }
    _id = to_uuid(id);
    try {
        db_obj = self.collection.find_one({'_id': str(_id)});
    } except Exception as e {
        logger.debug(f"MongoDB get failed: {e}");
        return None;
    }
    if not db_obj {
        return None;
    }
    anchor_type = db_obj.get('type');
    arch_module = db_obj.get('arch_module');
    arch_type = db_obj.get('arch_type');
    fingerprint = db_obj.get('fingerprint');
    data = db_obj.get('data');
    fmt_version = db_obj.get('format_version');
    # Fingerprint drift check (INFO-only; best-effort load proceeds below).
    if arch_module and arch_type and fingerprint {
        cls = Serializer._get_class(arch_module, arch_type);
        current_fp = getattr(cls, '__jac_fingerprint__', None) if cls else None;
        if current_fp and current_fp != fingerprint {
            logger.info(
                f"MongoBackend: schema drift on {arch_module}.{arch_type} "
                f"(stored={fingerprint}, current={current_fp}, id={id}); "
                "attempting best-effort load."
            );
        }
    }
    try {
        anchor = Serializer.deserialize(data) if data is not None else None;
    } except Exception as e {
        logger.warning(
            f"MongoBackend: failed to deserialize anchor {id} "
            f"({arch_module}.{arch_type}): {type(e).__name__}: {e}. "
            "Moving to quarantine."
        );
        _mongo_quarantine(
            self,
            str(_id),
            anchor_type,
            arch_module,
            arch_type,
            fingerprint,
            data,
            f"deserialize error: {type(e).__name__}: {e}",
            from_format_version=fmt_version
        );
        return None;
    }
    if anchor is None {
        logger.warning(
            f"MongoBackend: class {arch_module}.{arch_type} unresolvable "
            f"for anchor {id}. Moving to quarantine."
        );
        _mongo_quarantine(
            self,
            str(_id),
            anchor_type,
            arch_module,
            arch_type,
            fingerprint,
            data,
            f"class {arch_module}.{arch_type} unresolvable",
            from_format_version=fmt_version
        );
        return None;
    }
    return cast(Anchor, anchor);
}

"""Store anchor in MongoDB with fingerprint and archetype identity fields."""
impl MongoBackend.put(anchor: Anchor) -> None {
    if self.client is None or not anchor.persistent {
        return;
    }
    _id = to_uuid(anchor.id);
    try {
        doc = _anchor_to_doc(anchor);
        self.collection.update_one({'_id': str(_id)}, {'$set': doc}, upsert=True);
        anchor.hash = Serializer._compute_hash(anchor);
        _snapshot_anchor_collections(anchor);
    } except Exception as e {
        logger.error(f"MongoDB put failed: {e}");
    }
}

"""Delete anchor from MongoDB."""
impl MongoBackend.delete(id: UUID) -> None {
    if self.client is None {
        return;
    }
    _id = to_uuid(id);
    try {
        self.collection.delete_one({'_id': str(_id)});
    } except Exception as e {
        logger.debug(f"MongoDB delete failed: {e}");
    }
}

"""Close MongoDB connection."""
impl MongoBackend.close -> None {
    if self.client {
        try {
            self.client.close();
        } except Exception as e {
            logger.warning(f"Error closing MongoDB connection: {e}");
        }
        self.client = None;
    }
    self._mem_ref = None;
}

"""Check if an anchor exists in MongoDB."""
impl MongoBackend.`has(id: UUID) -> bool {
    if self.client is None {
        return False;
    }
    _id = to_uuid(id);
    try {
        return self.collection.count_documents({'_id': str(_id)}, limit=1) > 0;
    } except Exception {
        return False;
    }
}

"""Query all anchors with optional filter."""
impl MongoBackend.query(
    filter: (Callable[[Anchor], bool] | None) = None
) -> Generator[Anchor, None, None] {
    if self.client is None {
        return;
    }
    try {
        for doc in self.collection.find() {
            if (anchor := self._load_anchor(doc)) {
                if filter is None or filter(anchor) {
                    yield anchor;
                }
            }
        }
    } except Exception as e {
        logger.debug(f"MongoDB query failed: {e}");
    }
}

"""Get all root anchors."""
impl MongoBackend.get_roots -> Generator[Root, None, None] {
    for anchor in self.query() {
        if isinstance(anchor.archetype, Root) {
            yield cast(Root, anchor.archetype);
        }
    }
}

"""Find anchors by IDs with optional filter."""
impl MongoBackend.find(
    ids: (UUID | Iterable[UUID]), filter: (Callable[[Anchor], Anchor] | None) = None
) -> Generator[Anchor, None, None] {
    id_list = [ids] if isinstance(ids, UUID) else list(ids);
    for id in id_list {
        if (anchor := self.get(id)) {
            if filter is None or filter(anchor) {
                yield anchor;
            }
        }
    }
}

"""Find one anchor by ID(s) with optional filter."""
impl MongoBackend.find_one(
    ids: (UUID | Iterable[UUID]), filter: (Callable[[Anchor], Anchor] | None) = None
) -> (Anchor | None) {
    id_list = [ids] if isinstance(ids, UUID) else list(ids);
    for id in id_list {
        if (anchor := self.get(id)) {
            if filter is None or filter(anchor) {
                return anchor;
            }
        }
    }
    return None;
}

"""Commit - no-op for MongoDB (writes are immediate)."""
impl MongoBackend.commit(anchor: (Anchor | None) = None) -> None {
# No-op: MongoDB writes are immediate
}

# PersistentMemory-specific methods
"""Sync - flush L1 memory to MongoDB (only changed anchors).

For each changed anchor, tries the element-level collection-delta path
(Layer 4.2) first: if only collection fields changed since the last
snapshot, issue targeted $addToSet / $push / $pullAll / $set / $unset
operators instead of rewriting the whole row.  Falls back to a full-row
put whenever scalar fields also changed or the delta write fails.
"""
impl MongoBackend.sync -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    if not self._mem_ref or not self.client {
        return;
    }
    for (_, anchor) in list(self._mem_ref.items()) {
        if not anchor.persistent {
            continue;
        }
        current_hash = Serializer._compute_hash(anchor);
        if current_hash == anchor.hash {
            continue;
        }
        if not Jac.check_write_access(anchor) {
            continue;
        }
        try {
            delta_result = _compute_anchor_deltas(anchor);
            field_deltas    = cast(dict, delta_result[0]);
            scalars_unchanged = cast(bool, delta_result[1]);
            if scalars_unchanged and field_deltas {
                try {
                    self._put_collection_delta(anchor, field_deltas);
                    _snapshot_anchor_collections(anchor);
                } except Exception as e {
                    logger.warning(
                        f"MongoDB collection delta failed for {anchor.id}, "
                        f"falling back to full put: {e}"
                    );
                    self.put(anchor);
                }
            } else {
                self.put(anchor);
            }
        } except Exception as e {
            logger.warning(f"MongoDB sync failed for anchor {anchor.id}: {e}");
        }
    }
}

"""Bulk store multiple anchors with Layer 1+2 fingerprint + metadata."""
impl MongoBackend.bulk_put(anchors: Iterable[Anchor]) -> None {
    if self.client is None {
        return;
    }
    ops: list = [];
    for anchor in anchors {
        if not anchor.persistent {
            continue;
        }
        _id = to_uuid(anchor.id);
        try {
            doc = _anchor_to_doc(anchor);
            ops.append(UpdateOne({'_id': str(_id)}, {'$set': doc}, upsert=True));
        } except Exception as e {
            logger.debug(f"MongoDB bulk_put serialization failed: {e}");
        }
    }
    if ops {
        try {
            self.collection.bulk_write(ops);
        } except Exception as e {
            logger.debug(f"MongoDB bulk_write failed: {e}");
        }
    }
}

"""Batch get multiple anchors by ID using MongoDB $in query."""
impl MongoBackend.batch_get(ids: list[UUID]) -> dict[UUID, Anchor] {
    result: dict[UUID, Anchor] = {};
    if self.client is None or not ids {
        return result;
    }
    str_ids = [str(to_uuid(id)) for id in ids];
    try {
        for doc in self.collection.find({'_id': {'$in': str_ids}}) {
            if (anchor := self._load_anchor(doc)) {
                anchor.is_updated = False;
                result[UUID(doc['_id'])] = anchor;
            }
        }
    } except Exception as e {
        logger.debug(f"MongoDB batch_get failed: {e}");
    }
    return result;
}

"""Load anchor from raw MongoDB document, quarantining on failure."""
impl MongoBackend._load_anchor(raw: dict[(str, Any)]) -> (Anchor | None) {
    if 'data' not in raw {
        return None;
    }
    doc_id = str(raw.get('_id', ''));
    anchor_type = raw.get('type');
    arch_module = raw.get('arch_module');
    arch_type = raw.get('arch_type');
    fingerprint = raw.get('fingerprint');
    fmt_version = raw.get('format_version');
    data = raw['data'];
    try {
        anchor = Serializer.deserialize(data);
    } except Exception as e {
        logger.warning(
            f"MongoBackend: failed to deserialize anchor (id={doc_id}, "
            f"type={anchor_type}): {type(e).__name__}: {e}. "
            "Moving to quarantine."
        );
        _mongo_quarantine(
            self,
            doc_id,
            anchor_type,
            arch_module,
            arch_type,
            fingerprint,
            data,
            f"deserialize error: {type(e).__name__}: {e}",
            from_format_version=fmt_version
        );
        return None;
    }
    if anchor is None {
        logger.warning(
            f"MongoBackend: class {arch_module}.{arch_type} unresolvable "
            f"for anchor {doc_id}. Moving to quarantine."
        );
        _mongo_quarantine(
            self,
            doc_id,
            anchor_type,
            arch_module,
            arch_type,
            fingerprint,
            data,
            f"class {arch_module}.{arch_type} unresolvable",
            from_format_version=fmt_version
        );
        return None;
    }
    loaded = cast(Anchor, anchor);
    _snapshot_anchor_collections(loaded);
    return loaded;
}


# ----------------------------------------------------------------------
# Layer 1+2+3 operator surface — parity with SqliteMemory.
# ----------------------------------------------------------------------
"""Attempt to re-deserialize one quarantined Mongo doc, re-stamped with
the live class's identity + fingerprint on success. Returns (ok, reason)."""
def _mongo_attempt_recover(backend: MongoBackend, doc: dict) -> tuple {
    doc_id = str(doc.get('_id', ''));
    data = doc.get('data');
    arch_module = doc.get('arch_module');
    arch_type = doc.get('arch_type');
    if data is None {
        return (False, "no data payload stored");
    }
    try {
        anchor = Serializer.deserialize(data);
    } except Exception as e {
        return (False, f"deserialize raised: {type(e).__name__}: {e}");
    }
    if anchor is None {
        return (False, f"class {arch_module}.{arch_type} still unresolvable");
    }
    # Re-stamp with live class metadata.
    re_doc = _anchor_to_doc(cast(Anchor, anchor));
    try {
        backend.collection.update_one({'_id': doc_id}, {'$set': re_doc}, upsert=True);
        _mongo_q_collection(backend).delete_one({'_id': doc_id});
    } except Exception as e {
        return (False, f"write-back failed: {type(e).__name__}: {e}");
    }
    return (True, "recovered");
}


"""Helper: shape a Mongo quarantine doc into the CLI-expected format."""
def _format_q_doc(d: dict) -> dict {
    return {
        'id': d.get('_id'),
        'type': d.get('type'),
        'arch_module': d.get('arch_module'),
        'arch_type': d.get('arch_type'),
        'fingerprint': d.get('fingerprint'),
        'error': d.get('error'),
        'quarantined_at': d.get('quarantined_at'),
        'from_format_version': d.get('from_format_version'),
        'data': d.get('data')
    };
}


"""Apply element-level Mongo operators for a set of collection field deltas.

Translates the `field_deltas` dict produced by `_compute_anchor_deltas`
into a single `update_one` call:

  list (set_semantics=True)  → $addToSet / $pullAll
  list (set_semantics=False) → $push    / $pullAll
  set field                  → $addToSet / $pullAll
  dict field                 → $set per key / $unset per key

Multiple fields are coalesced into one round-trip by merging operator
dicts. Path collisions within a single operator are impossible here
because each field maps to a unique `data.archetype.<name>` path.
"""
impl MongoBackend._put_collection_delta(anchor: Anchor, field_deltas: dict) -> None {
    if not field_deltas {
        return;
    }
    ops: dict[str, dict] = {};
    for (fname, delta) in field_deltas.items() {
        mongo_path = cast(str, delta['mongo_path']);
        kind = cast(str, delta.get('kind', ''));
        if kind in ('list', 'set') {
            added   = cast(list, delta.get('added', []));
            removed = cast(list, delta.get('removed', []));
            set_sem = cast(bool, delta.get('set_semantics', False));
            if added {
                if set_sem {
                    ops.setdefault('$addToSet', {})[mongo_path] = {'$each': added};
                } else {
                    ops.setdefault('$push', {})[mongo_path] = {'$each': added};
                }
            }
            if removed {
                ops.setdefault('$pullAll', {})[mongo_path] = removed;
            }
        } elif kind == 'dict' {
            added_or_changed = cast(dict, delta.get('added_or_changed', {}));
            removed_keys     = cast(list, delta.get('removed', []));
            for (k, v) in added_or_changed.items() {
                ops.setdefault('$set', {})[f'{mongo_path}.{k}'] = v;
            }
            for k in removed_keys {
                ops.setdefault('$unset', {})[f'{mongo_path}.{k}'] = '';
            }
        }
    }
    if not ops {
        return;
    }
    ops.setdefault('$set', {})['updated_at'] = datetime.now(timezone.utc).isoformat();
    self.collection.update_one({'_id': str(anchor.id)}, ops);
    anchor.hash = Serializer._compute_hash(anchor);
}

"""Summary for `jac db inspect`."""
impl MongoBackend.inspect_summary -> dict {
    loc = (
        (self.mongo_url or '<no mongo url>') + '/' + self.db_name + '.' + self.collection_name
    );
    if self.client is None {
        return {
            'format_version': '?',
            'anchors_total': 0,
            'anchors_by_type': [],
            'quarantine_total': 0,
            'quarantine_by_type': [],
            'aliases_total': 0,
            'location': loc
        };
    }
    pipeline = [
        {'$group': {'_id': '$arch_type', 'count': {'$sum': 1}}},
        {'$sort': {'count': -1}}
    ];
    try {
        anchors_by = [
            (doc.get('_id') or '<none>', doc.get('count', 0))
            for doc in self.collection.aggregate(pipeline)
        ];
    } except Exception {
        anchors_by = [];
    }
    try {
        qby = [
            (doc.get('_id') or '<none>', doc.get('count', 0))
            for doc in _mongo_q_collection(self).aggregate(pipeline)
        ];
    } except Exception {
        qby = [];
    }
    try {
        alias_count = _mongo_a_collection(self).count_documents({});
    } except Exception {
        alias_count = 0;
    }
    return {
        'format_version': '1',
        'anchors_total': sum(r[1] for r in anchors_by),
        'anchors_by_type': anchors_by,
        'quarantine_total': sum(r[1] for r in qby),
        'quarantine_by_type': qby,
        'aliases_total': alias_count,
        'location': loc
    };
}


"""List the N most recent quarantined documents."""
impl MongoBackend.list_quarantined(limit: int = 50) -> list {
    if self.client is None {
        return [];
    }
    try {
        docs = list(
            _mongo_q_collection(self).find().sort('quarantined_at', -1).limit(limit)
        );
    } except Exception {
        return [];
    }
    return [
        {
            'id': str(d.get('_id', '')),
            'arch': ((d.get('arch_module') or '?') + '.' + (d.get('arch_type') or '?')),
            'fingerprint': str(d.get('fingerprint') or ''),
            'error': str(d.get('error') or ''),
            'quarantined_at': str(d.get('quarantined_at') or '')
        } for d in docs
    ];
}


"""Full detail of one quarantined document (by id or unique prefix)."""
impl MongoBackend.show_quarantined(id_prefix: str) -> (dict | None) {
    if self.client is None {
        return None;
    }
    try {
        exact = _mongo_q_collection(self).find_one({'_id': id_prefix});
        if exact {
            return _format_q_doc(exact);
        }
        import re;
        pattern = '^' + re.escape(id_prefix);
        docs = list(
            _mongo_q_collection(self).find({'_id': {'$regex': pattern}}).limit(2)
        );
    } except Exception {
        return None;
    }
    if not docs {
        return None;
    }
    if len(docs) > 1 {
        return {'error': 'ambiguous', 'count': len(docs)};
    }
    return _format_q_doc(docs[0]);
}


"""Recover a single quarantined document (by id or unique prefix)."""
impl MongoBackend.recover_one(id_prefix: str) -> tuple {
    if self.client is None {
        return (False, "no mongodb connection");
    }
    self._load_db_aliases();
    try {
        exact = _mongo_q_collection(self).find_one({'_id': id_prefix});
        if exact {
            return _mongo_attempt_recover(self, exact);
        }
        import re;
        pattern = '^' + re.escape(id_prefix);
        docs = list(
            _mongo_q_collection(self).find({'_id': {'$regex': pattern}}).limit(2)
        );
    } except Exception as e {
        return (False, f"mongo query failed: {e}");
    }
    if not docs {
        return (False, f"no quarantined row matching {id_prefix}");
    }
    if len(docs) > 1 {
        return (False, f"prefix {id_prefix} matches multiple rows");
    }
    return _mongo_attempt_recover(self, docs[0]);
}


"""Recover every quarantined document."""
impl MongoBackend.recover_all -> tuple {
    if self.client is None {
        return (0, []);
    }
    self._load_db_aliases();
    try {
        docs = list(_mongo_q_collection(self).find());
    } except Exception {
        return (0, []);
    }
    recovered = 0;
    still_stuck: list = [];
    for d in docs {
        (ok, reason) = _mongo_attempt_recover(self, d);
        if ok {
            recovered += 1;
        } else {
            still_stuck.append((str(d.get('_id', '')), reason));
        }
    }
    return (recovered, still_stuck);
}


"""List DB-resident aliases."""
impl MongoBackend.list_aliases -> list {
    if self.client is None {
        return [];
    }
    try {
        docs = list(_mongo_a_collection(self).find().sort('created_at', 1));
    } except Exception {
        return [];
    }
    return [
        {
            'old_name': str(d.get('_id', '')),
            'new_name': str(d.get('new_name', '')),
            'created_at': str(d.get('created_at', ''))
        } for d in docs
    ];
}


"""Add or replace a DB-resident alias; merge into Serializer registry."""
impl MongoBackend.add_alias(old_name: str, new_name: str) -> None {
    if self.client is None {
        return;
    }
    now = datetime.now(timezone.utc).isoformat();
    try {
        _mongo_a_collection(self).update_one(
            {'_id': old_name},
            {'$set': {'new_name': new_name, 'created_at': now}},
            upsert=True
        );
    } except Exception as e {
        logger.error(f"MongoBackend: add_alias failed: {e}");
        return;
    }
    Serializer._aliases[old_name] = new_name;
}


"""Remove a DB-resident alias. Returns True if an entry was deleted."""
impl MongoBackend.remove_alias(old_name: str) -> bool {
    if self.client is None {
        return False;
    }
    try {
        result = _mongo_a_collection(self).delete_one({'_id': old_name});
    } except Exception as e {
        logger.error(f"MongoBackend: remove_alias failed: {e}");
        return False;
    }
    removed = result.deleted_count > 0;
    if removed {
        Serializer._aliases.pop(old_name, None);
    }
    return removed;
}


"""Load DB-resident aliases into the in-process Serializer registry."""
impl MongoBackend._load_db_aliases -> int {
    if self.client is None {
        return 0;
    }
    count = 0;
    try {
        for doc in _mongo_a_collection(self).find() {
            old_name = doc.get('_id');
            new_name = doc.get('new_name');
            if isinstance(old_name, str) and isinstance(new_name, str) {
                Serializer._aliases[old_name] = new_name;
                count += 1;
            }
        }
    } except Exception as e {
        logger.debug(f"MongoBackend: _load_db_aliases skipped: {e}");
    }
    return count;
}
