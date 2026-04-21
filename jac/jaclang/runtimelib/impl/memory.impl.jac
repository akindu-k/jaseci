"""Memory Hierarchy Implementations.

Implementations for VolatileMemory, LocalCacheMemory, SqliteMemory, and TieredMemory.
"""

import json;
import logging;
import os;
import sqlite3;
import from collections.abc { Callable, Generator, Iterable }
import from datetime { datetime, timezone }
import from typing { cast }
import from uuid { UUID }
import from jaclang.jac0core.archetype { Anchor, NodeAnchor, Root }
import from jaclang.runtimelib.serializer { Serializer }

glob logger = logging.getLogger(__name__),
     # Bumped when the on-disk row layout changes in a way that requires
     # schema migration. Kept in the `schema_meta` table.
     SQLITE_DB_FORMAT_VERSION: int = 1;

"""Serialize an anchor to the tuple of columns stored in the anchors table.

Uses `storage_mode=True` so nested archetypes emit $ref rather than inlining.
Mutating a child archetype rewrites only its own row; the parent's blob still
references it as {"$ref": child_uuid} and its hash is unchanged.
"""
def _anchor_to_row(anchor: Anchor) -> tuple {
    data = Serializer.serialize(anchor, include_type=True, storage_mode=True);
    data_json = json.dumps(data);
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
    return (
        anchor_type,
        arch_module,
        arch_type,
        fingerprint,
        data_json,
        SQLITE_DB_FORMAT_VERSION,
        datetime.now(timezone.utc).isoformat()
    );
}

# ---------------------------------------------------------------------------
# Phase 4.1 — Snapshot-based collection delta detection (shared primitive).
# Used by both SqliteMemory (Phase 5) and MongoBackend (Phase 4).
# ---------------------------------------------------------------------------

"""Stable JSON string key for comparing two serialized values by content."""
def _json_key(val: object) -> str {
    return json.dumps(val, sort_keys=True, default=str);
}

"""Return {field_name: kind} for all collection-typed `has` fields on `arch_cls`.

`kind` is 'list', 'set', or 'dict'. Only top-level container origins are
inspected so nested containers (e.g. `list[list[int]]`) are classified by
their outermost type.
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

Stores the serialized form of each collection field (via storage_mode=True)
plus the edge list for NodeAnchors in `anchor._field_snapshots`. Call after
every successful load or flush so `_compute_anchor_deltas` can diff later.
"""
def _snapshot_anchor_collections(anchor: Anchor) -> None {
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

`field_deltas` maps field names (plus '__edges__' for NodeAnchor) to delta
dicts. `scalars_unchanged` is True when no non-collection field changed since
the last snapshot — only in that case can element-level ops be used instead
of a full-row replace.
"""
def _compute_anchor_deltas(anchor: Anchor) -> tuple {
    snaps: dict = getattr(anchor, '_field_snapshots', None) or {};
    if not snaps {
        return ({}, False);
    }
    field_deltas: dict[str, object] = {};
    scalars_unchanged: bool = True;

    # NodeAnchor.edges — always set semantics
    if isinstance(anchor, NodeAnchor) {
        current_edges = [str(e.id) for e in anchor.edges];
        snap_edges: list = cast(list, snaps.get('__edges__', []));
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
                    'json_path': '$.edges',
                    'mongo_path': 'data.edges'
                };
            }
        }
    }

    # Archetype fields
    snap_arch: dict = cast(dict, snaps.get('__arch__', {}));
    if anchor.is_populated() and anchor.archetype is not None {
        arch = anchor.archetype;
        coll_kinds = _get_collection_fields(type(arch));
        curr_arch: dict = Serializer._serialize_attrs(
            arch, include_type=False, api_mode=False, storage_mode=True
        );

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
            json_path  = f'$.archetype.{fname}';
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
                        'json_path': json_path,
                        'mongo_path': mongo_path
                    };
                }
            } elif kind == 'set' {
                snap_items: list = (
                    cast(dict, snap_val).get('items', []) if isinstance(snap_val, dict) else []
                );
                curr_items: list = (
                    cast(dict, curr_val).get('items', []) if isinstance(curr_val, dict) else []
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
                        'json_path': json_path,
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
                        'json_path': json_path,
                        'mongo_path': mongo_path
                    };
                }
            }
        }

        for fname in snap_arch {
            if fname not in curr_arch and coll_kinds.get(fname) is None {
                scalars_unchanged = False;
                break;
            }
        }
    }

    return (field_deltas, scalars_unchanged);
}

"""Return True if the provided sqlite connection has the new anchors schema."""
def _is_new_schema(conn: sqlite3.Connection) -> bool {
    cursor = conn.execute("PRAGMA table_info(anchors)");
    cols = {row[1] for row in cursor.fetchall()};
    # Distinguishing column on the new schema. Legacy has (id, data) only.
    return 'fingerprint' in cols and 'format_version' in cols;
}

"""Return True if the connection has the legacy (id TEXT, data BLOB) schema."""
def _is_legacy_schema(conn: sqlite3.Connection) -> bool {
    cursor = conn.execute("PRAGMA table_info(anchors)");
    rows = cursor.fetchall();
    if not rows {
        return False;
    }
    cols = {row[1] for row in rows};
    return cols == {'id','data'};
}

"""Create the anchors + quarantine + schema_meta tables (new schema)."""
def _create_new_schema(conn: sqlite3.Connection) {
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS anchors (
            id              TEXT PRIMARY KEY,
            type            TEXT NOT NULL,
            arch_module     TEXT,
            arch_type       TEXT,
            fingerprint     TEXT,
            data            TEXT NOT NULL,
            format_version  INTEGER NOT NULL DEFAULT 1,
            updated_at      TEXT
        )
        """
    );
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS anchors_quarantine (
            id                   TEXT PRIMARY KEY,
            type                 TEXT,
            arch_module          TEXT,
            arch_type            TEXT,
            fingerprint          TEXT,
            data                 TEXT,
            error                TEXT,
            quarantined_at       TEXT,
            from_format_version  INTEGER
        )
        """
    );
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        )
        """
    );
    # DB-resident alias table. CLI-managed; complements the
    # @archetype_alias decorator (which is code-resident, per-process).
    # DB aliases are merged into Serializer._aliases at connect time so
    # operator-driven rescues work without a code deploy.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS aliases (
            old_name    TEXT PRIMARY KEY,
            new_name    TEXT NOT NULL,
            created_at  TEXT
        )
        """
    );
    conn.execute(
        "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
        ('db_format_version', str(SQLITE_DB_FORMAT_VERSION))
    );
    conn.commit();
}


"""Load all DB-resident aliases into the in-process Serializer registry.

