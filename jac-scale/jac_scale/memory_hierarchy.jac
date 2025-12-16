"""Base memory hierachy implementation with timeout resilience."""
import os;
import shelve;
import from collections.abc { Iterable, MutableMapping }
import from pickle { dumps, loads }
import from threading { RLock }
import from typing { Any, TypeVar, cast }
import from uuid { UUID }
import redis;
import from pymongo { MongoClient, UpdateOne }
import from pymongo.errors { ConnectionFailure, ServerSelectionTimeoutError, NetworkTimeout }
import from jaclang.runtimelib.archetype { TANCH, Anchor }
import from jaclang.runtimelib.memory { Memory }
import from time { time }

glob ID = TypeVar('ID');

obj MultiHierarchyMemory(Memory[(UUID, Anchor)]) {
    has redis_failures: int = 0;
    has mongo_failures: int = 0;
    has max_failures: int = 5;
    has failure_reset_time: float = 300.0;  
    has last_redis_failure_time: float = 0.0;
    has last_mongo_failure_time: float = 0.0;

    def init() -> None {
        super.init();
        self.mem = Memory[(UUID, Anchor)]();
        self.redis = RedisDB();
        self.mongo = MongoDB();
        self.redis_available = self.redis.redis_is_available();
        self.mongo_available = self.mongo.mongo_is_available();
        self.shelf: (ShelfDB | None) = None;
    }

    def postinit() -> None {
        if (not self.redis_available and not self.mongo_available) {
            self.shelf = ShelfDB();
        }
    }

    def _should_skip_redis() -> bool {
        if (self.redis_failures >= self.max_failures) {
            if (time() - self.last_redis_failure_time > self.failure_reset_time) {
                self.redis_failures = 0; 
                return False;
            }
            return True;
        }
        return False;
    }

    def _should_skip_mongo() -> bool {
        if (self.mongo_failures >= self.max_failures) {
            if (time() - self.last_mongo_failure_time > self.failure_reset_time) {
                self.mongo_failures = 0;
                return False;
            }
            return True;
        }
        return False;
    }

    def _record_redis_failure() -> None {
        self.redis_failures += 1;
        self.last_redis_failure_time = time();
    }

    def _record_mongo_failure() -> None {
        self.mongo_failures += 1;
        self.last_mongo_failure_time = time();
    }

    def find_by_id(id: UUID) -> (Anchor | None) {
        if (anchor := self.mem.find_by_id(id)) {
            return anchor;
        }

        if (self.redis_available and not self._should_skip_redis()) {
            try {
                if (anchor := self.redis.find_by_id(id)) {
                    self.mem.set(anchor);
                    return anchor;
                }
            } except (redis.TimeoutError, redis.ConnectionError, Exception) {
                self._record_redis_failure();
            }
        }

        if (self.mongo_available and not self._should_skip_mongo()) {
            try {
                if (anchor := self.mongo.find_by_id(id)) {
                    self.mem.set(anchor);
                    if (self.redis_available and not self._should_skip_redis()) {
                        try {
                            self.redis.set(anchor);
                        } except (redis.TimeoutError, redis.ConnectionError, Exception) {
                            self._record_redis_failure();
                        }
                    }
                    return anchor;
                }
            } except (ServerSelectionTimeoutError, NetworkTimeout, Exception) {
                self._record_mongo_failure();
            }
        } elif self.shelf {
            try {
                if (anchor := self.shelf.find_by_id(id)) {
                    self.mem.set(anchor);
                    return anchor;
                }
            } except Exception {
                
                pass;
            }
        }

        return None;
    }

    def commit(anchor: (Anchor | None) = None) {
        gc = self.mem.get_gc();
        memory = self.mem.get_mem();
        if (anchor) {
            if (anchor in gc) {
                self.delete(anchor);
                self.mem.remove_from_gc(anchor);
            } else {
                if (self.redis_available and not self._should_skip_redis()) {
                    try {
                        self.redis.set(anchor);
                    } except (redis.TimeoutError, redis.ConnectionError, Exception) {
                        self._record_redis_failure();
                    }
                }
                if (self.mongo_available and not self._should_skip_mongo()) {
                    try {
                        self.mongo.set(anchor);
                    } except (ServerSelectionTimeoutError, NetworkTimeout, Exception) {
                        self._record_mongo_failure();
                    }
                } elif (self.shelf) {
                    try {
                        self.shelf.set(anchor);
                    } except Exception {
                        
                        pass;
                    }
                }
            }
            return;
        }

        for anchor in gc {
            self.delete(anchor);
            self.mem.remove_from_gc(anchor);
        }
        anchors = <>set(memory.values());
        self.sync(anchors);
    }

    def close() {
        try {
            self.commit();
        } except Exception {
            
            pass;
        }
        
        self.mem.close();

        if (self.redis_available and self.redis.redis_client) {
            try {
                self.redis.redis_client.close();
            } except Exception {
                pass;
            }
        }

        if (self.mongo_available and self.mongo.client) {
            try {
                self.mongo.client.close();
            } except Exception {
                pass;
            }
        }

        if (self.shelf) {
            try {
                self.shelf.close();
            } except Exception {
                pass;
            }
        }
    }

    def sync(anchors: Iterable[Anchor]) -> None {
        if (self.redis_available and not self._should_skip_redis()) {
            try {
                self.redis.commit(keys=anchors);
            } except (redis.TimeoutError, redis.ConnectionError, Exception) {
                self._record_redis_failure();
            }
        }
        if (self.mongo_available and not self._should_skip_mongo()) {
            try {
                self.mongo.commit(keys=anchors);
            } except (ServerSelectionTimeoutError, NetworkTimeout, Exception) {
                self._record_mongo_failure();
            }
        } elif self.shelf {
            try {
                self.shelf.commit(keys=anchors);
            } except Exception {
                pass;
            }
        }
    }

    def delete(anchor: Anchor) {
        self.mem.remove(anchor.id);

        if (self.redis_available and not self._should_skip_redis()) {
            try {
                self.redis.remove(anchor);
            } except (redis.TimeoutError, redis.ConnectionError, Exception) {
                self._record_redis_failure();
            }
        }
        if (self.mongo_available and not self._should_skip_mongo()) {
            try {
                self.mongo.remove(anchor);
            } except (ServerSelectionTimeoutError, NetworkTimeout, Exception) {
                self._record_mongo_failure();
            }
        } elif self.shelf {
            try {
                self.shelf.remove(anchor);
            } except Exception {
                pass;
            }
        }
    }

    def <>set(anchor: TANCH) {
        self.mem.set(anchor);
    }
}

