"""Memory Hierarchy Implementations.

Implementations for VolatileMemory, LocalCacheMemory, SqliteMemory, and TieredMemory.
"""

import json;
import logging;
import os;
import sqlite3;
import from collections.abc { Callable, Generator, Iterable }
import from pickle { dumps, loads }
import from typing { cast }
import from uuid { UUID }
import from jaclang.jac0core.archetype { Anchor, NodeAnchor, Root }
import from jaclang.runtimelib.serializer { Serializer }

glob logger = logging.getLogger(__name__);

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
}

"""Lazily initialize SQLite connection when first needed."""
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

    # Check if we need to migrate from old BLOB schema to JSON schema
    cursor = self.__conn__.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='anchors'"
    );
    table_exists = cursor.fetchone() is not None;

    if table_exists {
        # Check if it's the old BLOB schema by inspecting column types
        cursor = self.__conn__.execute("PRAGMA table_info(anchors)");
        columns = {row[1]: row[2] for row in cursor.fetchall()};

        if 'data' in columns and columns['data'] == 'BLOB' {
            # Old schema detected - migrate to JSON
            logger.info(
                "Migrating SQLite schema from BLOB to JSON with version support..."
            );
            self._migrate_blob_to_json();
        }
    } else {
        # Create new JSON-based schema with version support
        self.__conn__.execute(
            """
            CREATE TABLE anchors (
                id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                version INTEGER NOT NULL DEFAULT 0
            )
        """
        );
        # Create index on version for optimistic locking queries
        self.__conn__.execute("CREATE INDEX idx_version ON anchors(version)");
        self.__conn__.commit();
    }
    self.__conn__.commit();
}

"""Migrate from old BLOB schema to JSON schema with version support."""
impl SqliteMemory._migrate_blob_to_json -> None {
    logger.info("Starting migration from BLOB to JSON schema...");
    try {
        # Create new table with JSON schema
        self.__conn__.execute(
            """
            CREATE TABLE anchors_new (
                id TEXT PRIMARY KEY,
                data TEXT NOT NULL,
                version INTEGER NOT NULL DEFAULT 0
            )
        """
        );

        # Migrate data from old table to new table
        cursor = self.__conn__.execute("SELECT id, data FROM anchors");
        migrated = 0;
        failed = 0;

        for row in cursor.fetchall() {
            try {
                # Deserialize BLOB data
                anchor = loads(row[1]);
                # Serialize to JSON
                json_data = json.dumps(Serializer.serialize(anchor, include_type=True));
                # Insert into new table with version 0
                self.__conn__.execute(
                    "INSERT INTO anchors_new (id, data, version) VALUES (?, ?, 0)",
                    (row[0], json_data)
                );
                migrated += 1;
            } except Exception as e {
                logger.warning(f"Failed to migrate anchor {row[0]}: {e}");
                failed += 1;
            }
        }

        # Drop old table and rename new table
        self.__conn__.execute("DROP TABLE anchors");
        self.__conn__.execute("ALTER TABLE anchors_new RENAME TO anchors");

        # Create index on version
        self.__conn__.execute("CREATE INDEX idx_version ON anchors(version)");

        self.__conn__.commit();
        logger.info(
            f"Migration complete: {migrated} anchors migrated, {failed} failed"
        );
    } except Exception as e {
        logger.error(f"Migration failed: {e}");
        self.__conn__.rollback();
        raise e;
    }
}

"""Check if database connection is available."""
impl SqliteMemory.is_available -> bool {
    return self.__conn__ is not None;
}

