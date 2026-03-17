"""MongoDB PersistenceBackend Implementation."""

"""Post-initialization: connect to MongoDB."""
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

"""Get anchor by UUID from MongoDB."""
impl MongoBackend.get(id: UUID) -> (Anchor | None) {
    if self.client is None {
        return None;
    }
    _id = to_uuid(id);
    try {
        db_obj = self.collection.find_one({'_id': str(_id)});
        if db_obj {
            return self._load_anchor(db_obj);
        }
    } except Exception as e {
        logger.debug(f"MongoDB get failed: {e}");
    }
    return None;
}

"""Store anchor in MongoDB."""
impl MongoBackend.put(anchor: Anchor) -> None {
    if self.client is None or not anchor.persistent {
        return;
    }
    _id = to_uuid(anchor.id);
    try {
        data = Serializer.serialize(anchor, include_type=True);
        # Increment version on every put
        anchor.version += 1;
        self.collection.update_one(
            {'_id': str(_id)},
            {
                '$set': {
                    'data': data,
                    'type': type(anchor).__name__,
                    'version': anchor.version
                }
            },
            upsert=True
        );
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
"""Sync - no-op for MongoDB (writes are immediate)."""
impl MongoBackend.sync -> None {
# No-op: MongoDB writes are immediate
}

"""Bulk store multiple anchors."""
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
            data = Serializer.serialize(anchor, include_type=True);
            ops.append(
                UpdateOne(
                    {'_id': str(_id)},
                    {'$set': {'data': data, 'type': type(anchor).__name__}},
                    upsert=True
                )
            );
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

"""Partially update an anchor's archetype fields with optimistic locking.

Uses MongoDB's atomic $set operations with version-based optimistic locking.
Uses findOneAndUpdate to get the merged result for read-your-writes consistency.
"""
impl MongoBackend.partial_update(
    anchor: Anchor, fields: (dict[str, object] | None) = None
) -> None {
    if self.client is None or not anchor.persistent {
        return;
    }
    _id = to_uuid(anchor.id);
    # If no fields specified, fall back to full put
    if fields is None or not fields {
        self.put(anchor);
        return;
    }

    # Retry loop for optimistic lock conflicts
    max_retries = 3;
    for attempt in range(max_retries) {
        try {
            # Get current version from anchor
            current_version = anchor.version;

            # Build MongoDB $set operation for only the specified archetype fields
            update_ops = {};
            for (field_name, field_value) in fields.items() {
                # Serialize the field value
                serialized_value = Serializer._serialize_value(
                    field_value, include_type=True
                );
                # Use MongoDB dot notation to update nested field in data.archetype
                update_ops[f"data.archetype.{field_name}"] = serialized_value;
            }

            if update_ops {
                # Serialize the full anchor for $setOnInsert (used only if document doesn't exist)
                full_data = Serializer.serialize(anchor, include_type=True);

                # Use findOneAndUpdate with optimistic locking (version check)
                # This atomically:
                # 1. Checks the version matches (no concurrent modification)
                # 2. Updates only the specified fields
                # 3. Increments the version
                # 4. Returns the UPDATED document for read-your-writes
                result = self.collection.find_one_and_update(
                    {'_id': str(_id), 'version': current_version},
                    {
                        '$set': update_ops,  # Update specified fields
                        '$inc': {'version': 1},  # Atomic version increment
                        '$setOnInsert': {
                            'data': full_data,
                            'type': type(anchor).__name__,
                            'version': 0  # Will be incremented to 1 by $inc
                        }
                    },
                    upsert=True,
                    return_document=True  # Return the document AFTER update
                );

                if result {
                    # Check if this was an insert (upsert created new doc)
                    was_insert = result.get('version', 0) == 1 and current_version == 0;

                    if was_insert or result.get('version', 0) == current_version + 1 {
                        # Success! Update completed
                        # Update L1 cache with the actual merged result from MongoDB
                        updated_anchor = self._load_anchor(result);
                        if updated_anchor {
                            # Update anchor version to match database
                            anchor.version = result.get('version', current_version + 1);

                            logger.debug(
                                f"MongoDB partial_update succeeded: updated {len(
                                    update_ops
                                )} "
                                f"fields for anchor {_id} (v{current_version} -> v{anchor.version})"
                            );
                            return;
                        }
                    } else {
                        # Version mismatch - concurrent modification detected
                        actual_version = result.get('version', -1);
                        logger.debug(
                            f"Optimistic lock conflict for anchor {_id} "
                            f"(expected v{current_version}, found v{actual_version}). "
                            f"Retry {attempt + 1}/{max_retries}"
                        );
                        # Refetch to get latest version and retry
                        fresh_doc = self.collection.find_one({'_id': str(_id)});
                        if fresh_doc {
                            anchor.version = fresh_doc.get('version', 0);
                            # Retry with fresh version
                            continue;
                        }
                    }
                } else {
                    # findOneAndUpdate returned None - document might not exist
                    # or version mismatch prevented update
                    logger.debug(
                        f"MongoDB findOneAndUpdate returned None for {_id}, "
                        f"checking if document exists..."
                    );
                    # Check if document exists with different version
                    existing = self.collection.find_one({'_id': str(_id)});
                    if existing {
                        # Version conflict - retry with correct version
                        anchor.version = existing.get('version', 0);
                        logger.debug(
                            f"Version conflict detected, retrying with v{anchor.version}"
                        );
                        continue;
                    } else {
                        # Document doesn't exist - do full put
                        self.put(anchor);
                        return;
                    }
                }
            }
        } except Exception as e {
            logger.warning(f"MongoDB partial_update attempt {attempt + 1} failed: {e}");
            if attempt == max_retries - 1 {
                # Last attempt failed - fall back to full put
                logger.error(
                    f"All {max_retries} MongoDB partial_update attempts failed for {_id}, "
                    "falling back to full put"
                );
                self.put(anchor);
                return;
            }
            # Retry
            continue;
        }
    }

    # Exhausted all retries
    logger.error(
        f"Exhausted {max_retries} retries due to optimistic lock conflicts for {_id}, "
        "falling back to full put"
    );
    self.put(anchor);
}

"""Load anchor from raw MongoDB document."""
impl MongoBackend._load_anchor(raw: dict[(str, Any)]) -> (Anchor | None) {
    if 'data' not in raw {
        return None;
    }
    try {
        data = raw['data'];
        anchor = Serializer.deserialize(data);
        # Set version from MongoDB document if available
        if anchor and isinstance(anchor, Anchor) {
            anchor.version = raw.get('version', 0);
        }
        return anchor;
    } except Exception as e {
        doc_id = raw.get('_id', '<unknown>');
        doc_type = raw.get('type', '<unknown>');
        logger.warning(
            f"MongoDB _load_anchor failed to deserialize anchor "
            f"(id={doc_id}, type={doc_type}): {e}. "
            f"This anchor will be skipped. Data may be from an incompatible "
            f"version or the class definition has changed."
        );
        return None;
    }
}
