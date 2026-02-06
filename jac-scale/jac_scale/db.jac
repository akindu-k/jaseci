"""Direct Database Access Module."""
import from pymongo { MongoClient }
import from redis { Redis }
import from typing { Any }
import from jac_scale.factories.database_factory {
    DatabaseProviderFactory,
    DatabaseType
}
import from bson { ObjectId }

glob _mongo_clients: dict[str, MongoClient] = {},
     _redis_clients: dict[str, Redis] = {};

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
    import from jac_scale.config_loader { get_scale_config }

    # Get default URI if not provided
    if uri is None {
        scale_config = get_scale_config();
        db_config = scale_config.get_database_config();
        uri = db_config.get('mongodb_uri');
        if uri is None {
            raise ValueError('MongoDB URI not found in configuration') ;
        }
    }

    # Return existing client or create new one
    if uri not in _mongo_clients {
        _mongo_clients[uri] = DatabaseProviderFactory.create_client(
            DatabaseType.MONGODB, uri=uri
        );
    }

    return _mongo_clients[uri];
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
    import from jac_scale.config_loader { get_scale_config }

    # Get default URI if not provided
    if uri is None {
        scale_config = get_scale_config();
        db_config = scale_config.get_database_config();
        uri = db_config.get('redis_url');
        if uri is None {
            raise ValueError('Redis URL not found in configuration') ;
        }
    }

    # Return existing client or create new one
    if uri not in _redis_clients {
        _redis_clients[uri] = DatabaseProviderFactory.create_client(
            DatabaseType.REDIS, uri=uri
        );
    }

    return _redis_clients[uri];
}

"""Close a specific MongoDB client connection.

    Args:
        uri: MongoDB connection URI. If None, closes default connection.
    """
def close_mongo_client(uri: (str | None) = None) -> None {
    global _mongo_clients;
    import from jac_scale.config_loader { get_scale_config }

    if uri is None {
        scale_config = get_scale_config();
        db_config = scale_config.get_database_config();
        uri = db_config.get('mongodb_uri');
    }

    if uri and uri in _mongo_clients {
        _mongo_clients[uri].close();
        del _mongo_clients[uri];
    }
}

"""Close a specific Redis client connection.

    Args:
        uri: Redis connection URL. If None, closes default connection.
    """
def close_redis_client(uri: (str | None) = None) -> None {
    global _redis_clients;
    import from jac_scale.config_loader { get_scale_config }

    if uri is None {
        scale_config = get_scale_config();
        db_config = scale_config.get_database_config();
        uri = db_config.get('redis_url');
    }

    if uri and uri in _redis_clients {
        _redis_clients[uri].close();
        del _redis_clients[uri];
    }
}

"""Close all database connections (MongoDB and Redis).

    Useful for cleanup during application shutdown.
    """
def close_all_db_connections() -> None {
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
    def find(col_name: str, filter: dict) -> Any;
    def insert_one(col_name: str, document: dict) -> Any;
    def update_one(
        col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False
    ) -> Any;

    def delete_one(col_name: str, filter: dict) -> Any;
    # Bulk operations
    def insert_many(col_name: str, documents: list) -> Any;
    def update_many(
        col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False
    ) -> Any;

    # ID-based convenience methods
    def find_by_id(col_name: str, id: str) -> dict | None;
    def update_by_id(
        col_name: str, id: str, update_data: dict, upsert_mode: bool = False
    ) -> Any;

    def delete_by_id(col_name: str, id: str) -> Any;
}
