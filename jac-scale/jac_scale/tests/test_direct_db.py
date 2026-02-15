"""Integration tests for direct database operations using testcontainers."""

import contextlib
import io
import json
import os
import sys
from collections.abc import Generator
from pathlib import Path

import pytest
from testcontainers.mongodb import MongoDbContainer
from testcontainers.redis import RedisContainer

from jac_scale.db import close_all_db_connections
from jac_scale.lib import kvstore

_FIXTURES_DIR = Path(__file__).parent / "fixtures"
_SOCIAL_GRAPH_JAC = str(_FIXTURES_DIR / "social_graph.jac")


@pytest.fixture(scope="session")
def mongo_uri():
    with MongoDbContainer("mongo:7.0") as container:
        yield container.get_connection_url()


@pytest.fixture(scope="session")
def redis_uri():
    with RedisContainer("redis:7.2-alpine") as container:
        host = container.get_container_host_ip()
        port = container.get_exposed_port(6379)
        yield f"redis://{host}:{port}/0"


@pytest.fixture(autouse=True)
def cleanup() -> Generator[None, None, None]:
    yield
    with contextlib.suppress(Exception):
        close_all_db_connections()


# ===== MONGODB =====


def test_mongodb_crud(mongo_uri: str) -> None:
    """Test MongoDB insert, find, update, delete operations."""
    db = kvstore(db_name="test_db", db_type="mongodb", uri=mongo_uri)

    # Insert and find
    db.insert_one("users", {"name": "Alice", "role": "admin", "age": 30})
    db.insert_one("users", {"name": "Bob", "role": "user", "age": 25})
    assert db.find_one("users", {"name": "Alice"})["age"] == 30
    assert len(list(db.find("users", {"role": "admin"}))) == 1
    assert len(list(db.find("users", {"age": {"$gt": 20}}))) == 2

    # Update and delete by ID
    result = db.insert_one("users", {"name": "Charlie", "status": "active"})
    doc_id = str(result.inserted_id)
    db.update_by_id("users", doc_id, {"$set": {"status": "inactive"}})
    assert db.find_by_id("users", doc_id)["status"] == "inactive"
    db.delete_by_id("users", doc_id)
    assert db.find_by_id("users", doc_id) is None

    # Bulk operations
    db.insert_many("scores", [{"score": 100}, {"score": 200}, {"score": 300}])
    assert (
        db.update_many(
            "scores", {"score": {"$gte": 200}}, {"$set": {"tier": "gold"}}
        ).modified_count
        == 2
    )
    assert db.delete_many("scores", {"tier": "gold"}).deleted_count == 2


def test_mongodb_kv_api(mongo_uri: str) -> None:
    """Test MongoDB with common key-value methods."""
    db = kvstore(db_name="test_db", db_type="mongodb", uri=mongo_uri)

    assert db.set("user:123", {"name": "Dave"}, "sessions") == "user:123"
    assert db.get("user:123", "sessions")["name"] == "Dave"
    assert db.exists("user:123", "sessions") is True
    assert db.exists("nonexistent", "sessions") is False
    assert db.delete("user:123", "sessions") == 1
    assert db.get("user:123", "sessions") is None


def test_mongodb_rejects_redis_methods(mongo_uri: str) -> None:
    """Test MongoDB raises NotImplementedError for Redis-specific methods."""
    db = kvstore(db_name="test_db", db_type="mongodb", uri=mongo_uri)

    with pytest.raises(NotImplementedError):
        db.set_with_ttl("key", {"v": 1}, ttl=60)
    with pytest.raises(NotImplementedError):
        db.incr("counter")
    with pytest.raises(NotImplementedError):
        db.expire("key", 300)
    with pytest.raises(NotImplementedError):
        db.scan_keys("pattern:*")


# ===== REDIS =====