Called at connection-open time. DB aliases merge with decorator-declared
aliases; if both touch the same old_name, the DB entry takes precedence
(the CLI is the operator's rescue path, expected to override a stale
default from code).
"""
def _load_db_aliases(conn: sqlite3.Connection) -> int {
    import from jaclang.runtimelib.serializer { Serializer }
    cursor = conn.execute("SELECT old_name, new_name FROM aliases");
    count = 0;
    for (old_name, new_name) in cursor.fetchall() {
        if isinstance(old_name, str) and isinstance(new_name, str) {
            Serializer._aliases[old_name] = new_name;
            count += 1;
        }
    }
    return count;
}

"""Quarantine a row that failed to deserialize. Never raises."""
def _quarantine(
    conn: sqlite3.Connection,
    id: str,
    anchor_type: (str | None),
    arch_module: (str | None),
    arch_type: (str | None),
    fingerprint: (str | None),
    data: (str | None),
    error: str,
    from_format_version: (int | None) = None
) {
    try {
        conn.execute(
            """
            INSERT OR REPLACE INTO anchors_quarantine
                (id, type, arch_module, arch_type, fingerprint, data,
                 error, quarantined_at, from_format_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                id,
                anchor_type,
                arch_module,
                arch_type,
                fingerprint,
                data,
                error,
                datetime.now(timezone.utc).isoformat(),
                from_format_version
            )
        );
        conn.execute("DELETE FROM anchors WHERE id = ?", (id, ));
        conn.commit();
    } except Exception as e {
        logger.error(f"Failed to quarantine anchor {id}: {e}");
    }
}

