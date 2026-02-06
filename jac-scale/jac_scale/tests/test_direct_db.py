"""Production-grade tests for direct database operations.

Tests cover:
1. Core CRUD operations (MongoDB & Redis)
2. Connection pooling and reuse
3. Configuration fallback mechanism
4. Error handling and edge cases
"""

import os
import pytest
from testcontainers.mongodb import MongoDbContainer
from testcontainers.redis import RedisContainer
from jaclang.pycore.runtime import JacRuntime as Jac


@pytest.fixture(scope="session")
def mongodb_container():
    """Provide a MongoDB test container for the session."""
    with MongoDbContainer("mongo:7.0") as container:
        yield container


@pytest.fixture(scope="session")
def redis_container():
    """Provide a Redis test container for the session."""
    with RedisContainer("redis:7.2-alpine") as container:
        yield container


@pytest.fixture
def mongo_uri(mongodb_container):
    """Get MongoDB connection URI from container."""
    return mongodb_container.get_connection_url()


@pytest.fixture
def redis_uri(redis_container):
    """Get Redis connection URI from container."""
    host = redis_container.get_container_host_ip()
    port = redis_container.get_exposed_port(6379)
    return f"redis://{host}:{port}/0"


@pytest.fixture(autouse=True)
def cleanup_connections():
    """Clean up all database connections after each test."""
    yield
    # Cleanup after test
    try:
        from jac_scale.db import close_all_db_connections
        close_all_db_connections()
    except Exception:
        pass


class TestMongoDBOperations:
    """Test core MongoDB CRUD operations."""

    def test_insert_and_find_one(self, mongo_uri):
        """Test basic insert and find operations."""
        # Call via Jac runtime (as users would)
        db_instance = Jac.db(
            db_name="test_db",
            db_type="mongodb",
            uri=mongo_uri
        )

        # Insert a document
        doc = {"name": "Alice", "age": 30, "role": "engineer"}
        result = db_instance.insert_one("users", doc)

        assert result.inserted_id is not None

        # Find the document
        found = db_instance.find_by_id("users", str(result.inserted_id))
        assert found is not None
        assert found["name"] == "Alice"
        assert found["age"] == 30

    def test_update_and_delete(self, mongo_uri):
        """Test update and delete operations."""
        db_instance = Jac.db(
            db_name="test_db",
            db_type="mongodb",
            uri=mongo_uri
        )

        # Insert
        doc = {"name": "Bob", "status": "active"}
        result = db_instance.insert_one("users", doc)
        doc_id = str(result.inserted_id)

        # Update
        update_result = db_instance.update_by_id(
            "users",
            doc_id,
            {"$set": {"status": "inactive"}}
        )
        assert update_result.modified_count == 1

        # Verify update
        found = db_instance.find_by_id("users", doc_id)
        assert found["status"] == "inactive"

        # Delete
        delete_result = db_instance.delete_by_id("users", doc_id)
        assert delete_result.deleted_count == 1

        # Verify deletion
        found = db_instance.find_by_id("users", doc_id)
        assert found is None

    def test_bulk_operations(self, mongo_uri):
        """Test bulk insert and update operations."""
        db_instance = Jac.db(
            db_name="test_db",
            db_type="mongodb",
            uri=mongo_uri
        )

        # Bulk insert
        docs = [
            {"name": "User1", "score": 100},
            {"name": "User2", "score": 200},
            {"name": "User3", "score": 300}
        ]
        result = db_instance.insert_many("scores", docs)
        assert len(result.inserted_ids) == 3

        # Bulk update
        update_result = db_instance.update_many(
            "scores",
            {"score": {"$gte": 200}},
            {"$set": {"tier": "gold"}}
        )
        assert update_result.modified_count == 2