def test_redis_kv_operations(redis_uri: str) -> None:
    """Test Redis key-value, TTL, incr, expire, and scan_keys."""
    db = kvstore(db_name="cache", db_type="redis", uri=redis_uri)

    # Basic get/set/delete/exists
    assert db.set("session:abc", {"user_id": "42"}) == "session:abc"
    assert db.get("session:abc")["user_id"] == "42"
    assert db.exists("session:abc") is True
    assert db.delete("session:abc") == 1
    assert db.get("session:abc") is None

    # TTL and expire
    assert db.set_with_ttl("temp:token", {"v": "secret"}, ttl=3600) is True
    assert db.get("temp:token")["v"] == "secret"
    db.set("temp:data", {"v": "test"})
    assert db.expire("temp:data", 300) is True

    # Atomic increment
    assert db.incr("page:views") == 1
    assert db.incr("page:views") == 2
    assert db.incr("page:views") == 3

    # Pattern scan
    db.set("session:user1", {"id": "1"})
    db.set("session:user2", {"id": "2"})
    db.set("config:app", {"theme": "dark"})
    assert len(db.scan_keys("session:*")) == 2
    assert len(db.scan_keys("config:*")) == 1


def test_redis_rejects_mongodb_methods(redis_uri: str) -> None:
    """Test Redis raises NotImplementedError for MongoDB-specific methods."""
    db = kvstore(db_name="cache", db_type="redis", uri=redis_uri)

    with pytest.raises(NotImplementedError):
        db.find_one("users", {"name": "Alice"})
    with pytest.raises(NotImplementedError):
        db.find("users", {})
    with pytest.raises(NotImplementedError):
        db.insert_one("users", {"name": "Bob"})
    with pytest.raises(NotImplementedError):
        db.update_one("users", {"name": "Bob"}, {"$set": {"age": 30}})
    with pytest.raises(NotImplementedError):
        db.delete_many("users", {})


# ===== CONNECTION POOLING & CONFIG =====


def test_connection_pooling(mongo_uri: str, redis_uri: str) -> None:
    """Test same URI reuses connection, different URIs create separate ones."""
    db1 = kvstore(db_name="db1", db_type="mongodb", uri=mongo_uri)
    db2 = kvstore(db_name="db2", db_type="mongodb", uri=mongo_uri)
    assert db1.client is db2.client

    redis_db = kvstore(db_name="cache", db_type="redis", uri=redis_uri)
    assert db1.client is not redis_db.client


def test_config_fallback(mongo_uri: str) -> None:
    """Test URI resolution: explicit > env var > raises ValueError."""
    # Explicit URI overrides env var
    os.environ["MONGODB_URI"] = "mongodb://fake:27017"
    try:
        db = kvstore(db_name="test", db_type="mongodb", uri=mongo_uri)
        assert db.insert_one("test", {"data": "ok"}).inserted_id is not None
    finally:
        del os.environ["MONGODB_URI"]

    # Env var fallback
    os.environ["MONGODB_URI"] = mongo_uri
    try:
        db = kvstore(db_name="test", db_type="mongodb")
        assert db.insert_one("test", {"data": "ok"}).inserted_id is not None
    finally:
        del os.environ["MONGODB_URI"]

    # Missing config raises error
    os.environ.pop("MONGODB_URI", None)
    with pytest.raises(ValueError, match="MongoDB URI not found"):
        kvstore(db_name="test", db_type="mongodb")


def test_invalid_db_type(mongo_uri: str) -> None:
    """Test invalid db_type raises ValueError."""
    with pytest.raises(ValueError, match="is not a valid DatabaseType"):
        kvstore(db_name="test", db_type="invalid_db", uri=mongo_uri)


# ===== SOCIAL GRAPH / SERIALIZATION =====


def _run_jac_walker(
    filename: str, walker: str, *args: object
) -> list[dict[str, object]]:
    """Run a Jac walker via execution.enter and capture its report() output.

    Walker ``report`` statements are printed as JSON lines to stdout.
    Returns the list of reported dicts (one entry per ``report`` call).
    Non-JSON and non-dict lines are silently skipped.
    """
    from jaclang.cli.commands import execution  # type: ignore[attr-defined]

    buf = io.StringIO()
    old_stdout = sys.stdout
    sys.stdout = buf
    try:
        execution.enter(filename=filename, entrypoint=walker, args=list(args))
    finally:
        sys.stdout = old_stdout

    output = buf.getvalue().strip()
    if not output:
        return []
    reports: list[dict[str, object]] = []
    for line in output.splitlines():
        line = line.strip()
        if line:
            try:
                parsed = json.loads(line)
                if isinstance(parsed, dict):
                    reports.append(parsed)
            except json.JSONDecodeError:
                pass
    return reports