"""MongoDB handler with timeout resilience."""
obj MongoDB {
    has client: (MongoClient | None) = None;
    has db_name: str = 'jac_db';
    has collection_name: str = 'anchors';
    has mongo_url: str = os.environ.get(
        'MONGODB_URI', 'mongodb://root:rootpassword123@localhost:27017/'
    );

    """Initialize MongoDB with proper timeout settings."""
    def postinit() -> None {
        if (self.client is None) {
            self.client = MongoClient(
                self.mongo_url,
                serverSelectionTimeoutMS=5000,
                connectTimeoutMS=5000,
                socketTimeoutMS=30000,
                maxPoolSize=10,
                retryWrites=True
            );
        }
        self.db = self.client[self.db_name];
        self.collection = self.db[self.collection_name];
    }

    def mongo_is_available(
        uri: str = 'mongodb://root:rootpassword123@localhost:27017/'
    ) -> bool {
        client = None;

        try {
            client = MongoClient(
                uri, 
                serverSelectionTimeoutMS=5000,
                connectTimeoutMS=5000
            );

            client.admin.command('ping', maxTimeMS=5000);
            return True;
        } except (ConnectionFailure, ServerSelectionTimeoutError) {
            return False;
        } except Exception {
            return False;
        } finally {
            if (client) {
                client.close();
            }
        }
    }

    def _to_uuid(id: (UUID | str)) -> UUID {
        if not isinstance(id, UUID) {
            return UUID(str(id));
        }
        return id;
    }

    def _load_anchor(raw: dict[(str, Any)]) -> (TANCH | None) {
        try {
            return loads(raw['data']);
        } except Exception {
            return None;
        }
    }

    """
    Save anchor to MongoDB with timeout handling:
        - Save all anchors (no empty NodeAnchor skipping)
        - Update NodeAnchor edges
        - Respect write and connect access
    """
    def <>set(anchor: Anchor) -> None {
        import from jaclang.runtimelib.archetype { NodeAnchor }
        import from jaclang.pycore.runtime { JacRuntimeInterface as Jac }
        _id = self._to_uuid(anchor.id);
        try {
            current_hash = hash(dumps(anchor));
        } except Exception {
            return;
        }
        if (getattr(anchor, 'hash', None) == current_hash) {
            return;
        }
        
        try {
            db_doc = self.collection.find_one(
                {'_id': str(_id)},
                maxTimeMS=5000
            );
        } except (ServerSelectionTimeoutError, NetworkTimeout) {
            return;
        }
        
        stored_anchor = self._load_anchor(db_doc) if db_doc else None;
        if (
            stored_anchor
            and isinstance(stored_anchor, NodeAnchor)
            and isinstance(anchor, NodeAnchor)
            and (
                getattr(stored_anchor, 'edges', None) != getattr(anchor, 'edges', None)
            )
            and Jac.check_connect_access(anchor)
        ) {
            stored_anchor.edges = anchor.edges;
            base_anchor = stored_anchor;
        } else {
            base_anchor = anchor;
        }
        if (stored_anchor and Jac.check_write_access(anchor)) {
            try {
                if (hash(dumps(stored_anchor.access)) != hash(dumps(anchor.access))) {
                    stored_anchor.access = anchor.access;
                }
                if (
                    hash(dumps(stored_anchor.archetype)) != hash(
                        dumps(anchor.archetype)
                    )
                ) {
                    stored_anchor.archetype = anchor.archetype;
                }
                final_anchor = stored_anchor;
            } except Exception {
                final_anchor = anchor;
            }
        } else {
            final_anchor = base_anchor;
        }
        try {
            data_blob = dumps(final_anchor);
        } except Exception {
            return;
        }
        
        try {
            self.collection.update_one(
                {'_id': str(_id)},
                {'$set': {'data': data_blob, 'type': <>type(final_anchor).__name__}},
                upsert=True
            );
        } except (ServerSelectionTimeoutError, NetworkTimeout) {
            return;
        }
    }

    def remove(anchor: TANCH) -> None {
        _id = self._to_uuid(anchor.id);
        try {
            self.collection.delete_one({'_id': str(_id)});
        } except (ServerSelectionTimeoutError, NetworkTimeout) {
            return;
        }
    }

    def find_by_id(id: UUID) -> (Anchor | None) {
        _id = self._to_uuid(id);
        try {
            db_obj = self.collection.find_one(
                {'_id': str(_id)},
                maxTimeMS=5000
            );
        } except (ServerSelectionTimeoutError, NetworkTimeout) {
            return None;
        }
        
        if db_obj {
            anchor = self._load_anchor(db_obj);
            if anchor {
                return anchor;
            }
        }
        return None;
    }

    """
    Faster bulk commit with chunking and timeout handling:
        - Save all anchors (no empty NodeAnchor skipping)
        - Update NodeAnchor edges
        - Respect write and connect access
    """
    def commit_bulk(anchors: Iterable[Anchor]) -> None {
        import from jaclang.runtimelib.archetype { NodeAnchor }
        import from jaclang.pycore.runtime { JacRuntimeInterface as Jac }
        
        ops: list = [];
        batch_size = 100;  
        
        for anc in anchors {
            _id = self._to_uuid(anc.id);
            try {
                current_hash = hash(dumps(anc));
            } except Exception {
                continue;
            }
            if (getattr(anc, 'hash', None) == current_hash) {
                continue;
            }
            
            try {
                db_doc = self.collection.find_one(
                    {'_id': str(_id)},
                    maxTimeMS=5000
                );
            } except (ServerSelectionTimeoutError, NetworkTimeout) {
                continue;
            }
            
            stored_anchor = self._load_anchor(db_doc) if db_doc else None;
            if (
                stored_anchor
                and isinstance(stored_anchor, NodeAnchor)
                and isinstance(anc, NodeAnchor)
                and (
                    getattr(stored_anchor, 'edges', None) != getattr(
                        anc, 'edges', None
                    )
                )
                and Jac.check_connect_access(anc)
            ) {
                stored_anchor.edges = anc.edges;
                working_anchor = stored_anchor;
            } else {
                working_anchor = anc;
            }
            if (stored_anchor and Jac.check_write_access(anc)) {
                try {
                    if (hash(dumps(stored_anchor.access)) != hash(dumps(anc.access))) {
                        stored_anchor.access = anc.access;
                    }
                    if (
                        hash(dumps(stored_anchor.archetype)) != hash(
                            dumps(anc.archetype)
                        )
                    ) {
                        stored_anchor.archetype = anc.archetype;
                    }
                    working_anchor = stored_anchor;
                } except Exception {
                    working_anchor = anc;
                }
            }
            try {
                blob = dumps(working_anchor);
            } except Exception {
                continue;
            }
            ops.append(
                UpdateOne(
                    {'_id': str(_id)},
                    {'$set': {'data': blob, 'type': <>type(working_anchor).__name__}},
                    upsert=True
                )
            );
            
            
            if (len(ops) >= batch_size) {
                try {
                    self.collection.bulk_write(ops, ordered=False);
                    ops = [];
                } except (ServerSelectionTimeoutError, NetworkTimeout) {
                    
                    ops = [];
                }
            }
        }
        
        
        if ops {
            try {
                self.collection.bulk_write(ops, ordered=False);
            } except (ServerSelectionTimeoutError, NetworkTimeout) {
               
                pass;
            }
        }
    }

    def commit(anchor: (TANCH | None) = None, keys: Iterable[Anchor] = []) -> None {
        if anchor {
            self.set(anchor);
            return;
        }
        if keys {
            self.commit_bulk(keys);
        }
    }
}