class TestRedisOperations:
    """Test core Redis operations."""

    def test_redis_insert_and_find(self, redis_uri):
        """Test Redis insert and find operations."""
        db_instance = Jac.db(
            db_name="cache",
            db_type="redis",
            uri=redis_uri
        )

        # Insert
        doc = {"session_id": "abc123", "user": "alice"}
        result = db_instance.insert_one("sessions", doc)
        assert result.inserted_id is not None

        # Find by ID
        found = db_instance.find_by_id("sessions", result.inserted_id)
        assert found is not None
        assert found["session_id"] == "abc123"
        assert found["user"] == "alice"

    def test_redis_update_and_delete(self, redis_uri):
        """Test Redis update and delete operations."""
        db_instance = Jac.db(
            db_name="cache",
            db_type="redis",
            uri=redis_uri
        )

        # Insert
        doc = {"key": "value1"}
        result = db_instance.insert_one("data", doc)
        doc_id = result.inserted_id

        # Update
        update_result = db_instance.update_by_id(
            "data",
            doc_id,
            {"key": "value2"}
        )
        assert update_result.modified_count == 1

        # Verify
        found = db_instance.find_by_id("data", doc_id)
        assert found["key"] == "value2"

        # Delete
        delete_result = db_instance.delete_by_id("data", doc_id)
        assert delete_result.deleted_count == 1


class TestConnectionPooling:
    """Test connection pooling and reuse."""

    def test_same_uri_reuses_connection(self, mongo_uri):
        """Verify same URI reuses the same connection."""
        db1 = Jac.db(db_name="db1", db_type="mongodb", uri=mongo_uri)
        db2 = Jac.db(db_name="db2", db_type="mongodb", uri=mongo_uri)

        # Same URI should reuse the same client
        assert db1.client is db2.client

    def test_different_uri_creates_new_connection(self, mongo_uri, redis_uri):
        """Verify different URIs create different connections."""
        mongo_db = Jac.db(db_name="mongo", db_type="mongodb", uri=mongo_uri)
        redis_db = Jac.db(db_name="redis", db_type="redis", uri=redis_uri)

        # Different databases should have different clients
        assert mongo_db.client is not redis_db.client

    def test_multiple_mongodb_uris(self, mongodb_container):
        """Test multiple MongoDB URIs create separate connections."""
        uri1 = mongodb_container.get_connection_url()
        # Simulate different URI by adding query parameter
        uri2 = uri1 + "?retryWrites=true" if "?" not in uri1 else uri1 + "&maxPoolSize=50"

        db1 = Jac.db(db_name="db1", db_type="mongodb", uri=uri1)
        db2 = Jac.db(db_name="db2", db_type="mongodb", uri=uri1)  # Same URI
        db3 = Jac.db(db_name="db3", db_type="mongodb", uri=uri2)  # Different URI

        # db1 and db2 should share client
        assert db1.client is db2.client

        # db3 should have different client (different URI)
        assert db1.client is not db3.client


class TestConfigurationFallback:
    """Test configuration fallback mechanism."""

    def test_explicit_uri_overrides_config(self, mongo_uri):
        """Verify explicit URI parameter takes precedence."""
        # Set environment variable
        os.environ["MONGODB_URI"] = "mongodb://fake:27017"

        try:
            # Explicit URI should be used, not env var
            db_instance = Jac.db(
                db_name="test",
                db_type="mongodb",
                uri=mongo_uri  # Explicit URI
            )

            # Should successfully connect with explicit URI
            result = db_instance.insert_one("test", {"test": "data"})
            assert result.inserted_id is not None
        finally:
            del os.environ["MONGODB_URI"]

    def test_env_var_fallback(self, mongo_uri):
        """Verify environment variable is used when URI not provided."""
        os.environ["MONGODB_URI"] = mongo_uri

        try:
            # No URI provided, should use env var
            db_instance = Jac.db(db_name="test", db_type="mongodb")

            # Should connect successfully
            result = db_instance.insert_one("test", {"test": "data"})
            assert result.inserted_id is not None
        finally:
            del os.environ["MONGODB_URI"]

    def test_missing_config_raises_error(self):
        """Verify missing configuration raises ValueError."""
        # Ensure no config is set
        os.environ.pop("MONGODB_URI", None)
        os.environ.pop("REDIS_URL", None)

        with pytest.raises(ValueError, match="MongoDB URI not found"):
            Jac.db(db_name="test", db_type="mongodb")  # No URI, no config


