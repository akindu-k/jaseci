"""ScaleTieredMemory Implementation - Multi-tier storage coordination.

Storage configuration comes from environment variables or jac.toml.
"""

"""Initialize ScaleTieredMemory with distributed backends."""
impl ScaleTieredMemory.init(use_cache: bool = True) -> None {
    # L1: Initialize volatile memory (inherited from VolatileMemory via TieredMemory)
    self.__mem__ = {};
    self.__gc__ = set();
    self.__dirty__ = set();
    # L2: Try to initialize Redis cache (replaces LocalCacheMemory)
    redis_backend = RedisBackend();
    self._cache_available = redis_backend.is_available();
    if self._cache_available and use_cache {
        self.l2 = redis_backend;
        logger.debug("Redis cache backend initialized");
    } else {
        self.l2 = None;
        logger.debug("Redis not available, running without distributed cache");
    }
    # L3: Try MongoDB first (replaces SqliteMemory), fall back to SqliteMemory
    mongo_backend = MongoBackend();
    if mongo_backend.is_available() {
        self.l3 = mongo_backend;
        self._persistence_type = PersistenceType.MONGODB;
        logger.debug("MongoDB persistence backend initialized");
        # Show subtle message (optional - uncomment to enable)
        try {
            import from jaclang.cli.console { console }
            logger.debug("  ✔ Using MongoDB for persistence", style="muted");
        } except Exception { }
    } else {
        # Fall back to jaclang's SqliteMemory using configured path
        self.l3 = SqliteMemory(
            path=get_scale_config().get_database_config()['shelf_db_path']
        );
        self._persistence_type = PersistenceType.SQLITE;
        logger.debug("MongoDB not available, using SqliteMemory for persistence");
        # Show subtle message
        try {
            import from jaclang.cli.console { console }
            logger.debug("  ✔ Using SQLite for persistence", style="muted");
        } except Exception { }
    }
}

"""Override put to track dirty anchors for deferred L3 writes."""
impl ScaleTieredMemory.put(anchor: Anchor) -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    # Always write to L1 (self.__mem__ inherited from VolatileMemory)
    self.__mem__[anchor.id] = anchor;
    # Write-through to L2 (cache) if enabled - cache is always write-through
    if self.l2 {
        self.l2.put(anchor);
    }
    # Track as dirty for deferred L3 write (happens in commit())
    # This avoids writing to L3 on every put() and batches writes at commit time
    if self.l3 and anchor.persistent and Jac.check_write_access(anchor) {
        self.__dirty__.add(anchor.id);
    }
}

"""Commit changes: flush only dirty L1 anchors to persistent storage (MongoDB/SQLite)."""
impl ScaleTieredMemory.commit(anchor: (Anchor | None) = None) -> None {
    if self.l3 is None {
        return;
    }
    # Single anchor commit
    if anchor is not None {
        # Early return if anchor is not valid for persistence
        if not anchor.persistent {
            return;
        }
        # Early return if no write access
        if not Jac.check_write_access(anchor) {
            return;
        }
        try {
            self.l3.put(anchor);
            # Also update L2 cache if available
            if self.l2 {
                self.l2.put(anchor);
            }
            # Remove from dirty set after successful commit
            self.__dirty__.discard(anchor.id);
        } except Exception as e {
            logger.warning(f"ScaleTieredMemory.commit(anchor) failed: {e}");
        }
        return;
    }
    # Early return if no dirty anchors - nothing to commit
    if not self.__dirty__ {
        logger.debug("ScaleTieredMemory.commit: No dirty anchors, skipping");
        return;
    }
    # Flush only dirty L1 anchors to L3 (and L2 if available)
    dirty_ids = list(self.__dirty__);
    committed_ids: list[UUID] = [];
    for anchor_id in dirty_ids {
        # Get anchor from L1 memory
        mem_anchor = self.__mem__.get(anchor_id);
        if not mem_anchor {
            # Anchor was deleted, remove from dirty set
            self.__dirty__.discard(anchor_id);
            continue;
        }
        if not mem_anchor.persistent or not Jac.check_write_access(mem_anchor) {
            # No longer persistent or no write access, skip but keep in dirty set
            continue;
        }
        try {
            self.l3.put(mem_anchor);
            if self.l2 {
                self.l2.put(mem_anchor);
            }
            # Track successfully committed anchors
            committed_ids.append(anchor_id);
        } except Exception as e {
            logger.warning(
                f"ScaleTieredMemory.commit flush failed for anchor "
                f"{mem_anchor.id}: {e}"
            );
        }
    }
    # Clear dirty flags for successfully committed anchors
    for committed_id in committed_ids {
        self.__dirty__.discard(committed_id);
    }
    logger.debug(
        f"ScaleTieredMemory.commit: Committed {len(committed_ids)} of "
        f"{len(dirty_ids)} dirty anchors"
    );
}

"""Close all backends."""
impl ScaleTieredMemory.close -> None {
    self.commit();
    # Sync and close L3 persistence
    if self.l3 {
        self.l3.sync();
        self.l3.close();
    }
    # Close L2 cache
    if self.l2 {
        self.l2.close();
    }
    # Clear L1 (inherited from VolatileMemory)
    self.__mem__.clear();
    self.__gc__.clear();
    self.__dirty__.clear();
}