"""Redis-based Memory Handler with timeout resilience."""
obj RedisDB {
    has redis_url: str = os.environ.get(
        'REDIS_URL', 'redis://:mypassword123@localhost:6379/0'
    );
    has redis_client: (redis.Redis | None) = None;

    """Initialize Redis with timeout settings."""
    def postinit() -> None {
        if (self.redis_client is None) {
            self.redis_client = redis.from_url(
                self.redis_url,
                socket_connect_timeout=5,
                socket_timeout=30,
                retry_on_timeout=True,
                health_check_interval=30
            );
        }
    }

    """Check whether Redis connection is alive and reachable."""
    def redis_is_available() -> bool {
        try {
            if (self.redis_client is None) {
                return False;
            }
            return self.redis_client.ping();
        } except (redis.ConnectionError, redis.TimeoutError, Exception) {
            return False;
        }
    }

    def _redis_key(id: UUID) -> str {
        return f"anchor:{str(id)}";
    }

    def _to_uuid(id: (UUID | str)) -> UUID {
        if not isinstance(id, UUID) {
            return UUID(str(id));
        }
        return id;
    }

    def _load_anchor_from_redis(id: UUID) -> (Anchor | None) {
        if (self.redis_client is None) {
            return None;
        }
        key = self._redis_key(id);
        try {
            raw = self.redis_client.get(key);
            if not raw {
                return None;
            }
            return loads(raw);
        } except (redis.TimeoutError, redis.ConnectionError, Exception) {
            return None;
        }
    }

    """Save to Redis with timeout handling."""
    def <>set(anchor: Anchor) -> None {
        if (self.redis_client is None) {
            return;
        }
        try {
            self.redis_client.set(self._redis_key(anchor.id), dumps(anchor));
        } except (redis.TimeoutError, redis.ConnectionError) {
            raise;  
        }
    }

    """Delete from Redis with timeout handling."""
    def remove(anchor: Anchor) -> None {
        if (self.redis_client is None) {
            return;
        }
        try {
            self.redis_client.delete(self._redis_key(anchor.id));
        } except (redis.TimeoutError, redis.ConnectionError) {
            raise;  
        }
    }

    def find_by_id(id: UUID) -> (Anchor | None) {
        _id = self._to_uuid(id);
        return self._load_anchor_from_redis(_id);
    }

    """Commit with timeout handling."""
    def commit(anchor: (Anchor | None) = None, keys: Iterable[Anchor] = []) -> None {
        if anchor {
            self.set(anchor);
            return;
        }
        if keys {
            for anc in keys {
                try {
                    self.set(anc);
                } except (redis.TimeoutError, redis.ConnectionError) {
                    
                    continue;
                }
            }
        }
    }
}

