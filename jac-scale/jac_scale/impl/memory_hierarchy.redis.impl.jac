"""Redis CacheBackend Implementation."""

"""Post-initialization: connect to Redis using a process-level shared client."""
impl RedisBackend.postinit -> None {
    if self.redis_url is None {
        self.redis_url = _get_db_config().get('redis_url');
    }
    if not self.redis_url {
        return;
    }
    if 'redis_client' not in _process_cache {
        try {
            db_config = _get_db_config();
            max_connections = db_config.get('redis_max_connections', 20);
            _process_cache['redis_client'] = redis.from_url(
                self.redis_url, max_connections=max_connections
            );
        } except Exception as e {
            logger.warning(f"Redis connection failed: {e}");
        }
    }
    self.redis_client = _process_cache.get('redis_client');
}

"""Check if Redis is available and connected."""
impl RedisBackend.is_available -> bool {
    if _process_cache.get('redis_available') is True {
        return True;
    }
    if self.redis_client is None {
        return False;
    }
    try {
        self.redis_client.ping();
        _process_cache['redis_available'] = True;
        return True;
    } except Exception as e {
        logger.debug(f"Redis availability check failed: {e}");
        return False;
    }
}

"""Get anchor by UUID from Redis cache."""
impl RedisBackend.get(id: UUID) -> (Anchor | None) {
    if self.redis_client is None {
        return None;
    }
    self.fetch_count += 1;
    key = storage_key(to_uuid(id));
    try {
        raw = self.redis_client.get(key);
        if not raw {
            return None;
        }
        data = json.loads(raw);
        return Serializer.deserialize(data);
    } except Exception as e {
        logger.debug(f"Redis get failed: {e}");
        return None;
    }
}

"""Reset get/put counters (for instrumentation/tests)."""
impl RedisBackend.reset_counters -> None {
    self.fetch_count = 0;
    self.put_count = 0;
}

"""Store anchor in Redis cache."""
impl RedisBackend.put(anchor: Anchor) -> None {
    if self.redis_client is None {
        return;
    }
    self.put_count += 1;
    try {
        data = Serializer.serialize(anchor, include_type=True);
        key = storage_key(anchor.id);

        # Get TTL from config
        db_config = _get_db_config();
        ttl = db_config.get('redis_default_ttl', 0);

        # Apply TTL if configured (ttl > 0)
        if ttl > 0 {
            self.redis_client.setex(key, ttl, json.dumps(data));
            logger.debug(f"Stored anchor {anchor.id} in Redis with TTL={ttl}s");
        } else {
            self.redis_client.set(key, json.dumps(data));
        }
    } except Exception as e {
        logger.debug(f"Redis put failed: {e}");
    }
}

"""Delete anchor from Redis cache."""
impl RedisBackend.delete(id: UUID) -> None {
    if self.redis_client is None {
        return;
    }
    try {
        key = storage_key(to_uuid(id));
        self.redis_client.delete(key);
    } except Exception as e {
        logger.debug(f"Redis delete failed: {e}");
    }
}

"""Close Redis connection. The pub/sub listener is process-level and outlives any single request."""
impl RedisBackend.close -> None {
    self._pubsub_listener = None;
    self.redis_client = None;
}

"""Publish an anchor UUID to the cross-pod invalidation channel.

The message is prefixed with this process's pod_id so the listener on the
same pod can skip it and avoid evicting its own freshly-written L1 entry.
"""
impl RedisBackend.publish_invalidation(id: UUID) -> None {
    if self.redis_client is None {
        return;
    }
    try {
        import from uuid { uuid4 }
        pod_id = _process_cache.setdefault('pod_id', str(uuid4()));
        self.redis_client.publish("jac:anchor:invalidate", f"{pod_id}:{str(id)}");
    } except Exception as e {
        logger.debug(f"Redis publish_invalidation failed: {e}");
    }
}

"""Subscribe to the cross-pod invalidation channel; evict stale L1 entries on receive.

One listener thread is shared across all requests in the process (stored in
_process_cache['pubsub_listener']). The callback evicts from every active L1
registered in _process_cache['l1_registry'] so concurrent requests all benefit.

Messages are formatted as "pod_id:anchor_uuid". If the pod_id matches this
process, the message was self-published — skip it so the writing pod does not
evict its own freshly-updated L1 entry.

On connection error the handler stops the thread and clears _process_cache so
the next request can re-register, recovering from a Redis restart automatically.
The handler does not capture `self` so the per-request RedisBackend is not
kept alive by the process-level thread.
"""
impl RedisBackend.start_invalidation_listener(evict_cb: Any) -> None {
    if self.redis_client is None {
        return;
    }
    existing = _process_cache.get('pubsub_listener');
    if existing is not None {
        self._pubsub_listener = existing;
        return;
    }
    try {
        def _handle_invalidation(message: Any) {
            try {
                raw = message.get('data', b'');
                id_str = raw.decode('utf-8') if isinstance(raw, bytes) else str(raw);
                if not id_str {
                    return;
                }
                # Messages are "pod_id:anchor_uuid"; skip self-originated ones.
                if ':' in id_str {
                    parts = id_str.split(':', 1);
                    src_pod_id = parts[0];
                    anchor_uuid_str = parts[1];
                    if src_pod_id == _process_cache.get('pod_id') {
                        return;
                    }
                } else {
                    anchor_uuid_str = id_str;
                }
                anchor_id = UUID(anchor_uuid_str);
                for l1 in list(_process_cache.get('l1_registry', {}).values()) {
                    l1.pop(anchor_id, None);
                }
            } except Exception as e {
                logger.debug(f"Redis invalidation handler error: {e}");
            }
        }
        # Bug-fix: call thread.stop() to break the run loop on disconnect so
        # the thread does not busy-spin. Do NOT reference `self` here — keeping
        # `self` out of the closure prevents the per-request RedisBackend from
        # being held alive by the process-level thread indefinitely.
        def _on_thread_error(ex: Any, pubsub: Any, thread: Any) {
            logger.debug(f"Redis invalidation listener thread error: {ex}");
            thread.stop();
            _process_cache.pop('pubsub_listener', None);
        }
        pubsub = self.redis_client.pubsub(ignore_subscribe_messages=True);
        pubsub.subscribe(**{"jac:anchor:invalidate": _handle_invalidation});
        self._pubsub_listener = pubsub.run_in_thread(
            sleep_time=0.05, daemon=True, exception_handler=_on_thread_error
        );
        _process_cache['pubsub_listener'] = self._pubsub_listener;
        logger.debug("Redis cross-pod invalidation listener started");
    } except Exception as e {
        logger.debug(f"Redis start_invalidation_listener failed: {e}");
    }
}

