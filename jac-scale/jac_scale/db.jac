"""Direct Database Access Module."""
import from pymongo { MongoClient }
import from pymongo.results {
    InsertOneResult as PyMongoInsertOneResult,
    InsertManyResult as PyMongoInsertManyResult,
    UpdateResult as PyMongoUpdateResult,
    DeleteResult as PyMongoDeleteResult
}
import from pymongo.cursor { Cursor }
import from redis { Redis }
import from jac_scale.factories.database_factory {
    DatabaseProviderFactory,
    DatabaseType,
    _resolve_uri
}
import from bson { ObjectId }
import from uuid { uuid4 }
import json;

glob _mongo_clients: dict[str, MongoClient] = {},
     _redis_clients: dict[str, Redis] = {};

# Result classes for database operations
class InsertResult {
    has inserted_id: str;
}

class InsertManyResult {
    has inserted_ids: list;
}

class UpdateResult {
    has matched_count: int,
        modified_count: int,
        upserted_id: str | None = None;
}

class DeleteResult {
    has deleted_count: int;
}

"""Get or create a MongoDB client for the given URI.

    Uses connection pooling with URI as the key. If URI is None,
    fetches the default URI from configuration.

    Args:
        uri: MongoDB connection URI. If None, uses config default.

    Returns:
        MongoClient instance for the given URI.

    Raises:
        ValueError: If no URI is provided and none found in config.
    """
def get_mongo_client(uri: (str | None) = None) -> MongoClient {
    global _mongo_clients;

    # Resolve URI from config if not provided
    resolved_uri = _resolve_uri(uri, DatabaseType.MONGODB);

    # Return existing client or create new one
    if resolved_uri not in _mongo_clients {
        _mongo_clients[resolved_uri] = DatabaseProviderFactory.create_client(
            DatabaseType.MONGODB, uri=resolved_uri
        );
    }

    return _mongo_clients[resolved_uri];
}

"""Get or create a Redis client for the given URI.

    Uses connection pooling with URI as the key. If URI is None,
    fetches the default URI from configuration.

    Args:
        uri: Redis connection URL. If None, uses config default.

    Returns:
        Redis instance for the given URI.

    Raises:
        ValueError: If no URI is provided and none found in config.
    """
def get_redis_client(uri: (str | None) = None) -> Redis {
    global _redis_clients;

    # Resolve URI from config if not provided
    resolved_uri = _resolve_uri(uri, DatabaseType.REDIS);

    # Return existing client or create new one
    if resolved_uri not in _redis_clients {
        _redis_clients[resolved_uri] = DatabaseProviderFactory.create_client(
            DatabaseType.REDIS, uri=resolved_uri
        );
    }

    return _redis_clients[resolved_uri];
}

"""Close a specific MongoDB client connection.

    Args:
        uri: MongoDB connection URI. If None, closes default connection.
    """
def close_mongo_client(uri: (str | None) = None) -> None {
    global _mongo_clients;

    # Resolve URI (silently skip if config not found)
    try {
        resolved_uri = _resolve_uri(uri, DatabaseType.MONGODB);
        if resolved_uri in _mongo_clients {
            _mongo_clients[resolved_uri].close();
            del _mongo_clients[resolved_uri];
        }
    } except ValueError { }
}

"""Close a specific Redis client connection.

    Args:
        uri: Redis connection URL. If None, closes default connection.
    """
def close_redis_client(uri: (str | None) = None) -> None {
    global _redis_clients;

    # Resolve URI (silently skip if config not found)
    try {
        resolved_uri = _resolve_uri(uri, DatabaseType.REDIS);
        if resolved_uri in _redis_clients {
            _redis_clients[resolved_uri].close();
            del _redis_clients[resolved_uri];
        }
    } except ValueError { }
}

"""Close all database connections (MongoDB and Redis).

    Useful for cleanup during application shutdown.
    """
def close_all_db_connections -> None {
    global _mongo_clients,_redis_clients;

    # Close all MongoDB clients
    for client in _mongo_clients.values() {
        try {
            client.close();
        } except Exception { }
    }
    _mongo_clients.clear();

    # Close all Redis clients
    for client in _redis_clients.values() {
        try {
            client.close();
        } except Exception { }
    }
    _redis_clients.clear();
}

obj Db {
    has client: (MongoClient | Redis),
        db_name: str = 'jac_db',
        db_type: DatabaseType = DatabaseType.MONGODB;

    def find_one(col_name: str, filter: dict) -> dict | None;
    def find(col_name: str, filter: dict) -> Cursor | list;
    def insert_one(col_name: str, document: dict) -> PyMongoInsertOneResult | InsertResult;
    def update_one(
        col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False
    ) -> PyMongoUpdateResult | UpdateResult;
    def delete_one(col_name: str, filter: dict) -> PyMongoDeleteResult | DeleteResult;

    # Bulk operations
    def insert_many(col_name: str, documents: list) -> PyMongoInsertManyResult | InsertManyResult;
    def update_many(
        col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False
    ) -> PyMongoUpdateResult | UpdateResult;

    # ID-based convenience methods
    def find_by_id(col_name: str, id: str) -> dict | None;
    def update_by_id(
        col_name: str, id: str, update_data: dict, upsert_mode: bool = False
    ) -> PyMongoUpdateResult | UpdateResult;
    def delete_by_id(col_name: str, id: str) -> PyMongoDeleteResult | DeleteResult;
}