"""
Shelf-based Memory Handler with lock timeout handling.
Uses dbm.dumb on all platforms to avoid gdbm locking issues in Linux.
"""
obj ShelfDB {
    has shelf_path: str = os.environ.get('SHELF_DB_PATH', 'anchor_store.db');
    has _shelf: shelve.Shelf | None = None;
    has _lock: RLock | None = None;

    """Initialize shelf DB on startup."""
    def postinit() {
        self._lock = RLock();
        self._open_shelf();
    }

    """Always use dbm.dumb backend to avoid Linux gdbm locking."""
    def _open_shelf() -> shelve.Shelf {
        import dbm.dumb;
        if (self._shelf is None) {
            raw_db = dbm.dumb.open(self.shelf_path, 'c');
            db_as_mapping = cast(MutableMapping[(<>bytes, <>bytes)], raw_db);
            self._shelf = shelve.Shelf(db_as_mapping, writeback=False);
        }
        return self._shelf;
    }

    def _ensure_shelf() -> shelve.Shelf {
        if (self._shelf is None) {
            self._shelf = self._open_shelf();
        }
        return self._shelf;
    }

    """Cleanly close shelf storage."""
    def close() {
        if (self._shelf is not None) {
            try {
                self._shelf.close();
            } except Exception {
                pass;
            }
            self._shelf = None;
        }
    }

    """Match key format used by Redis for consistency."""
    def _redis_key(id: UUID) -> str {
        return f"anchor:{str(id)}";
    }

    def _to_uuid(id: (UUID | str)) -> UUID {
        if not isinstance(id, UUID) {
            return UUID(str(id));
        }
        return id;
    }

    def _load_anchor_from_shelf(id: UUID) -> (Anchor | None) {
        key = self._redis_key(id);
        shelf = self._ensure_shelf();
        
        
        if (self._lock.acquire(timeout=10)) { 
            try {
                if (key not in shelf) {
                    return None;
                }
                return shelf[key];
            } finally {
                self._lock.release();
            }
        } else {
           
            return None;
        }
    }

    """Save anchor to shelf with timeout."""
    def <>set(anchor: Anchor) -> None {
        key = self._redis_key(anchor.id);
        shelf = self._ensure_shelf();
        
        if (self._lock.acquire(timeout=10)) {
            try {
                shelf[key] = anchor;
                shelf.sync();
            } finally {
                self._lock.release();
            }
        }
        
    }

    """Remove anchor from shelf with timeout."""
    def remove(anchor: Anchor) -> None {
        key = self._redis_key(anchor.id);
        shelf = self._ensure_shelf();
        
        if (self._lock.acquire(timeout=10)) {
            try {
                if (key in shelf) {
                    del (shelf[key], );
                    shelf.sync();
                }
            } finally {
                self._lock.release();
            }
        }
    }

    def find_by_id(id: UUID) -> (Anchor | None) {
        _id = self._to_uuid(id);
        return self._load_anchor_from_shelf(_id);
    }

    """Commit one or many anchors with timeout handling."""
    def commit(anchor: (Anchor | None) = None, keys: Iterable[Anchor] = []) -> None {
        if anchor {
            self.set(anchor);
            return;
        }
        for anc in keys {
            try {
                self.set(anc);
            } except Exception {
                
                continue;
            }
        }
    }
}