"""Check if an anchor is in the cache."""
impl RedisBackend.`has(id: UUID) -> bool {
    return self.exists(id);
}

"""Query all anchors - not supported for distributed cache."""
impl RedisBackend.query(
    filter: (Callable[[Anchor], bool] | None) = None
) -> Generator[Anchor, None, None] {
    # Redis doesn't support iteration efficiently
    return;
    yield ;
}

"""Get all root anchors - not supported for distributed cache."""
impl RedisBackend.get_roots -> Generator[Root, None, None] {
    return;
    yield ;
}

"""Find anchors by IDs with optional filter."""
impl RedisBackend.find(
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
impl RedisBackend.find_one(
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

"""Commit - no-op for cache."""
impl RedisBackend.commit(anchor: (Anchor | None) = None) -> None {
# No-op: cache doesn't need commit
}

"""Batch get from Redis cache using a single MGET pipeline call."""
impl RedisBackend.batch_get(ids: list[UUID]) -> dict[UUID, Anchor] {
    result: dict[UUID, Anchor] = {};
    if not ids or self.redis_client is None {
        return result;
    }
    self.fetch_count += len(ids);
    try {
        keys = [storage_key(to_uuid(id)) for id in ids];
        values = self.redis_client.mget(keys);
        for (id, raw) in zip(ids, values) {
            if raw {
                try {
                    data = json.loads(raw);
                    anchor = Serializer.deserialize(data);
                    if anchor {
                        result[id] = anchor;
                    }
                } except Exception as e {
                    logger.debug(f"Redis batch_get deserialize failed for {id}: {e}");
                }
            }
        }
    } except Exception as e {
        logger.debug(f"Redis batch_get failed: {e}");
    }
    return result;
}

"""Batch write anchors to Redis cache."""
impl RedisBackend.batch_put(anchors: list[Anchor]) -> None {
    for anchor in anchors {
        self.put(anchor);
    }
}

# CacheMemory-specific methods
"""Check if key exists in cache."""
impl RedisBackend.exists(id: UUID) -> bool {
    if self.redis_client is None {
        return False;
    }
    try {
        key = storage_key(to_uuid(id));
        return bool(self.redis_client.exists(key));
    } except Exception {
        return False;
    }
}

"""Store anchor only if it already exists in cache."""
impl RedisBackend.put_if_exists(anchor: Anchor) -> bool {
    if self.redis_client is None {
        return False;
    }
    if not self.exists(anchor.id) {
        return False;
    }
    self.put(anchor);
    return True;
}

"""Remove an entry from cache."""
impl RedisBackend.invalidate(id: UUID) -> None {
    self.delete(id);
}

"""Get anchor by UUID using native redis.asyncio (no asyncio.to_thread)."""
impl RedisBackend.aget(id: UUID) -> (Anchor | None) {
    import from jac_scale._optdeps.redis { AsyncRedis, HAS_REDIS }
    if not HAS_REDIS or AsyncRedis is None {
        return await super.aget(id);
    }
    if self._async_redis is None {
        if self.redis_url is None {
            return await super.aget(id);
        }
        self._async_redis = AsyncRedis.from_url(self.redis_url);
    }
    key = storage_key(to_uuid(id));
    try {
        raw = await self._async_redis.get(key);
        if not raw {
            return None;
        }
        data = json.loads(raw);
        return Serializer.deserialize(data);
    } except Exception as e {
        logger.debug(f"Redis async get failed: {e}");
        return None;
    }
}

"""Store anchor using native redis.asyncio (no asyncio.to_thread)."""
impl RedisBackend.aput(anchor: Anchor) -> None {
    import from jac_scale._optdeps.redis { AsyncRedis, HAS_REDIS }
    if not HAS_REDIS or AsyncRedis is None {
        await super.aput(anchor);
        return;
    }
    if self._async_redis is None {
        if self.redis_url is None {
            await super.aput(anchor);
            return;
        }
        self._async_redis = AsyncRedis.from_url(self.redis_url);
    }
    try {
        data = Serializer.serialize(anchor, include_type=True);
        key = storage_key(anchor.id);
        db_config = _get_db_config();
        ttl = db_config.get('redis_default_ttl', 0);
        if ttl > 0 {
            await self._async_redis.setex(key, ttl, json.dumps(data));
        } else {
            await self._async_redis.set(key, json.dumps(data));
        }
    } except Exception as e {
        logger.debug(f"Redis async put failed: {e}");
    }
}
