"""Public API for jac-scale library functions.

This module provides user-facing APIs for direct database access and other utilities.
"""
import from jac_scale.db { Db, get_mongo_client, get_redis_client }
import from jac_scale.factories.database_factory { DatabaseType }

"""Create a key-value store instance for direct database operations.

    Provides access to MongoDB (document database) and Redis (key-value store)
    without the graph abstraction layer. Each database type exposes methods
    appropriate to its semantics.

    Args:
        db_name: Name of the database to use. Defaults to 'jac_db'.
        db_type: Type of database ('mongodb' or 'redis'). Defaults to 'mongodb'.
        uri: Optional database connection URI. If not provided, uses configuration
             from environment variables or jac.toml.

    Returns:
        Db instance configured for the specified database.

    Raises:
        ValueError: If db_type is invalid or URI cannot be resolved from config.

    Common Methods (work for both):
        - get(key, col_name): Get a value by key
        - set(key, value, col_name): Set a value by key
        - delete(key, col_name): Delete a value by key
        - exists(key, col_name): Check if key exists

    MongoDB-Only Methods:
        - find_one(col_name, filter): Query documents with filters
        - find(col_name, filter): Find multiple documents
        - insert_one(col_name, doc): Insert a document
        - update_one/update_many: Update with MongoDB operators
        - delete_many: Delete multiple documents

    Redis-Only Methods:
        - set_with_ttl(key, value, ttl): Set with expiration
        - incr(key): Atomic increment
        - expire(key, seconds): Set TTL on existing key
        - scan_keys(pattern): Find keys matching pattern

    Example - MongoDB for Document Queries:
        ```jac
        import from jac_scale.lib { kvstore }

        mongo_db = kvstore(db_name='my_app', db_type='mongodb');

        # Document operations with filters
        mongo_db.insert_one('users', {'name': 'Alice', 'role': 'admin'});
        user = mongo_db.find_one('users', {'name': 'Alice'});

        # Or use simple key-value API
        mongo_db.set('user:123', {'name': 'Bob'}, 'users');
        user = mongo_db.get('user:123', 'users');
        ```

    Example - Redis for Caching:
        ```jac
        import from jac_scale.lib { kvstore }

        redis_cache = kvstore(db_name='cache', db_type='redis');

        # Simple key-value operations
        redis_cache.set('session:abc', {'user_id': '123', 'token': 'xyz'});
        session = redis_cache.get('session:abc');

        # Redis-specific features
        redis_cache.set_with_ttl('temp:token', {'value': 'xyz'}, ttl=3600);
        redis_cache.incr('page:views');

        # Find keys by pattern
        all_sessions = redis_cache.scan_keys('session:*');
        ```

    Example - Custom URI:
        ```jac
        custom_db = kvstore(
            db_name='analytics',
            db_type='mongodb',
            uri='mongodb://analytics-server:27017'
        );
        ```
    """
def kvstore(
    db_name: str = 'jac_db', db_type: str = 'mongodb', uri: (str | None) = None
) -> Db {
    # Convert string to DatabaseType enum
    db_type_enum = DatabaseType(db_type);

    # Get appropriate client based on database type
    if db_type_enum == DatabaseType.MONGODB {
        client = get_mongo_client(uri=uri);
    } elif db_type_enum == DatabaseType.REDIS {
        client = get_redis_client(uri=uri);
    } else {
        raise ValueError(f'Unsupported database type: {db_type}') ;
    }

    return Db(client=client, db_name=db_name, db_type=db_type_enum);
}
