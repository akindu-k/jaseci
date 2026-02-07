"""Public API for jac-scale library functions.

This module provides user-facing APIs for direct database access and other utilities.
"""
import from jac_scale.db { Db, get_mongo_client, get_redis_client }
import from jac_scale.factories.database_factory { DatabaseType }

"""Create a key-value store instance for direct database operations.

    Provides a unified interface for MongoDB and Redis operations without
    the graph abstraction layer. Useful for caching, session storage, and
    direct document manipulation.

    Args:
        db_name: Name of the database to use. Defaults to 'jac_db'.
        db_type: Type of database ('mongodb' or 'redis'). Defaults to 'mongodb'.
        uri: Optional database connection URI. If not provided, uses configuration
             from environment variables or jac.toml.

    Returns:
        Db instance configured for the specified database.

    Raises:
        ValueError: If db_type is invalid or URI cannot be resolved from config.

    Example:
        ```jac
        import from jac_scale.lib { kvstore }

        # MongoDB for persistent data
        mongo_db = kvstore(db_name='my_app', db_type='mongodb');
        mongo_db.insert_one('users', {'name': 'Alice', 'role': 'admin'});

        # Redis for caching
        redis_cache = kvstore(db_name='cache', db_type='redis');
        redis_cache.insert_one('sessions', {'user_id': '123', 'token': 'abc'});

        # Custom URI
        custom_db = kvstore(
            db_name='analytics',
            db_type='mongodb',
            uri='mongodb://analytics-server:27017'
        );
        ```
    """
def kvstore(
    db_name: str = 'jac_db',
    db_type: str = 'mongodb',
    uri: (str | None) = None
) -> Db {
    # Convert string to DatabaseType enum
    db_type_enum = DatabaseType(db_type);

    # Get appropriate client based on database type
    if db_type_enum == DatabaseType.MONGODB {
        client = get_mongo_client(uri=uri);
    } elif db_type_enum == DatabaseType.REDIS {
        client = get_redis_client(uri=uri);
    } else {
        raise ValueError(f'Unsupported database type: {db_type}');
    }

    return Db(client=client, db_name=db_name, db_type=db_type_enum);
}