"""One-shot migration from legacy pickle (id TEXT, data BLOB) to JSON schema.

Called when an existing DB file has the legacy schema but none of the new
tables. Reads every pickle row, re-serializes via Serializer, writes to the
new anchors table. Rows that can't be unpickled or re-serialized are moved
to anchors_quarantine with the raw bytes hex-encoded and the error message.
"""
def _migrate_legacy_pickle_db(conn: sqlite3.Connection) {
    import from pickle { loads as pickle_loads }
    import from _pickle { UnpicklingError }
    logger.warning(
        "SqliteMemory: legacy pickle schema detected; migrating to JSON. "
        "Rows that can't be unpickled will be moved to anchors_quarantine."
    );
    # Snapshot old rows; the table will be rewritten.
    cursor = conn.execute("SELECT id, data FROM anchors");
    old_rows = cursor.fetchall();
    # Rename old table aside so we can build the new one cleanly.
    conn.execute("ALTER TABLE anchors RENAME TO anchors_legacy_pickle");
    _create_new_schema(conn);
    migrated = 0;
    quarantined = 0;
    for (id_str, blob) in old_rows {
        try {
            anchor = pickle_loads(blob);
            row = _anchor_to_row(anchor);
            conn.execute(
                """
                INSERT OR REPLACE INTO anchors
                    (id, type, arch_module, arch_type, fingerprint, data,
                     format_version, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (id_str, ) + row
            );
            migrated += 1;
        } except (
            UnpicklingError,
            ModuleNotFoundError,
            AttributeError,
            TypeError
        ) as e {
            # We intentionally don't store the raw bytes in quarantine for
            # the legacy path — pickle bytes aren't useful to inspect and
            # bloat the DB. Record the fact and the error instead.
            _quarantine(
                conn,
                id_str,
                None,
                None,
                None,
                None,
                None,
                f"legacy pickle unreadable: {type(e).__name__}: {e}",
                from_format_version=0
            );
            quarantined += 1;
        } except Exception as e {
            _quarantine(
                conn,
                id_str,
                None,
                None,
                None,
                None,
                None,
                f"legacy pickle migration error: {type(e).__name__}: {e}",
                from_format_version=0
            );
            quarantined += 1;
        }
    }
    conn.execute("DROP TABLE anchors_legacy_pickle");
    conn.commit();
    logger.warning(
        f"SqliteMemory: legacy migration complete — "
        f"{migrated} anchors migrated, {quarantined} quarantined."
    );
}

# =============================================================================
# VolatileMemory Implementation (L1)
# =============================================================================
"""Initialize mutable defaults."""
impl VolatileMemory.postinit -> None {
    self.__mem__ = {};
    self.__gc__ = set();
}

"""In-memory storage is always available."""
impl VolatileMemory.is_available -> bool {
    return True;
}

"""Retrieve an anchor by ID."""
impl VolatileMemory.get(id: UUID) -> (Anchor | None) {
    return self.__mem__.get(id);
}

"""Store an anchor."""
impl VolatileMemory.put(anchor: Anchor) -> None {
    self.__mem__[anchor.id] = anchor;
}

"""Remove an anchor by ID and track for garbage collection."""
impl VolatileMemory.delete(id: UUID) -> None {
    if (anchor := self.__mem__.pop(id, None)) {
        self.__gc__.add(anchor);
    }
}

"""Close and clear memory."""
impl VolatileMemory.close -> None {
    self.__mem__.clear();
    self.__gc__.clear();
}

"""Check if an anchor is in memory."""
impl VolatileMemory.`has(id: UUID) -> bool {
    return id in self.__mem__;
}

"""Query all anchors with optional filter."""
impl VolatileMemory.query(
    filter: (Callable[[Anchor], bool] | None) = None
) -> Generator[Anchor, None, None] {
    for anchor in self.__mem__.values() {
        if filter is None or filter(anchor) {
            yield anchor;
        }
    }
}

"""Get all root anchors."""
impl VolatileMemory.get_roots -> Generator[Root, None, None] {
    for anchor in self.__mem__.values() {
        if isinstance(anchor.archetype, Root) {
            yield cast(Root, anchor.archetype);
        }
    }
}

"""Find anchors by IDs with optional filter."""
impl VolatileMemory.find(
    ids: (UUID | Iterable[UUID]), filter: (Callable[[Anchor], Anchor] | None) = None
) -> Generator[Anchor, None, None] {
    id_list = [ids] if isinstance(ids, UUID) else list(ids);
    for id in id_list {
        if (anchor := self.__mem__.get(id)) {
            if filter is None or filter(anchor) {
                yield anchor;
            }
        }
    }
}

"""Find one anchor by ID(s) with optional filter."""
impl VolatileMemory.find_one(
    ids: (UUID | Iterable[UUID]), filter: (Callable[[Anchor], Anchor] | None) = None
) -> (Anchor | None) {
    id_list = [ids] if isinstance(ids, UUID) else list(ids);
    for id in id_list {
        if (anchor := self.__mem__.get(id)) {
            if filter is None or filter(anchor) {
                return anchor;
            }
        }
    }
    return None;
}

"""Get garbage collection list."""
impl VolatileMemory.get_gc -> list[Anchor] {
    return list(self.__gc__);
}

"""Remove anchor from garbage collection list."""
impl VolatileMemory.remove_from_gc(anchor: Anchor) -> None {
    self.__gc__.discard(anchor);
}

"""Get the underlying memory dict."""
impl VolatileMemory.get_mem -> dict[UUID, Anchor] {
    return self.__mem__;
}

"""Commit - no-op for volatile memory."""
impl VolatileMemory.commit(anchor: (Anchor | None) = None) -> None {
# No persistence, nothing to commit
}

# =============================================================================
# LocalCacheMemory Implementation (L2)
# Inherits all Memory interface methods from VolatileMemory.
# Only implements CacheMemory-specific methods.
# =============================================================================
"""Check if a key exists in the cache without loading the value."""
impl LocalCacheMemory.exists(id: UUID) -> bool {
    return id in self.__mem__;
}

"""Store an anchor only if it already exists in the cache."""
impl LocalCacheMemory.put_if_exists(anchor: Anchor) -> bool {
    if anchor.id in self.__mem__ {
        self.__mem__[anchor.id] = anchor;
        return True;
    }
    return False;
}

"""Invalidate a cache entry by ID."""
impl LocalCacheMemory.invalidate(id: UUID) -> None {
    self.__mem__.pop(id, None);
}

# =============================================================================
# SqliteMemory Implementation (L3 Persistent)
# =============================================================================
"""Initialize SqliteMemory with a file path (lazy - no DB created yet)."""
impl SqliteMemory.postinit -> None {
    self.__mem__ = {};
    self.__gc__ = set();
    # Connection is lazily initialized on first write
    self.__conn__ = None;
    self.l3_fetch_count = 0;
}

"""Lazily initialize SQLite connection when first needed.

Creates the new JSON-based schema. If an existing DB uses the legacy
pickle schema (id TEXT, data BLOB), migrates all rows in-place before
returning.
"""
impl SqliteMemory._ensure_connection -> None {
    if self.__conn__ is not None {
        return;
    }
    # Ensure parent directory exists for database file
    parent_dir = os.path.dirname(self.path);
    if parent_dir {
        os.makedirs(parent_dir, exist_ok=True);
    }
    # Open SQLite connection with WAL mode for better concurrency
    self.__conn__ = sqlite3.connect(self.path, check_same_thread=False);
    self.__conn__.execute("PRAGMA journal_mode=WAL");
    self.__conn__.execute("PRAGMA synchronous=NORMAL");
    # Detect schema state: new, legacy pickle, or empty.
    if _is_new_schema(self.__conn__) {
        # Already migrated — ensure quarantine + meta + aliases tables exist
        # in case the DB was opened by an older client before this version
        # (CREATE TABLE IF NOT EXISTS is idempotent).
        _create_new_schema(self.__conn__);
    } elif _is_legacy_schema(self.__conn__) {
        _migrate_legacy_pickle_db(self.__conn__);
    } else {
        _create_new_schema(self.__conn__);
    }
    # Merge DB-resident aliases into Serializer._aliases so CLI-managed
    # rescues apply automatically on the next read.
    _load_db_aliases(self.__conn__);
}

"""Check if database connection is available."""
impl SqliteMemory.is_available -> bool {
    return self.__conn__ is not None;
}

"""Get an anchor by ID. Check memory first, then database.

On deserialization failure, the row is moved to anchors_quarantine
(never deleted outright) so data can be inspected and recovered later.
Fingerprint drift is logged but does not block deserialization — the
Serializer tolerates added/removed fields by design.
"""
impl SqliteMemory.get(id: UUID) -> (Anchor | None) {
    # Check in-memory cache first
    if (anchor := self.__mem__.get(id)) {
        return anchor;
    }
    # Lazily connect if DB file exists (for reading existing data)
    if not self.__conn__ and os.path.exists(self.path) {
        self._ensure_connection();
    }
    if not self.__conn__ {
        return None;
    }
    cursor = self.__conn__.execute(
        """
        SELECT type, arch_module, arch_type, fingerprint, data, format_version
        FROM anchors WHERE id = ?
        """,
        (str(id), )
    );
    row = cast(
        (tuple[str, (str | None), (str | None), (str | None), str, int] | None),
        cursor.fetchone()
    );
    if not row {
        return None;
    }
    (anchor_type, arch_module, arch_type, fingerprint, data_json, fmt_version) = row;
    self.l3_fetch_count += 1;
    # Fingerprint drift check — informational only. The serializer already
    # tolerates added/removed fields; type changes will surface as
    # deserialize exceptions below.
    if arch_module and arch_type and fingerprint {
        cls = Serializer._get_class(arch_module, arch_type);
        current_fp = getattr(cls, '__jac_fingerprint__', None) if cls else None;
        if current_fp and current_fp != fingerprint {
            logger.info(
                f"SqliteMemory: schema drift on {arch_module}.{arch_type} "
                f"(stored fingerprint={fingerprint}, current={current_fp}, "
                f"anchor id={id}); attempting best-effort load."
            );
        }
    }
    try {
        data = json.loads(data_json);
        anchor = Serializer.deserialize(data);
    } except Exception as e {
        logger.warning(
            f"SqliteMemory: failed to deserialize anchor {id} "
            f"({arch_module}.{arch_type}): {type(e).__name__}: {e}. "
            f"Moving to anchors_quarantine."
        );
        _quarantine(
            self.__conn__,
            str(id),
            anchor_type,
            arch_module,
            arch_type,
            fingerprint,
            data_json,
            f"deserialize error: {type(e).__name__}: {e}",
            from_format_version=fmt_version
        );
        return None;
    }
    if anchor is None {
        # Either the row couldn't deserialize at all, or the archetype
        # class was unresolvable (even after alias lookup). Quarantine
        # rather than drop — class rename/move is recoverable via the
        # @archetype_alias decorator. The source of truth for "can't
        # reconstruct" lives inside Serializer._deserialize_anchor so
        # every persistence backend gets the same guarantee.
        logger.warning(
            f"SqliteMemory: class {arch_module}.{arch_type} unresolvable "
            f"for anchor {id}. Moving to anchors_quarantine."
        );
        _quarantine(
            self.__conn__,
            str(id),
            anchor_type,
            arch_module,
            arch_type,
            fingerprint,
            data_json,
            f"class {arch_module}.{arch_type} unresolvable",
            from_format_version=fmt_version
        );
        return None;
    }
    loaded = cast(Anchor, anchor);
    _snapshot_anchor_collections(loaded);
    self.__mem__[id] = loaded;
    return loaded;
}

"""Store an anchor. Writes to memory and immediately persists to database."""
impl SqliteMemory.put(anchor: Anchor) -> None {
    self.__mem__[anchor.id] = anchor;
    if anchor.persistent {
        self._ensure_connection();
        assert self.__conn__ is not None;
        conn = self.__conn__;
        try {
            row = _anchor_to_row(anchor);
            conn.execute(
                """
                INSERT OR REPLACE INTO anchors
                    (id, type, arch_module, arch_type, fingerprint, data,
                     format_version, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (str(anchor.id), ) + row
            );
            conn.commit();
            anchor.hash = Serializer._compute_hash(anchor);
            _snapshot_anchor_collections(anchor);
        } except Exception as e {
            logger.warning(f"SqliteMemory.put immediate persist failed: {e}");
        }
    }
}

"""Delete an anchor and track for garbage collection (only if persistent)."""
impl SqliteMemory.delete(id: UUID) -> None {
    if (anchor := self.__mem__.pop(id, None)) {
        # Only track persistent anchors for DB deletion
        if anchor.persistent {
            self.__gc__.add(anchor);
        }
    }
    # Also remove from database immediately if connected
    if self.__conn__ {
        conn = cast(sqlite3.Connection, self.__conn__);
        conn.execute("DELETE FROM anchors WHERE id = ?", (str(id), ));
        conn.commit();
    }
}

"""Close database connection and clear memory."""
impl SqliteMemory.close -> None {
    if self.__conn__ {
        self.__conn__.close();
        self.__conn__ = None;
    }
    self.__mem__.clear();
    self.__gc__.clear();
}

"""Check if an anchor is in memory or database."""
impl SqliteMemory.`has(id: UUID) -> bool {
    if id in self.__mem__ {
        return True;
    }
    # Lazily connect if DB file exists
    if not self.__conn__ and os.path.exists(self.path) {
        self._ensure_connection();
    }
    if self.__conn__ {
        cursor = self.__conn__.execute(
            "SELECT 1 FROM anchors WHERE id = ?", (str(id), )
        );
        return cursor.fetchone() is not None;
    }
    return False;
}

"""Query all anchors with optional filter."""
impl SqliteMemory.query(
    filter: (Callable[[Anchor], bool] | None) = None
) -> Generator[Anchor, None, None] {
    for anchor in self.__mem__.values() {
        if filter is None or filter(anchor) {
            yield anchor;
        }
    }
}

"""Get all root anchors."""
impl SqliteMemory.get_roots -> Generator[Root, None, None] {
    for anchor in self.__mem__.values() {
        if isinstance(anchor.archetype, Root) {
            yield cast(Root, anchor.archetype);
        }
    }
}

"""Find anchors by IDs with optional filter."""
impl SqliteMemory.find(
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
impl SqliteMemory.find_one(
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

"""Serialize an object to canonical JSON for equality comparison."""
def _canonical_json(val: object) -> str {
    return json.dumps(
        Serializer.serialize(val, include_type=True),
        sort_keys=True,
        default=lambda v: str : str(v)
    );
}

"""Sync memory to database with access control checks.

"""Apply element-level JSON1 operators for a set of collection field deltas.

Issues one or more `UPDATE anchors SET data = json_*(...) WHERE id = ?`
statements inside a single implicit SQLite write-lock window, so concurrent
writers serialize naturally and no Python-side read-modify-write race is
possible.

Routing per field kind (same semantics as MongoBackend._put_collection_delta):
  list (set_semantics=True)  → json_insert + CASE guard / remove-by-value
  list (set_semantics=False) → json_insert[#] append / remove-by-value
  set field                  → json_insert + CASE guard / remove-by-value
  dict field                 → json_set per key / json_remove per key

All values are passed through json(?) so both plain scalars and embedded
JSON objects (e.g. {$ref: …}) survive the round-trip correctly.
Requires SQLite 3.38+ (json_* built-ins); guaranteed on Python 3.11+.
"""
impl SqliteMemory._put_collection_delta(anchor: Anchor, field_deltas: dict) -> None {
    if not field_deltas {
        return;
    }
    self._ensure_connection();
    conn = cast(sqlite3.Connection, self.__conn__);
    anchor_id = str(anchor.id);
    ts = datetime.now(timezone.utc).isoformat();

    for (fname, delta) in field_deltas.items() {
        json_path = cast(str, delta['json_path']);
        kind      = cast(str, delta.get('kind', ''));

        if kind in ('list', 'set') {
            added     = cast(list, delta.get('added', []));
            removed   = cast(list, delta.get('removed', []));
            set_sem   = cast(bool, delta.get('set_semantics', False));

            # Add elements
            for elem in added {
                elem_json = json.dumps(elem);
                if set_sem {
                    # Insert only when not already present (set semantics)
                    conn.execute(
                        f"""
                        UPDATE anchors
                           SET data = CASE
                                   WHEN NOT EXISTS (
                                       SELECT 1 FROM json_each(data, ?)
                                        WHERE json(value) = json(?)
                                   )
                                   THEN json_insert(data, ? || '[#]', json(?))
                                   ELSE data
                               END,
                               updated_at = ?
                         WHERE id = ?
                        """,
                        (json_path, elem_json, json_path, elem_json, ts, anchor_id)
                    );
                } else {
                    # Unconditional append (list/push semantics)
                    conn.execute(
                        f"""
                        UPDATE anchors
                           SET data = json_insert(data, ? || '[#]', json(?)),
                               updated_at = ?
                         WHERE id = ?
                        """,
                        (json_path, elem_json, ts, anchor_id)
                    );
                }
            }

            # Remove elements (drop all exact matches)
            for elem in removed {
                elem_json = json.dumps(elem);
                conn.execute(
                    f"""
                    UPDATE anchors
                       SET data = json_set(
                               data,
                               ?,
                               (SELECT COALESCE(json_group_array(json(value)), '[]')
                                  FROM json_each(data, ?)
                                 WHERE json(value) != json(?))
                           ),
                           updated_at = ?
                     WHERE id = ?
                    """,
                    (json_path, json_path, elem_json, ts, anchor_id)
                );
            }

        } elif kind == 'dict' {
            added_or_changed = cast(dict, delta.get('added_or_changed', {}));
            removed_keys     = cast(list, delta.get('removed', []));

            for (k, v) in added_or_changed.items() {
                key_path = f'{json_path}.{k}';
                conn.execute(
                    f"""
                    UPDATE anchors
                       SET data = json_set(data, ?, json(?)),
                           updated_at = ?
                     WHERE id = ?
                    """,
                    (key_path, json.dumps(v), ts, anchor_id)
                );
            }

            for k in removed_keys {
                key_path = f'{json_path}.{k}';
                conn.execute(
                    f"""
                    UPDATE anchors
                       SET data = json_remove(data, ?),
                           updated_at = ?
                     WHERE id = ?
                    """,
                    (key_path, ts, anchor_id)
                );
            }
        }
    }

    conn.commit();
    anchor.hash = Serializer._compute_hash(anchor);
}

"""
Preserves the field-level merge semantics from the legacy pickle path:
edges merge requires CONNECT access, archetype/access merge require
WRITE access. Equality comparisons use JSON-serialized forms instead of
pickle-hash, making the sync safe across schema drift.
"""
impl SqliteMemory.sync -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    # Check if there's anything to sync
    has_persistent = any(a.persistent for a in self.__mem__.values());
    if not self.__gc__ and not has_persistent {
        return;  # Nothing to sync, don't create DB

    }
    # Lazily create connection now that we have data to persist
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    # Handle garbage collected anchors (deletions)
    for anchor in self.__gc__ {
        conn.execute("DELETE FROM anchors WHERE id = ?", (str(anchor.id), ));
    }
    self.__gc__.clear();
    # Sync memory to database with access control
    for (id, anchor) in list(self.__mem__.items()) {
        if not anchor.persistent {
            continue;
        }
        # Skip stubs - only sync fully populated anchors
        if not anchor.is_populated() {
            continue;
        }
        current_hash = Serializer._compute_hash(anchor);
        if current_hash == anchor.hash {
            continue;
        }

        key = str(id);
        # --- Phase 5 (Layer 4.3): element-level JSON1 path ---
        # Try targeted json_* ops when only collection fields changed and
        # we have a snapshot to diff against. Falls back to the full merge
        # path below on any failure.
        delta_result = _compute_anchor_deltas(anchor);
        field_deltas    = cast(dict, delta_result[0]);
        scalars_unchanged = cast(bool, delta_result[1]);
        if scalars_unchanged and field_deltas {
            try {
                # Edge delta requires CONNECT access; archetype field deltas
                # require WRITE access. Use the most permissive check that
                # covers what actually changed.
                edges_only = list(field_deltas.keys()) == ['__edges__'];
                has_access = (
                    Jac.check_connect_access(anchor)
                        if edges_only
                        else Jac.check_write_access(anchor)
                );
                if has_access {
                    self._put_collection_delta(anchor, field_deltas);
                    _snapshot_anchor_collections(anchor);
                    continue;
                }
            } except Exception as e {
                logger.warning(
                    f"SqliteMemory.sync: collection delta failed for {key}, "
                    f"falling back to full merge: {e}"
                );
            }
        }

        try {
            cursor = conn.execute(
                """
                SELECT type, arch_module, arch_type, fingerprint, data,
                       format_version
                FROM anchors WHERE id = ?
                """,
                (key, )
            );
            raw_row = cursor.fetchone();
            stored: (Anchor | None) = None;
            if raw_row {
                row_type = cast(str, raw_row[0]);
                row_arch_module = cast((str | None), raw_row[1]);
                row_arch_type = cast((str | None), raw_row[2]);
                row_fingerprint = cast((str | None), raw_row[3]);
                row_data = cast(str, raw_row[4]);
                row_fmt = cast(int, raw_row[5]);
                try {
                    stored = cast(
                        (Anchor | None), Serializer.deserialize(json.loads(row_data))
                    );
                } except Exception as de {
                    logger.warning(
                        f"SqliteMemory.sync: stored anchor {key} unreadable "
                        f"({type(de).__name__}: {de}); quarantining and "
                        "overwriting with in-memory version."
                    );
                    _quarantine(
                        conn,
                        key,
                        row_type,
                        row_arch_module,
                        row_arch_type,
                        row_fingerprint,
                        row_data,
                        f"sync-time deserialize: {type(de).__name__}: {de}",
                        from_format_version=row_fmt
                    );
                    stored = None;
                }
            }

            if stored is not None and stored.is_populated() {
                stored_anchor = cast(Anchor, stored);
                changed = False;
                # Handle edge updates (CONNECT access)
                if (
                    isinstance(stored_anchor, NodeAnchor)
                    and isinstance(anchor, NodeAnchor)
                    and stored_anchor.edges != anchor.edges
                    and Jac.check_connect_access(anchor)
                ) {
                    if not anchor.edges and not isinstance(anchor.archetype, Root) {
                        conn.execute("DELETE FROM anchors WHERE id = ?", (key, ));
                        continue;
                    }
                    stored_anchor.edges = anchor.edges;
                    changed = True;
                }
                # Handle access/archetype updates (WRITE access)
                access_changed = _canonical_json(stored_anchor.access) != _canonical_json(
                    anchor.access
                );
                archetype_changed = _canonical_json(stored_anchor.archetype) != _canonical_json(
                    anchor.archetype
                );
                if (access_changed or archetype_changed)
                and Jac.check_write_access(anchor) {
                    if access_changed {
                        stored_anchor.access = anchor.access;
                    }
                    if archetype_changed {
                        stored_anchor.archetype = anchor.archetype;
                    }
                    changed = True;
                }
                # Only write to database if something actually changed
                if changed {
                    merged_row = _anchor_to_row(stored_anchor);
                    conn.execute(
                        """
                        INSERT OR REPLACE INTO anchors
                            (id, type, arch_module, arch_type, fingerprint,
                             data, format_version, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (key, ) + merged_row
                    );
                    anchor.hash = current_hash;
                    _snapshot_anchor_collections(anchor);
                }
            } else {
                # No stored or stored is a stub - save anchor if valid
                if not (
                    isinstance(anchor, NodeAnchor)
                    and not isinstance(anchor.archetype, Root)
                    and not anchor.edges
                )
                and Jac.check_write_access(anchor) {
                    new_row = _anchor_to_row(anchor);
                    conn.execute(
                        """
                        INSERT OR REPLACE INTO anchors
                            (id, type, arch_module, arch_type, fingerprint,
                             data, format_version, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (key, ) + new_row
                    );
                    anchor.hash = current_hash;
                    _snapshot_anchor_collections(anchor);
                }
            }
        } except (AttributeError, ModuleNotFoundError) {
            # Skip anchors that can't be serialized (e.g. transient test classes)
            continue;
        } except Exception as e {
            logger.warning(
                f"SqliteMemory.sync: failed to sync anchor {key}: "
                f"{type(e).__name__}: {e}"
            );
            continue;
        }
    }
    conn.commit();
}

"""Bulk store multiple anchors."""
impl SqliteMemory.bulk_put(anchors: Iterable[Anchor]) -> None {
    for anchor in anchors {
        self.put(anchor);
    }
}

"""Get garbage collection list."""
impl SqliteMemory.get_gc -> list[Anchor] {
    return list(self.__gc__);
}

"""Remove anchor from garbage collection list."""
impl SqliteMemory.remove_from_gc(anchor: Anchor) -> None {
    self.__gc__.discard(anchor);
}

"""Get the underlying memory dict."""
impl SqliteMemory.get_mem -> dict[UUID, Anchor] {
    return self.__mem__;
}

"""Commit - syncs pending changes to database."""
impl SqliteMemory.commit(anchor: (Anchor | None) = None) -> None {
    self.sync();
}

# =============================================================================
# SqliteMemory: Layer 1+2+3 operator surface
# =============================================================================
"""Helper: attempt to re-deserialize one quarantined row, re-stamped with the
live class's identity + fingerprint on success. Returns (ok, reason)."""
def _sqlite_attempt_recover(conn: sqlite3.Connection, row: tuple) -> tuple {
    (
        row_id,
        anchor_type,
        arch_module,
        arch_type,
        fingerprint,
        data_json,
        _error,
        _quarantined_at,
        from_format_version
    ) = row;
    if not data_json {
        return (False, "no data payload stored");
    }
    try {
        data = json.loads(data_json);
    } except Exception as e {
        return (False, f"json decode failed: {e}");
    }
    try {
        anchor = Serializer.deserialize(data);
    } except Exception as e {
        return (False, f"deserialize raised: {type(e).__name__}: {e}");
    }
    if anchor is None {
        return (False, f"class {arch_module}.{arch_type} still unresolvable");
    }
    # Re-stamp with live class metadata so subsequent reads bypass alias
    # resolution and drift-detection logging.
    re_data = Serializer.serialize(anchor, include_type=True);
    re_data_json = json.dumps(re_data);
    live_arch = getattr(anchor, 'archetype', None);
    live_module = getattr(type(live_arch), '__module__', arch_module)
        if live_arch
        else arch_module;
    live_type = getattr(type(live_arch), '__name__', arch_type)
        if live_arch
        else arch_type;
    live_fp = getattr(type(live_arch), '__jac_fingerprint__', fingerprint)
        if live_arch
        else fingerprint;
    now = datetime.now(timezone.utc).isoformat();
    conn.execute(
        """
        INSERT OR REPLACE INTO anchors
            (id, type, arch_module, arch_type, fingerprint, data,
             format_version, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            row_id,
            anchor_type or 'Anchor',
            live_module,
            live_type,
            live_fp,
            re_data_json,
            from_format_version or 1,
            now
        )
    );
    conn.execute("DELETE FROM anchors_quarantine WHERE id = ?", (row_id, ));
    return (True, "recovered");
}


"""Summary dict for `jac db inspect`."""
impl SqliteMemory.inspect_summary -> dict {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    fmt_row = conn.execute(
        "SELECT value FROM schema_meta WHERE key='db_format_version'"
    ).fetchone();
    fmt_version = fmt_row[0] if fmt_row else '?';
    anchors_rows = cast(
        list[tuple],
        list(
            conn.execute(
                """
        SELECT COALESCE(arch_type, '<none>'), COUNT(*)
        FROM anchors
        GROUP BY arch_type
        ORDER BY COUNT(*) DESC
        """
            )
        )
    );
    quarantine_rows = cast(
        list[tuple],
        list(
            conn.execute(
                """
        SELECT COALESCE(arch_type, '<none>'), COUNT(*)
        FROM anchors_quarantine
        GROUP BY arch_type
        ORDER BY COUNT(*) DESC
        """
            )
        )
    );
    (alias_count, ) = cast(
        tuple[int], conn.execute("SELECT COUNT(*) FROM aliases").fetchone()
    );
    return {
        'format_version': str(fmt_version),
        'anchors_total': sum(r[1] for r in anchors_rows),
        'anchors_by_type': [(r[0], r[1]) for r in anchors_rows],
        'quarantine_total': sum(r[1] for r in quarantine_rows),
        'quarantine_by_type': [(r[0], r[1]) for r in quarantine_rows],
        'aliases_total': alias_count,
        'location': self.path
    };
}


"""List recent quarantined rows."""
impl SqliteMemory.list_quarantined(limit: int = 50) -> list {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    rows = cast(
        list[tuple],
        list(
            conn.execute(
                """
        SELECT id, COALESCE(arch_module, '?') || '.' ||
               COALESCE(arch_type, '?'), COALESCE(fingerprint, ''),
               COALESCE(error, ''), COALESCE(quarantined_at, '')
        FROM anchors_quarantine
        ORDER BY quarantined_at DESC
        LIMIT ?
        """,
                (limit, )
            )
        )
    );
    return [
        {
            'id': str(r[0]),
            'arch': str(r[1]),
            'fingerprint': str(r[2]),
            'error': str(r[3]),
            'quarantined_at': str(r[4])
        } for r in rows
    ];
}


"""Full detail of one quarantined row (by id or unique prefix)."""
impl SqliteMemory.show_quarantined(id_prefix: str) -> (dict | None) {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    rows = cast(
        list[tuple],
        list(
            conn.execute(
                """
        SELECT id, type, arch_module, arch_type, fingerprint, data,
               error, quarantined_at, from_format_version
        FROM anchors_quarantine
        WHERE id = ? OR id LIKE ?
        LIMIT 2
        """,
                (id_prefix, id_prefix + '%')
            )
        )
    );
    if not rows {
        return None;
    }
    if len(rows) > 1 {
        return {'error': 'ambiguous', 'count': len(rows)};
    }
    r = rows[0];
    parsed_data = None;
    try {
        parsed_data = json.loads(r[5]) if r[5] else None;
    } except Exception { }
    return {
        'id': r[0],
        'type': r[1],
        'arch_module': r[2],
        'arch_type': r[3],
        'fingerprint': r[4],
        'error': r[6],
        'quarantined_at': r[7],
        'from_format_version': r[8],
        'data': parsed_data
    };
}


"""Recover a single quarantined row (or unique prefix)."""
impl SqliteMemory.recover_one(id_prefix: str) -> tuple {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    # Pull in DB-resident aliases so CLI-added rescues apply.
    _load_db_aliases(conn);
    rows = cast(
        list[tuple],
        list(
            conn.execute(
                """
        SELECT id, type, arch_module, arch_type, fingerprint, data,
               error, quarantined_at, from_format_version
        FROM anchors_quarantine
        WHERE id = ? OR id LIKE ?
        LIMIT 2
        """,
                (id_prefix, id_prefix + '%')
            )
        )
    );
    if not rows {
        return (False, f"no quarantined row matching {id_prefix}");
    }
    if len(rows) > 1 {
        return (False, f"prefix {id_prefix} matches multiple rows");
    }
    (ok, reason) = _sqlite_attempt_recover(conn, rows[0]);
    conn.commit();
    return (ok, reason);
}


"""Recover every quarantined row; return (n_recovered, [(id, reason)...])."""
impl SqliteMemory.recover_all -> tuple {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    _load_db_aliases(conn);
    rows = cast(
        list[tuple],
        list(
            conn.execute(
                """
        SELECT id, type, arch_module, arch_type, fingerprint, data,
               error, quarantined_at, from_format_version
        FROM anchors_quarantine
        """
            )
        )
    );
    recovered = 0;
    still_stuck: list = [];
    for r in rows {
        (ok, reason) = _sqlite_attempt_recover(conn, r);
        if ok {
            recovered += 1;
        } else {
            still_stuck.append((str(r[0]), reason));
        }
    }
    conn.commit();
    return (recovered, still_stuck);
}


"""List DB-resident aliases."""
impl SqliteMemory.list_aliases -> list {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    rows = cast(
        list[tuple],
        list(
            conn.execute(
                "SELECT old_name, new_name, COALESCE(created_at, '') "
                "FROM aliases ORDER BY created_at"
            )
        )
    );
    return [
        {'old_name': str(r[0]), 'new_name': str(r[1]), 'created_at': str(r[2])}
        for r in rows
    ];
}


"""Add (or replace) an alias; merge into the in-process Serializer map."""
impl SqliteMemory.add_alias(old_name: str, new_name: str) -> None {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    now = datetime.now(timezone.utc).isoformat();
    conn.execute(
        """
        INSERT OR REPLACE INTO aliases (old_name, new_name, created_at)
        VALUES (?, ?, ?)
        """,
        (old_name, new_name, now)
    );
    conn.commit();
    Serializer._aliases[old_name] = new_name;
}


"""Remove an alias. Returns True if an entry was deleted."""
impl SqliteMemory.remove_alias(old_name: str) -> bool {
    self._ensure_connection();
    assert self.__conn__ is not None;
    conn = self.__conn__;
    cursor = conn.execute("DELETE FROM aliases WHERE old_name = ?", (old_name, ));
    conn.commit();
    removed = cursor.rowcount > 0;
    if removed {
        Serializer._aliases.pop(old_name, None);
    }
    return removed;
}

# =============================================================================
# TieredMemory Implementation (extends VolatileMemory with L2 + L3)
# Inherits L1 functionality (__mem__, __gc__) from VolatileMemory.
# Only overrides methods that need tiering logic.
# =============================================================================
"""Initialize TieredMemory with optional cache and persistence."""
impl TieredMemory.postinit -> None {
    import from jaclang.runtimelib.memory { LocalCacheMemory, SqliteMemory }
    import from jaclang.runtimelib.utils { get_db_path }
    # Initialize L1 (inherited from VolatileMemory)
    self.__mem__ = {};
    self.__gc__ = set();
    # Initialize L2 cache if requested
    if self.use_cache {
        self.l2 = LocalCacheMemory();
    } else {
        self.l2 = None;
    }
    # Initialize L3 persistence if base_path provided
    if self.base_path {
        # Use project.db for projects, filename.db for standalone apps
        db_path = get_db_path(self.base_path);
        self.l3 = SqliteMemory(path=db_path);
    } else {
        self.l3 = None;
    }
}

"""Get anchor with read-through: L1 -> L2 -> L3 with promotion."""
impl TieredMemory.get(id: UUID) -> (Anchor | None) {
    # L1 hit (self.__mem__ inherited from VolatileMemory)
    if (anchor := self.__mem__.get(id)) {
        return anchor;
    }
    # L2 hit with promotion to L1
    if self.l2 and (anchor := self.l2.get(id)) {
        self.__mem__[anchor.id] = anchor;
        return anchor;
    }
    # L3 fallback with promotion to L1 (and L2 if enabled)
    if self.l3 and (anchor := self.l3.get(id)) {
        self.__mem__[anchor.id] = anchor;
        if self.l2 {
            self.l2.put(anchor);
        }
        return anchor;
    }
    return None;
}

"""Put anchor with write-through: L1 always, L2/L3 with access control."""
impl TieredMemory.put(anchor: Anchor) -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    # Always write to L1 (self.__mem__ inherited from VolatileMemory)
    self.__mem__[anchor.id] = anchor;
    # Write-through to L2 (cache) if enabled
    if self.l2 {
        self.l2.put(anchor);
    }
    # Write-through to L3 with access control check
    if self.l3 and anchor.persistent {
        if Jac.check_write_access(anchor) {
            self.l3.put(anchor);
        }
    }
}

"""Delete anchor from all tiers."""
impl TieredMemory.delete(id: UUID) -> None {
    # Delete from L1 (only track persistent anchors for GC)
    if (anchor := self.__mem__.pop(id, None)) {
        if anchor.persistent {
            self.__gc__.add(anchor);
        }
    }
    # Invalidate L2 cache
    if self.l2 {
        self.l2.invalidate(id);
    }
    # Delete from L3 persistence (only if we have persistent data)
    if self.l3 {
        self.l3.delete(id);
    }
}

"""Close all tiers."""
impl TieredMemory.close -> None {
    # Sync L3 before closing
    if self.l3 {
        self.l3.sync();
        self.l3.close();
    }
    # Close L2
    if self.l2 {
        self.l2.close();
    }
    # Clear L1 (inherited from VolatileMemory)
    self.__mem__.clear();
    self.__gc__.clear();
}

"""Check if anchor exists in any tier."""
impl TieredMemory.`has(id: UUID) -> bool {
    # Check L1 first
    if id in self.__mem__ {
        return True;
    }
    # Check L2 cache
    if self.l2 and self.l2.exists(id) {
        return True;
    }
    # Check L3 persistence
    if self.l3 and self.l3.`has(id) {
        return True;
    }
    return False;
}

"""Get L3 fetch count for testing/instrumentation."""
impl TieredMemory.get_l3_fetch_count -> int {
    import from jaclang.runtimelib.memory { SqliteMemory }
    if isinstance(self.l3, SqliteMemory) {
        return self.l3.l3_fetch_count;
    }
    return 0;
}

"""Reset L3 fetch count for testing/instrumentation."""
impl TieredMemory.reset_l3_fetch_count -> None {
    import from jaclang.runtimelib.memory { SqliteMemory }
    if isinstance(self.l3, SqliteMemory) {
        self.l3.l3_fetch_count = 0;
    }
}

"""Commit - syncs L3 persistence if available."""
impl TieredMemory.commit(anchor: (Anchor | None) = None) -> None {
    if self.l3 {
        self.l3.sync();
    }
}

"""Batch get: check L1, then load L3 misses, promote all to L1/L2."""
impl TieredMemory.batch_get(ids: list[UUID]) -> dict[UUID, Anchor] {
    result: dict[UUID, Anchor] = {};
    missing_ids: list[UUID] = [];
    for id in ids {
        if (anchor := self.__mem__.get(id)) {
            result[id] = anchor;
        } else {
            missing_ids.append(id);
        }
    }
    if missing_ids and self.l3 {
        for mid in missing_ids {
            if (anchor := self.l3.get(mid)) {
                self.__mem__[anchor.id] = anchor;
                if self.l2 {
                    self.l2.put(anchor);
                }
                result[anchor.id] = anchor;
            }
        }
    }
    return result;
}
