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

"""Commit changes: flush all modified L1 anchors to MongoDB.

Unlike SqliteMemory (which has its own sync logic), MongoBackend.put() is
write-through only for NEW anchors saved via Jac.save(). It does NOT
automatically re-write anchors that were mutated in L1 memory after being
loaded from MongoDB (e.g. a user-root NodeAnchor whose edges list grows
when a new node is connected via `++>`). This override iterates every
persistent anchor in L1 and re-writes it to MongoDB, so mutations like
edge-list updates survive a server restart.
"""
impl ScaleTieredMemory.commit(anchor: (Any | None) = None) -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    if self.l3 is None or self._persistence_type != PersistenceType.MONGODB {
        # Fall through to base TieredMemory behaviour for SQLite (calls l3.sync())
        if self.l3 {
            self.l3.sync();
        }
        return;
    }
    if anchor is not None {
        # Single-anchor commit (e.g. Jac.commit(specific_anchor))
        import from jaclang.jac0core.archetype { Anchor as _Anchor }
        import from typing { cast }
        try {
            if isinstance(anchor, _Anchor) and anchor.persistent {
                typed_anchor = cast(_Anchor, anchor);
                if Jac.check_write_access(typed_anchor) {
                    self.l3.put(typed_anchor);
                }
            }
        } except Exception as e {
            logger.warning(f"ScaleTieredMemory.commit(anchor) failed: {e}");
        }
        return;
    }
    # Full flush: write back every persistent L1 anchor to MongoDB so
    # mutations (edge list updates, archetype field changes, etc.) are durable.
    for (_, mem_anchor) in list(self.__mem__.items()) {
        if mem_anchor.persistent {
            try {
                if Jac.check_write_access(mem_anchor) {
                    self.l3.put(mem_anchor);
                }
            } except Exception as e {
                logger.warning(
                    f"ScaleTieredMemory.commit flush failed for anchor "
                    f"{mem_anchor.id}: {e}"
                );
            }
        }
    }
}

"""Close all backends."""
impl ScaleTieredMemory.close -> None {
    # Final commit before closing to ensure all L1 mutations are persisted
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
}