"""Get an anchor by ID. Check memory first, then database."""
impl SqliteMemory.get(id: UUID) -> (Anchor | None) {
    import from _pickle { UnpicklingError }
    # Check in-memory cache first
    if (anchor := self.__mem__.get(id)) {
        return anchor;
    }
    # Lazily connect if DB file exists (for reading existing data)
    if not self.__conn__ and os.path.exists(self.path) {
        self._ensure_connection();
    }
    # Check database
    if self.__conn__ {
        cursor = self.__conn__.execute(
            "SELECT data, version FROM anchors WHERE id = ?", (str(id), )
        );
        if (row := cursor.fetchone()) {
            try {
                # Try JSON deserialization first (new format)
                json_data = json.loads(row[0]);
                anchor = Serializer.deserialize(json_data);
                if anchor and isinstance(anchor, Anchor) {
                    # Set version from database
                    anchor.version = row[1] if len(row) > 1 else 0;
                    # Promote to memory cache
                    self.__mem__[id] = anchor;
                    return anchor;
                }
            } except (json.JSONDecodeError, ValueError) {
                # Try BLOB deserialization (old format) - fallback for unmigrated data
                try {
                    anchor = loads(row[0]);
                    # Promote to memory cache
                    self.__mem__[id] = anchor;
                    return anchor;
                } except (UnpicklingError, ModuleNotFoundError, AttributeError) {
                    # Can't deserialize - delete stale entry
                    self.__conn__.execute(
                        "DELETE FROM anchors WHERE id = ?", (str(id), )
                    );
                    self.__conn__.commit();
                    return None;
                }
            }
        }
    }
    return None;
}