class TestErrorHandling:
    """Test error handling and edge cases."""

    def test_invalid_db_type(self, mongo_uri):
        """Verify invalid database type raises error."""
        with pytest.raises(ValueError, match="is not a valid DatabaseType"):
            Jac.db(db_name="test", db_type="invalid_db", uri=mongo_uri)

    def test_invalid_mongodb_id(self, mongo_uri):
        """Verify invalid MongoDB ObjectId raises InvalidId exception."""
        from bson.errors import InvalidId

        db_instance = Jac.db(db_name="test", db_type="mongodb", uri=mongo_uri)

        # Invalid ObjectId should raise InvalidId exception
        with pytest.raises(InvalidId):
            db_instance.find_by_id("users", "invalid_id")

    def test_delete_nonexistent_document(self, mongo_uri):
        """Verify deleting non-existent document doesn't crash."""
        db_instance = Jac.db(db_name="test", db_type="mongodb", uri=mongo_uri)

        # Should return deleted_count = 0, not crash
        result = db_instance.delete_one("users", {"_id": "nonexistent"})
        assert result.deleted_count == 0

    def test_connection_cleanup(self, mongo_uri):
        """Verify connections can be cleaned up."""
        from jac_scale.db import close_all_db_connections

        # Create connections
        db1 = Jac.db(db_name="db1", db_type="mongodb", uri=mongo_uri)
        db1.insert_one("test", {"data": "test"})

        # Cleanup should not raise errors
        close_all_db_connections()

        # Creating new connection after cleanup should work
        db2 = Jac.db(db_name="db2", db_type="mongodb", uri=mongo_uri)
        result = db2.insert_one("test", {"data": "test2"})
        assert result.inserted_id is not None


class TestDatabaseIsolation:
    """Test database name isolation."""

    def test_different_db_names_are_isolated(self, mongo_uri):
        """Verify different database names maintain isolation."""
        db1 = Jac.db(db_name="db_one", db_type="mongodb", uri=mongo_uri)
        db2 = Jac.db(db_name="db_two", db_type="mongodb", uri=mongo_uri)

        # Insert into db1
        doc1 = {"name": "test1"}
        result1 = db1.insert_one("collection", doc1)

        # Insert into db2
        doc2 = {"name": "test2"}
        result2 = db2.insert_one("collection", doc2)

        # Verify isolation - db1 shouldn't see db2's data
        found1 = db1.find_by_id("collection", str(result1.inserted_id))
        assert found1 is not None
        assert found1["name"] == "test1"

        # db1 shouldn't have db2's document
        found2_in_db1 = db1.find_by_id("collection", str(result2.inserted_id))
        assert found2_in_db1 is None


# Integration test for real-world usage pattern
class TestRealWorldUsage:
    """Test realistic usage patterns."""

    def test_user_session_workflow(self, mongo_uri, redis_uri):
        """Simulate a real user session workflow."""
        # MongoDB for persistent data
        user_db = Jac.db(db_name="app", db_type="mongodb", uri=mongo_uri)

        # Redis for session cache
        cache_db = Jac.db(db_name="app", db_type="redis", uri=redis_uri)

        # 1. Create user in MongoDB
        user = {"email": "user@example.com", "name": "Test User"}
        user_result = user_db.insert_one("users", user)
        user_id = str(user_result.inserted_id)

        # 2. Create session in Redis
        session = {"user_id": user_id, "token": "abc123", "expires": "2024-12-31"}
        session_result = cache_db.insert_one("sessions", session)
        session_id = session_result.inserted_id

        # 3. Retrieve session from Redis
        cached_session = cache_db.find_by_id("sessions", session_id)
        assert cached_session is not None
        assert cached_session["user_id"] == user_id

        # 4. Update user in MongoDB
        user_db.update_by_id("users", user_id, {"$set": {"status": "active"}})

        # 5. Verify update
        updated_user = user_db.find_by_id("users", user_id)
        assert updated_user["status"] == "active"

        # 6. Cleanup
        cache_db.delete_by_id("sessions", session_id)
        user_db.delete_by_id("users", user_id)
