"""ScaleTieredMemory Implementation - Multi-tier storage coordination.

Storage configuration comes from environment variables or jac.toml.
"""
import logging;
import from jaclang.runtimelib.memory { SqliteMemory }

glob logger = logging.getLogger(__name__);

"""Initialize ScaleTieredMemory with distributed backends."""
impl ScaleTieredMemory.init(use_cache: bool = True) -> None {
    # L1: Initialize volatile memory (inherited from VolatileMemory via TieredMemory)
    self.__mem__ = {};
    self.__gc__ = set();
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
        self.l3 = SqliteMemory(path=_db_config['shelf_db_path']);
        self._persistence_type = PersistenceType.SQLITE;
        logger.debug("MongoDB not available, using SqliteMemory for persistence");
        # Show subtle message
        try {
            import from jaclang.cli.console { console }
            logger.debug("  ✔ Using SQLite for persistence", style="muted");
        } except Exception { }
    }
}

"""Commit - sync all modified persistent anchors to MongoDB."""
impl ScaleTieredMemory.commit(anchor: (Anchor | None) = None) -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    import from jaclang.pycore.archetype { NodeAnchor, Root }
    import from pickle { dumps }
    # Only needed for MongoDB - SQLite handles this via its own sync()
    if not isinstance(self.l3, MongoBackend) {
        # Delegate to base TieredMemory.commit() for SQLite
        if self.l3 {
            self.l3.sync();
        }
        return;
    }
    # Sync all modified persistent anchors in L1 to MongoDB.
    # An anchor is considered modified if its current pickle hash differs from
    # the hash recorded when it was loaded (anchor.hash set in __setstate__).
    for (id, mem_anchor) in list(self.__mem__.items()) {
        if not mem_anchor.persistent {
            continue;
        }
        # Skip newly created anchors (hash==0 means never loaded from DB, already
        # written by TieredMemory.put via check_write_access at creation time)
        if mem_anchor.hash == 0 {
            continue;
        }
        # Detect if this anchor has been modified since it was loaded from MongoDB.
        # EdgeAnchors whose source/target stubs have been populated will change hash,
        # but we only need to re-persist NodeAnchors (for edge list) and any anchor
        # whose archetype fields changed.
        current_hash = hash(dumps(mem_anchor));
        if current_hash == mem_anchor.hash {
            continue;  # Unchanged, skip MongoDB read
        }
        # Load the current stored version from MongoDB to merge changes
        stored = self.l3.get(id);
        if stored {
            updated = False;
            # Handle edge list updates (requires CONNECT access)
            if (
                isinstance(stored, NodeAnchor)
                and isinstance(mem_anchor, NodeAnchor)
                and stored.edges != mem_anchor.edges
                and Jac.check_connect_access(mem_anchor)
            ) {
                stored.edges = mem_anchor.edges;
                updated = True;
            }
            # Handle archetype and access updates (requires WRITE access)
            if Jac.check_write_access(mem_anchor) {
                if hash(dumps(stored.access)) != hash(dumps(mem_anchor.access)) {
                    stored.access = mem_anchor.access;
                    updated = True;
                }
                if hash(dumps(stored.archetype)) != hash(dumps(mem_anchor.archetype)) {
                    stored.archetype = mem_anchor.archetype;
                    updated = True;
                }
            }
            if updated {
                self.l3.put(stored);
            }
        }
    }
}

"""Close all backends."""
impl ScaleTieredMemory.close -> None {
    # Flush any pending modifications before closing
    self.commit();
    # Close L3 persistence
    if self.l3 {
        self.l3.close();
    }
    # Close L2 cache
    if self.l2 {
        self.l2.close();
    }
    # Clear L1 (inherited from VolatileMemory)
    self.__mem__.clear();
    self.__gc__.clear();
}