"""Store an anchor. Writes to memory and immediately persists to database."""
impl SqliteMemory.put(anchor: Anchor) -> None {
    self.__mem__[anchor.id] = anchor;
    if anchor.persistent {
        self._ensure_connection();
        try {
            # Serialize to JSON
            json_data = json.dumps(Serializer.serialize(anchor, include_type=True));
            # Increment version on every put
            anchor.version += 1;
            self.__conn__.execute(
                "INSERT OR REPLACE INTO anchors (id, data, version) VALUES (?, ?, ?)",
                (str(anchor.id), json_data, anchor.version)
            );
            self.__conn__.commit();
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
        self.__conn__.execute("DELETE FROM anchors WHERE id = ?", (str(id), ));
        self.__conn__.commit();
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

"""Sync memory to database with access control checks."""
impl SqliteMemory.sync -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    import from _pickle { PicklingError }
    # Check if there's anything to sync
    has_persistent = any(a.persistent for a in self.__mem__.values());
    if not self.__gc__ and not has_persistent {
        return;  # Nothing to sync, don't create DB

    }
    # Lazily create connection now that we have data to persist
    self._ensure_connection();
    # Handle garbage collected anchors (deletions)
    for anchor in self.__gc__ {
        self.__conn__.execute("DELETE FROM anchors WHERE id = ?", (str(anchor.id), ));
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

        key = str(id);
        try {
            cursor = self.__conn__.execute(
                "SELECT data, version FROM anchors WHERE id = ?", (key, )
            );
            row = cursor.fetchone();
            stored = None;
            stored_version = 0;

            if row {
                # Try to deserialize - handle both JSON (new) and BLOB (old) formats
                try {
                    # Try JSON first (new format)
                    json_data = json.loads(row[0]);
                    stored = Serializer.deserialize(json_data);
                    stored_version = row[1] if len(row) > 1 else 0;
                } except (json.JSONDecodeError, ValueError) {
                    # Fall back to BLOB (old format)
                    try {
                        stored = loads(row[0]);
                        stored_version = 0;  # Old format has no version
                    } except Exception {
                        stored = None;
                    }
                }
            }

            if stored and stored.is_populated() {
                changed = False;
                # Handle edge updates (CONNECT access)
                if (
                    isinstance(stored, NodeAnchor)
                    and isinstance(anchor, NodeAnchor)
                    and stored.edges != anchor.edges
                    and Jac.check_connect_access(anchor)
                ) {
                    if not anchor.edges and not isinstance(anchor.archetype, Root) {
                        self.__conn__.execute(
                            "DELETE FROM anchors WHERE id = ?", (key, )
                        );
                        continue;
                    }
                    stored.edges = anchor.edges;
                    changed = True;
                }
                # Handle access/archetype updates (WRITE access)
                access_changed = hash(dumps(stored.access)) != hash(
                    dumps(anchor.access)
                );
                archetype_changed = hash(dumps(stored.archetype)) != hash(
                    dumps(anchor.archetype)
                );
                if (access_changed or archetype_changed)
                and Jac.check_write_access(anchor) {
                    if access_changed {
                        stored.access = anchor.access;
                    }
                    if archetype_changed {
                        stored.archetype = anchor.archetype;
                    }
                    changed = True;
                }
                # Only write to database if something actually changed
                if changed {
                    # Use JSON format with version
                    json_data = json.dumps(
                        Serializer.serialize(stored, include_type=True)
                    );
                    stored.version = stored_version + 1;
                    self.__conn__.execute(
                        "INSERT OR REPLACE INTO anchors (id, data, version) VALUES (?, ?, ?)",
                        (key, json_data, stored.version)
                    );
                }
            } else {
                # No stored or stored is a stub - save anchor if valid
                if not (
                    isinstance(anchor, NodeAnchor)
                    and not isinstance(anchor.archetype, Root)
                    and not anchor.edges
                )
                and Jac.check_write_access(anchor) {
                    # Use JSON format with version
                    json_data = json.dumps(
                        Serializer.serialize(anchor, include_type=True)
                    );
                    anchor.version += 1;
                    self.__conn__.execute(
                        "INSERT OR REPLACE INTO anchors (id, data, version) VALUES (?, ?, ?)",
                        (key, json_data, anchor.version)
                    );
                }
            }
        } except (PicklingError, AttributeError, ModuleNotFoundError) as e {
            # Skip anchors that can't be serialized (e.g., transient test classes)
            logger.debug(f"Skipping anchor {key} during sync: {e}");
            continue;
        }
    }
    self.__conn__.commit();
}

"""Bulk store multiple anchors."""
impl SqliteMemory.bulk_put(anchors: Iterable[Anchor]) -> None {
    for anchor in anchors {
        self.put(anchor);
    }
}

"""Partially update an anchor's archetype fields with optimistic locking.

Uses JSON path updates for true atomic field-level modifications. Implements
optimistic locking via version field to detect concurrent modifications.
"""
impl SqliteMemory.partial_update(
    anchor: Anchor, fields: (dict[str, object] | None) = None
) -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    if not anchor.persistent or not Jac.check_write_access(anchor) {
        return;
    }
    # If no fields specified, fall back to full put
    if fields is None or not fields {
        self.put(anchor);
        return;
    }
    # Lazily create connection if needed
    self._ensure_connection();
    key = str(anchor.id);

    # Retry loop for optimistic lock conflicts with exponential backoff
    max_retries = 3;
    for attempt in range(max_retries) {
        try {
            # Exponential backoff: wait before retry (except first attempt)
            if attempt > 0 {
                import time;
                # Exponential backoff: 0.1s, 0.2s, 0.4s
                backoff_delay = 0.1 * (2 ** (attempt - 1));
                logger.debug(
                    f"Retry attempt {attempt + 1}/{max_retries} after {backoff_delay}s backoff"
                );
                time.sleep(backoff_delay);
            }

            # Get current version from database (or L1 cache if available)
            current_version = anchor.version;

            # Build JSON path updates for each field using json_set
            # This creates an atomic UPDATE query that modifies only the specified fields
            update_chain = "data";
            params = [];

            for (field_name, field_value) in fields.items() {
                # Serialize the field value to JSON
                serialized_value = Serializer._serialize_value(
                    field_value, include_type=True
                );
                # Build nested json_set calls: json_set(data, '$.archetype.field', value)
                json_path = f"$.archetype.{field_name}";
                update_chain = f"json_set({update_chain}, ?, ?)";
                params.extend([json_path, json.dumps(serialized_value)]);
            }

            # Execute atomic UPDATE with optimistic locking (version check)
            # This will only update if the version matches (no one else modified it)
            params.extend([current_version, key, current_version]);
            update_sql = f"""
                UPDATE anchors
                SET data = {update_chain},
                    version = version + 1
                WHERE id = ? AND version = ?
            """;

            cursor = self.__conn__.execute(update_sql, params);
            rows_affected = cursor.rowcount;

            if rows_affected == 0 {
                # Version mismatch - someone else updated this anchor
                # Fetch fresh version and retry
                cursor = self.__conn__.execute(
                    "SELECT version FROM anchors WHERE id = ?", (key, )
                );
                row = cursor.fetchone();
                if row {
                    # Document exists but version changed - optimistic lock conflict
                    logger.debug(
                        f"Optimistic lock conflict for anchor {key} "
                        f"(expected v{current_version}, found v{row[0]}). "
                        f"Retry {attempt + 1}/{max_retries}"
                    );
                    # Refetch the anchor to get latest version
                    fresh_anchor = self.get(anchor.id);
                    if fresh_anchor {
                        anchor.version = fresh_anchor.version;
                        # Retry with fresh version
                        continue;
                    }
                } else {
                    # Document doesn't exist - create it with full put
                    self.__conn__.rollback();
                    self.put(anchor);
                    return;
                }
            } else {
                # Success! Update completed atomically
                self.__conn__.commit();
                # Update anchor version in memory to match database
                anchor.version = current_version + 1;
                # OPTION A: Invalidate L1 cache to prevent stale reads
                # Remove from L1 cache - next access will refetch fresh data from database
                # This is the safest approach: guarantees no stale reads within same request
                if anchor.id in self.__mem__ {
                    del self.__mem__[anchor.id];
                    logger.debug(
                        f"L1 cache invalidated for anchor {key} after partial update"
                    );
                }
                logger.debug(
                    f"Partial update succeeded for anchor {key}: "
                    f"updated {len(fields)} fields (v{current_version} -> v{current_version + 1})"
                );
                return;
            }
        } except Exception as e {
            logger.warning(
                f"SqliteMemory.partial_update attempt {attempt + 1} failed: {e}"
            );
            self.__conn__.rollback();
            if attempt == max_retries - 1 {
                # Last attempt failed - fall back to full put
                logger.error(
                    f"All {max_retries} partial_update attempts failed for {key}, "
                    "falling back to full put"
                );
                self.put(anchor);
                return;
            }
            # Retry
            continue;
        }
    }

    # If we exhausted all retries due to version conflicts
    logger.error(
        f"Exhausted {max_retries} retries due to optimistic lock conflicts for {key}, "
        "falling back to full put"
    );
    self.put(anchor);
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

"""Commit - syncs pending changes to database and auto-persists dirty fields."""
impl SqliteMemory.commit(anchor: (Anchor | None) = None) -> None {
    # Auto-persist all dirty archetypes in cache before syncing
    for cached_anchor in `list(self.__mem__.values()) {
        try {
            if cached_anchor.is_populated() and cached_anchor.persistent {
                archetype = cached_anchor.archetype;
                # Check if force full sync flag is set (due to dirty field overflow)
                if archetype.__dict__.get('__jac_force_full_sync__', False) {
                    # Do a full put instead of partial update
                    self.put(cached_anchor);
                    # Clear the force full sync flag
                    if '__jac_force_full_sync__' in archetype.__dict__ {
                        del archetype.__dict__['__jac_force_full_sync__'];
                    }
                    # Clear dirty fields after persisting
                    archetype.__jac_clear_dirty__();
                } elif dirty_fields := archetype.__jac_dirty_fields__() {
                    # Check if this archetype has dirty fields tracked
                    # Build the fields dict from dirty field names FIRST
                    fields_dict = {};
                    for field_name in dirty_fields {
                        if hasattr(archetype, field_name) {
                            fields_dict[field_name] = getattr(archetype, field_name);
                        }
                    }
                    # Perform partial update if we have fields to update
                    if fields_dict {
                        # CRITICAL: Backup dirty fields BEFORE clearing
                        # If update fails, we restore these so next commit can retry
                        dirty_copy = dirty_fields.copy();

                        # Clear dirty fields BEFORE update to prevent infinite retry loop
                        # (If update fails mid-transaction, we don't want to retry same fields forever)
                        archetype.__jac_clear_dirty__();

                        try {
                            # Attempt the update (may fail due to network, lock, etc.)
                            self.partial_update(cached_anchor, fields_dict);
                            # Success! Dirty fields cleared, no restore needed
                        } except Exception as update_error {
                            # CRITICAL: Restore dirty fields for next commit retry
                            # This prevents data loss when update fails
                            if '__jac_dirty_fields__' not in archetype.__dict__ {
                                archetype.__dict__['__jac_dirty_fields__'] = set();
                            }
                            archetype.__dict__['__jac_dirty_fields__'].update(dirty_copy);
                            # Re-raise to trigger transaction rollback
                            raise update_error;
                        }
                    }
                }
            }
        } except Exception as e {
            logger.error(f"Auto-persist failed for anchor {cached_anchor.id}: {e}");
            # Continue with other anchors even if one fails
            0;
        }
    }
    self.sync();
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

"""Commit - syncs L3 persistence if available and auto-persists dirty fields."""
impl TieredMemory.commit(anchor: (Anchor | None) = None) -> None {
    # Auto-persist all dirty archetypes in L1 cache before syncing
    for cached_anchor in `list(self.__mem__.values()) {
        try {
            if cached_anchor.is_populated() and cached_anchor.persistent {
                archetype = cached_anchor.archetype;
                # Check if force full sync flag is set (due to dirty field overflow)
                if archetype.__dict__.get('__jac_force_full_sync__', False) {
                    # Do a full put instead of partial update
                    self.put(cached_anchor);
                    # Clear the force full sync flag
                    if '__jac_force_full_sync__' in archetype.__dict__ {
                        del archetype.__dict__['__jac_force_full_sync__'];
                    }
                    # Clear dirty fields after persisting
                    archetype.__jac_clear_dirty__();
                } elif dirty_fields := archetype.__jac_dirty_fields__() {
                    # Check if this archetype has dirty fields tracked
                    # Build the fields dict from dirty field names FIRST
                    fields_dict = {};
                    for field_name in dirty_fields {
                        if hasattr(archetype, field_name) {
                            fields_dict[field_name] = getattr(archetype, field_name);
                        }
                    }
                    # Perform partial update if we have fields to update
                    if fields_dict {
                        # Copy dirty fields before clearing
                        dirty_copy = set(dirty_fields);

                        # Clear dirty fields BEFORE update to prevent infinite retry
                        archetype.__jac_clear_dirty__();

                        try {
                            if self.l3 and self.l3?.partial_update {
                                # Use partial update to avoid race conditions
                                self.l3.partial_update(cached_anchor, fields_dict);

                                # Invalidate L1 cache (safest - prevents stale reads)
                                # Next access will refetch fresh data from L3
                                if cached_anchor.id in self.__mem__ {
                                    del self.__mem__[cached_anchor.id];
                                }

                                # Invalidate L2 cache for this anchor
                                if self.l2 and self.l2?.invalidate {
                                    self.l2.invalidate(cached_anchor.id);
                                }
                            } else {
                                # Fall back to full put if partial_update not available
                                self.put(cached_anchor);
                            }
                        } except Exception as update_error {
                            # On failure, restore dirty fields for retry
                            if '__jac_dirty_fields__' not in archetype.__dict__ {
                                archetype.__dict__['__jac_dirty_fields__'] = set();
                            }
                            archetype.__dict__['__jac_dirty_fields__'].update(
                                dirty_copy
                            );
                            # Re-raise to be caught by outer exception handler
                            raise update_error;
                        }
                    }
                }
            }
        } except Exception as e {
            logger.warning(f"Auto-persist failed for anchor {cached_anchor.id}: {e}");
            # Continue with other anchors even if one fails
            0;
        }
    }
    # Now sync L3
    if self.l3 {
        self.l3.sync();
    }
}