def test_social_graph_build_and_query_mongodb(mongo_uri: str, tmp_path: Path) -> None:
    """Run BuildGraph then QueryGraph walkers from social_graph.jac against a real MongoDB container and verify"""
    from jaclang import JacRuntime as Jac

    original_base = Jac.base_path_dir
    Jac.set_base_path(str(tmp_path))
    try:
        # ── Phase 1: BuildGraph walker ────────────────────────────────────────
        build_reports = _run_jac_walker(_SOCIAL_GRAPH_JAC, "BuildGraph", mongo_uri)

        assert len(build_reports) >= 1, "BuildGraph should report at least once"
        build_result = build_reports[0]
        assert build_result.get("users") == 2, "BuildGraph must report 2 users"
        assert build_result.get("posts") == 3, "BuildGraph must report 3 posts"

        # ── Phase 2: QueryGraph walker ────────────────────────────────────────
        query_reports = _run_jac_walker(_SOCIAL_GRAPH_JAC, "QueryGraph", mongo_uri)

        assert len(query_reports) >= 1, "QueryGraph should report at least once"
        result = query_reports[0]

        # alice: exact key lookup (db.get('Alice', 'users'))
        alice = result["alice"]
        assert alice is not None, "Alice must be retrievable from kvstore"
        assert alice["name"] == "Alice"
        assert alice["role"] == "admin"
        assert alice["age"] == 30, (
            "int field 'age' must survive the serialize/deserialize round-trip"
        )
        assert isinstance(alice["age"], int), "age must remain int, not str or float"

        # admins: filter query (db.find('users', {'role': 'admin'}))
        admins = result["admins"]
        assert len(admins) == 1
        assert admins[0]["name"] == "Alice"

        # young: range query (db.find('users', {'age': {'$lt': 28}}))
        young = result["young"]
        assert len(young) == 1
        assert young[0]["name"] == "Bob"
        assert young[0]["age"] == 25

        # posts: all-docs query (db.find('posts', {}))
        posts = result["posts"]
        assert len(posts) == 3
        titles = {p["title"] for p in posts}
        assert titles == {"Hello World", "Jac is cool", "Getting started"}
        # Verify string fields are intact after round-trip
        for post in posts:
            assert isinstance(post["title"], str)
            assert isinstance(post["content"], str)

        # ── Phase 3: direct kvstore verification after walkers ────────────────
        db = kvstore(db_name="social", db_type="mongodb", uri=mongo_uri)

        bob = db.get("Bob", "users")
        assert bob is not None
        assert bob["name"] == "Bob"
        assert bob["role"] == "user"
        assert bob["age"] == 25
        assert isinstance(bob["age"], int)

        p1 = db.get("Hello World", "posts")
        assert p1 is not None
        assert p1["content"] == "My first post"

        assert db.exists("Alice", "users") is True
        assert db.exists("Charlie", "users") is False

        # Update round-trip: overwrite a field and confirm persistence
        db.set("Bob", {"name": "Bob", "role": "user", "age": 26}, "users")
        assert db.get("Bob", "users")["age"] == 26

        # Delete round-trip
        assert db.delete("Hello World", "posts") == 1
        assert db.get("Hello World", "posts") is None
        assert len(list(db.find("posts", {}))) == 2
    finally:
        Jac.set_base_path(original_base)


# ===== REAL-WORLD PATTERN =====


def test_cache_aside_pattern(mongo_uri: str, redis_uri: str) -> None:
    """Test typical MongoDB (persistent) + Redis (cache) usage pattern."""
    mongo = kvstore(db_name="app", db_type="mongodb", uri=mongo_uri)
    cache = kvstore(db_name="cache", db_type="redis", uri=redis_uri)

    # Persist user in MongoDB, cache session in Redis
    user_id = str(
        mongo.insert_one(
            "users", {"email": "u@example.com", "name": "User"}
        ).inserted_id
    )
    cache.set_with_ttl(
        f"session:{user_id}", {"user_id": user_id, "token": "abc"}, ttl=3600
    )

    assert cache.get(f"session:{user_id}")["user_id"] == user_id
    assert mongo.find_one("users", {"email": "u@example.com"})["name"] == "User"

    mongo.update_by_id("users", user_id, {"$set": {"status": "active"}})
    cache.incr("stats:logins")

    # Cleanup
    cache.delete(f"session:{user_id}")
    mongo.delete_by_id("users", user_id)
    assert cache.get(f"session:{user_id}") is None
    assert mongo.find_by_id("users", user_id) is None
