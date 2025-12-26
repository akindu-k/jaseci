import contextlib
import os
import pickle
import shutil
import tempfile
import time
from dataclasses import dataclass, field
from typing import Any
from unittest.mock import MagicMock, Mock, patch
from uuid import UUID, uuid4

import docker
import pytest
import redis
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure

from jac_scale.config_loader import reset_scale_config
from jac_scale.config_loader import get_scale_config

from jac_scale.config_loader import reset_scale_config
from jac_scale.memory_hierarchy import (
    MongoDB,
    MultiHierarchyMemory,
    RedisDB,
    ShelfDB,
)


@dataclass(frozen=True)
class MockAnchor:
    """mock anchor for testing"""

    id: UUID
    data: str = "test_data"
    archetype: tuple = field(default_factory=tuple)
    access: tuple = field(default_factory=tuple)
    edges: tuple = field(default_factory=tuple)
    persistent: bool = True
    hash: int = field(default=1)


class TestShelfDB:
    def setup_method(self) -> None:
        self.temp_dir = tempfile.mkdtemp()
        self.shelf_path = os.path.join(self.temp_dir, "test_shelf.db")
        self.shelf_db = ShelfDB(shelf_path=self.shelf_path)

    def teardown_method(self) -> None:
        with contextlib.suppress(BaseException):
            self.shelf_db.close()
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_shelf_initialization(self) -> None:
        assert self.shelf_db.shelf_path == self.shelf_path
        assert self.shelf_db._shelf is not None

    def test_set_and_find_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id, data="test_anchor")
        self.shelf_db.set(anchor)
        found_anchor = self.shelf_db.find_by_id(anchor_id)
        assert found_anchor is not None
        assert found_anchor.id == anchor_id
        assert found_anchor.data == "test_anchor"

    def test_remove_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.shelf_db.set(anchor)
        assert self.shelf_db.find_by_id(anchor_id) is not None
        self.shelf_db.remove(anchor)
        assert self.shelf_db.find_by_id(anchor_id) is None

    def test_commit_single_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.shelf_db.commit(anchor=anchor)
        found_anchor = self.shelf_db.find_by_id(anchor_id)
        assert found_anchor is not None
        assert found_anchor.id == anchor_id

    def test_commit_multiple_anchors(self) -> None:
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        self.shelf_db.commit(keys=anchors)
        for anchor in anchors:
            found_anchor = self.shelf_db.find_by_id(anchor.id)
            assert found_anchor is not None
            assert found_anchor.id == anchor.id


class TestRedisDB:
    def setup_method(self) -> None:
        self.mock_redis = Mock(spec=redis.Redis)
        self.redis_db = RedisDB()
        self.redis_db.redis_client = self.mock_redis

    def test_redis_initialization(self) -> None:
        assert self.redis_db.redis_url is not None
        assert self.redis_db.redis_client is not None

    def test_redis_is_available_success(self) -> None:
        self.mock_redis.ping.return_value = True
        assert self.redis_db.redis_is_available() is True

    def test_redis_is_available_failure(self) -> None:
        self.mock_redis.ping.side_effect = Exception("Connection failed")
        assert self.redis_db.redis_is_available() is False

    def test_redis_is_available_none_client(self) -> None:
        self.redis_db.redis_client = None
        assert self.redis_db.redis_is_available() is False

    @patch("jac_scale.memory_hierarchy.dumps")
    def test_set_anchor(self, mock_dumps: Mock) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        mock_dumps.return_value = b"serialized_anchor"
        self.redis_db.set(anchor)
        expected_key = f"anchor:{str(anchor_id)}"
        self.mock_redis.set.assert_called_once_with(expected_key, b"serialized_anchor")

    def test_remove_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.redis_db.remove(anchor)
        expected_key = f"anchor:{str(anchor_id)}"
        self.mock_redis.delete.assert_called_once_with(expected_key)

    @patch("jac_scale.memory_hierarchy.loads")
    def test_find_by_id_success(self, mock_loads: Mock) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.mock_redis.get.return_value = b"serialized_anchor"
        mock_loads.return_value = anchor
        result = self.redis_db.find_by_id(anchor_id)
        expected_key = f"anchor:{str(anchor_id)}"
        self.mock_redis.get.assert_called_once_with(expected_key)
        assert result == anchor

    def test_find_by_id_not_found(self) -> None:
        anchor_id = uuid4()
        self.mock_redis.get.return_value = None
        result = self.redis_db.find_by_id(anchor_id)
        assert result is None

    def test_commit_single_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        with patch.object(self.redis_db, "set") as mock_set:
            self.redis_db.commit(anchor=anchor)
            mock_set.assert_called_once_with(anchor)

    def test_commit_multiple_anchors(self) -> None:
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        with patch.object(self.redis_db, "set") as mock_set:
            self.redis_db.commit(keys=anchors)
            assert mock_set.call_count == 3


class TestMongoDB:
    def setup_method(self) -> None:
        self.mock_collection = Mock()
        self.mock_db = Mock()
        self.mock_db.__getitem__ = Mock(return_value=self.mock_collection)
        self.mock_client = Mock()
        self.mock_client.__getitem__ = Mock(return_value=self.mock_db)
        with patch("jac_scale.memory_hierarchy.MongoClient") as mock_client_class:
            mock_client_class.return_value = self.mock_client
            self.mongo_db = MongoDB()
        self.mongo_db.client = self.mock_client
        self.mongo_db.db = self.mock_db
        self.mongo_db.collection = self.mock_collection

    def test_mongo_initialization(self) -> None:
        assert self.mongo_db.client is not None
        assert self.mongo_db.db_name == "jac_db"
        assert self.mongo_db.collection_name == "anchors"

    @patch("jac_scale.memory_hierarchy.MongoClient")
    def test_mongo_is_available_success(self, mock_mongo_client: Mock) -> None:
        mock_client = Mock()
        mock_mongo_client.return_value = mock_client
        mock_client.admin.command.return_value = True
        self.mongo_db.mongo_url = "mongodb://localhost:27017"
        result = self.mongo_db.mongo_is_available()
        assert result is True

    @patch("jac_scale.memory_hierarchy.MongoClient")
    def test_mongo_is_available_failure(self, mock_mongo_client: Mock) -> None:
        mock_mongo_client.side_effect = ConnectionFailure("Connection failed")
        result = self.mongo_db.mongo_is_available()
        assert result is False

    @patch("jac_scale.memory_hierarchy.dumps")
    def test_set_anchor(self, mock_dumps: Mock) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        mock_dumps.return_value = b"serialized_anchor"
        self.mock_collection.find_one.return_value = None
        self.mongo_db.set(anchor)
        self.mock_collection.update_one.assert_called_once()
        call_args = self.mock_collection.update_one.call_args
        assert call_args[0][0] == {"_id": str(anchor_id)}
        assert call_args[1]["upsert"] is True

    def test_remove_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.mongo_db.remove(anchor)
        self.mock_collection.delete_one.assert_called_once_with({"_id": str(anchor_id)})

    @patch("jac_scale.memory_hierarchy.loads")
    def test_find_by_id_success(self, mock_loads: Mock) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.mock_collection.find_one.return_value = {"data": b"serialized_anchor"}
        mock_loads.return_value = anchor
        result = self.mongo_db.find_by_id(anchor_id)
        self.mock_collection.find_one.assert_called_once_with({"_id": str(anchor_id)})
        assert result == anchor

    def test_find_by_id_not_found(self) -> None:
        anchor_id = uuid4()
        self.mock_collection.find_one.return_value = None
        result = self.mongo_db.find_by_id(anchor_id)
        assert result is None

    def test_commit_single_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        with patch.object(self.mongo_db, "set") as mock_set:
            self.mongo_db.commit(anchor=anchor)
            mock_set.assert_called_once_with(anchor)

    def test_commit_bulk_anchors(self) -> None:
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        with patch.object(self.mongo_db, "commit_bulk") as mock_bulk:
            self.mongo_db.commit(keys=anchors)
            mock_bulk.assert_called_once_with(anchors)


class TestMultiHierarchyMemory:
    def setup_method(self) -> None:
        self.mock_memory = MagicMock()
        self.mock_redis = Mock()
        self.mock_mongo = Mock()
        self.mock_shelf = Mock()
        with patch("jac_scale.memory_hierarchy.Memory") as mock_mem_class:
            mock_mem_class.return_value = self.mock_memory
            with patch("jac_scale.memory_hierarchy.RedisDB") as mock_redis_class:
                mock_redis_class.return_value = self.mock_redis
                with patch("jac_scale.memory_hierarchy.MongoDB") as mock_mongo_class:
                    mock_mongo_class.return_value = self.mock_mongo
                    self.multi_memory = MultiHierarchyMemory()

    def test_initialization_with_all_available(self) -> None:
        self.mock_redis.redis_is_available.return_value = True
        self.mock_mongo.mongo_is_available.return_value = True
        with patch("jac_scale.memory_hierarchy.Memory") as mock_mem_class:
            mock_mem_class.return_value = self.mock_memory
            with patch("jac_scale.memory_hierarchy.RedisDB") as mock_redis_class:
                mock_redis_class.return_value = self.mock_redis
                with patch("jac_scale.memory_hierarchy.MongoDB") as mock_mongo_class:
                    mock_mongo_class.return_value = self.mock_mongo
                    test_memory = MultiHierarchyMemory()
        assert test_memory.shelf is None
        assert test_memory.redis_available is True
        assert test_memory.mongo_available is True

    def test_initialization_with_none_available(self) -> None:
        self.mock_redis.redis_is_available.return_value = False
        self.mock_mongo.mongo_is_available.return_value = False
        with patch("jac_scale.memory_hierarchy.Memory") as mock_mem_class:
            mock_mem_class.return_value = self.mock_memory
            with patch("jac_scale.memory_hierarchy.RedisDB") as mock_redis_class:
                mock_redis_class.return_value = self.mock_redis
                with patch("jac_scale.memory_hierarchy.MongoDB") as mock_mongo_class:
                    mock_mongo_class.return_value = self.mock_mongo
                    with patch(
                        "jac_scale.memory_hierarchy.ShelfDB"
                    ) as mock_shelf_class:
                        mock_shelf_class.return_value = self.mock_shelf
                        test_memory = MultiHierarchyMemory()
        assert test_memory.shelf == self.mock_shelf
        assert test_memory.redis_available is False
        assert test_memory.mongo_available is False

    def test_initialization_with_redis_only(self) -> None:
        self.mock_redis.redis_is_available.return_value = True
        self.mock_mongo.mongo_is_available.return_value = False
        with patch("jac_scale.memory_hierarchy.Memory") as mock_mem_class:
            mock_mem_class.return_value = self.mock_memory
            with patch("jac_scale.memory_hierarchy.RedisDB") as mock_redis_class:
                mock_redis_class.return_value = self.mock_redis
                with patch("jac_scale.memory_hierarchy.MongoDB") as mock_mongo_class:
                    mock_mongo_class.return_value = self.mock_mongo
                    test_memory = MultiHierarchyMemory()
        assert test_memory.shelf is None
        assert test_memory.redis_available is True
        assert test_memory.mongo_available is False

    def test_initialization_with_mongo_only(self) -> None:
        self.mock_redis.redis_is_available.return_value = False
        self.mock_mongo.mongo_is_available.return_value = True
        with patch("jac_scale.memory_hierarchy.Memory") as mock_mem_class:
            mock_mem_class.return_value = self.mock_memory
            with patch("jac_scale.memory_hierarchy.RedisDB") as mock_redis_class:
                mock_redis_class.return_value = self.mock_redis
                with patch("jac_scale.memory_hierarchy.MongoDB") as mock_mongo_class:
                    mock_mongo_class.return_value = self.mock_mongo
                    test_memory = MultiHierarchyMemory()
        assert test_memory.shelf is None
        assert test_memory.redis_available is False
        assert test_memory.mongo_available is True

    def test_find_by_id_in_memory(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = anchor
        result = self.multi_memory.find_by_id(anchor_id)
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)

    def test_find_by_id_in_redis(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        self.mock_redis.find_by_id.return_value = anchor
        result = self.multi_memory.find_by_id(anchor_id)
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.mock_redis.find_by_id.assert_called_once_with(anchor_id)

    def test_find_by_id_in_mongo(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        self.mock_redis.find_by_id.return_value = None
        self.mock_mongo.find_by_id.return_value = anchor
        result = self.multi_memory.find_by_id(anchor_id)
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.mock_redis.find_by_id.assert_called_once_with(anchor_id)
        self.mock_mongo.find_by_id.assert_called_once_with(anchor_id)

    def test_find_by_id_in_shelf(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = MagicMock()
        self.multi_memory.shelf.find_by_id.return_value = anchor
        self.mock_redis.find_by_id.return_value = None
        result = self.multi_memory.find_by_id(anchor_id)
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.multi_memory.shelf.find_by_id.assert_called_once_with(anchor_id)

    def test_find_by_id_not_found(self) -> None:
        anchor_id = uuid4()
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        self.mock_redis.find_by_id.return_value = None
        self.mock_mongo.find_by_id.return_value = None
        result = self.multi_memory.find_by_id(anchor_id)
        assert result is None
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.mock_redis.find_by_id.assert_called_once_with(anchor_id)
        self.mock_mongo.find_by_id.assert_called_once_with(anchor_id)

    def test_set_anchor(self) -> None:
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        self.multi_memory.mem = MagicMock()
        self.multi_memory.set(anchor)
        self.multi_memory.mem.set.assert_called_once_with(anchor)

    def test_commit_single_anchor_in_gc(self) -> None:
        anchor = MockAnchor(id=uuid4())
        gc_set: set[MockAnchor] = {anchor}
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_set
        with patch.object(self.multi_memory, "delete") as mock_delete:
            self.multi_memory.commit(anchor)
            mock_delete.assert_called_once_with(anchor)
            self.multi_memory.mem.remove_from_gc.assert_called_once_with(anchor)

    def test_commit_single_anchor_not_in_gc_redis_mongo_available(self) -> None:
        anchor = MockAnchor(id=uuid4())
        gc_set: set[MockAnchor] = set()
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_set
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        self.multi_memory.commit(anchor)
        self.mock_redis.set.assert_called_once_with(anchor)
        self.mock_mongo.set.assert_called_once_with(anchor)

    def test_commit_single_anchor_not_in_gc_shelf_only(self) -> None:
        anchor = MockAnchor(id=uuid4())
        gc_set: set[MockAnchor] = set()
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_set
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = self.mock_shelf
        self.multi_memory.commit(anchor)
        self.mock_shelf.set.assert_called_once_with(anchor)

    def test_commit_all_anchors(self) -> None:
        gc_anchors = {MockAnchor(id=uuid4())}
        memory_anchors = {uuid4(): MockAnchor(id=uuid4()) for _ in range(3)}
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_anchors
        self.multi_memory.mem.get_mem.return_value = memory_anchors
        with (
            patch.object(self.multi_memory, "delete") as mock_delete,
            patch.object(self.multi_memory, "sync") as mock_sync,
        ):
            self.multi_memory.commit()
            for anchor in gc_anchors:
                mock_delete.assert_any_call(anchor)
                self.multi_memory.mem.remove_from_gc.assert_any_call(anchor)
            expected_anchors = set(memory_anchors.values())
            mock_sync.assert_called_once_with(expected_anchors)

    def test_sync_with_redis_and_mongo(self) -> None:
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        self.multi_memory.sync(anchors)
        self.mock_redis.commit.assert_called_once_with(keys=anchors)
        self.mock_mongo.commit.assert_called_once_with(keys=anchors)

    def test_sync_with_shelf_only(self) -> None:
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = self.mock_shelf
        self.multi_memory.sync(anchors)
        self.mock_shelf.commit.assert_called_once_with(keys=anchors)

    def test_delete_anchor_with_redis_and_mongo(self) -> None:
        anchor = MockAnchor(id=uuid4())
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        self.multi_memory.mem = MagicMock()
        self.multi_memory.delete(anchor)
        self.multi_memory.mem.remove.assert_called_once_with(anchor.id)
        self.mock_redis.remove.assert_called_once_with(anchor)
        self.mock_mongo.remove.assert_called_once_with(anchor)

    def test_delete_anchor_with_shelf(self) -> None:
        anchor = MockAnchor(id=uuid4())
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = self.mock_shelf
        self.multi_memory.mem = MagicMock()
        self.multi_memory.delete(anchor)
        self.multi_memory.mem.remove.assert_called_once_with(anchor.id)
        self.mock_shelf.remove.assert_called_once_with(anchor)

    def test_close(self) -> None:
        self.multi_memory.mem = MagicMock()
        with patch.object(self.multi_memory, "commit") as mock_commit:
            self.multi_memory.close()
            mock_commit.assert_called_once()
            self.multi_memory.mem.close.assert_called_once()


# INTEGRATION WORKFLOW TESTS


@pytest.fixture(scope="module")
def real_containers():
    """
    Spins up Docker containers for Redis and MongoDB using docker-py directly.
    Uses _db_config for configuration consistency.
    Scope='module' means they run once for all tests in this file.
    """
        
    client = docker.from_env()
    
    # Get default config for container settings
    config = get_scale_config()
    db_config = config.get_database_config()

    try:
        # Start Redis container
        redis_container = client.containers.run(
            "redis:latest", ports={"6379/tcp": None}, detach=True, remove=True
        )

        redis_container.reload()
        redis_port = redis_container.ports["6379/tcp"][0]["HostPort"]
        redis_host = "localhost"
        redis_url = f"redis://{redis_host}:{redis_port}/0"

        redis_client = redis.Redis(host=redis_host, port=int(redis_port))
        for _ in range(30):  # Wait up to 30 seconds
            try:
                redis_client.ping()
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("Redis container did not start in time")

        # Start MongoDB container
        mongo_container = client.containers.run(
            "mongo:latest", ports={"27017/tcp": None}, detach=True, remove=True
        )

        mongo_container.reload()
        mongo_port = mongo_container.ports["27017/tcp"][0]["HostPort"]
        mongo_host = "localhost"
        mongo_url = f"mongodb://{mongo_host}:{mongo_port}"

        for _ in range(30):  # Wait up to 30 seconds
            try:
                mongo_client = MongoClient(mongo_url, serverSelectionTimeoutMS=1000)
                mongo_client.admin.command("ping")
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("MongoDB container did not start in time")

        # Create updated config that uses the real container URLs
        updated_db_config = {
            'redis_url': redis_url,
            'mongodb_uri': mongo_url,
            'shelf_db_path': db_config.get('shelf_db_path', '/tmp/test_shelf.db')
        }

        yield {
            "redis_url": redis_url,
            "mongo_url": mongo_url,
            "redis_client": redis_client,
            "mongo_client": mongo_client,
            "db_config": updated_db_config,  # Include the config for patching
        }

    finally:
        # Cleanup containers
        with contextlib.suppress(Exception):
            redis_container.stop()
        with contextlib.suppress(Exception):
            mongo_container.stop()


class TestIntegrationWorkflow:
    @pytest.fixture(autouse=True)
    def setup_env(
        self, monkeypatch: pytest.MonkeyPatch, real_containers: dict[str, Any]
    ) -> None:
        # Reset the config instance first
        reset_scale_config()

        # Patch the _db_config at the module level where it's imported
        mock_db_config = {
            "mongodb_uri": real_containers["mongo_url"],
            "redis_url": real_containers["redis_url"],
            "shelf_db_path": "/tmp/test_shelf.db",
        }

        # Patch the global _db_config in the memory_hierarchy module
        with patch("jac_scale.memory_hierarchy._db_config", mock_db_config):
            self.verify_redis = real_containers["redis_client"]
            self.verify_mongo = real_containers["mongo_client"]

            self.verify_redis.flushall()
            self.verify_mongo.drop_database("jac_db")

            # Create the memory instance inside the patch context
            self.memory = MultiHierarchyMemory()

            self.memory.mem = MagicMock()
            self.l1_store: dict[UUID, MockAnchor] = {}  # to simulate RAM

            def mock_set(anchor: MockAnchor) -> None:
                self.l1_store[anchor.id] = anchor

            def mock_get(anchor_id: UUID) -> MockAnchor | None:
                return self.l1_store.get(anchor_id)

            def mock_remove(anchor_id: UUID) -> None:
                self.l1_store.pop(anchor_id, None)

            self.memory.mem.set.side_effect = mock_set
            self.memory.mem.find_by_id.side_effect = mock_get
            self.memory.mem.remove.side_effect = mock_remove
            self.memory.mem.get_gc.return_value = set()  # nothing in Garbage collector
            self.memory.mem.get_mem.return_value = self.l1_store

            # Store the patched config for use in tests
            self._db_config_patch = mock_db_config

    def teardown_method(self) -> None:
        if hasattr(self, "memory"):
            self.memory.close()

    def test_commit_workflow(self):
        # Re-apply the patch for this test method
        with patch("jac_scale.memory_hierarchy._db_config", self._db_config_patch):
            anchor_id = uuid4()
            anchor = MockAnchor(id=anchor_id, data="This is test data")

            self.memory.commit(anchor)

            # checking redis
            redis_key = f"anchor:{anchor_id}"
            assert self.verify_redis.exists(redis_key), "Data is not in Redis"

            # checking mongo
            mongo_document = self.verify_mongo["jac_db"]["anchors"].find_one(
                {"_id": str(anchor_id)}
            )
            assert mongo_document is not None, "Data is not in MongoDB"

            # deserializing data and checking the content
            data = pickle.loads(mongo_document["data"])
            assert data.data == "This is test data", (
                "Data content is not matching in MongoDB"
            )

    def test_l3_hit(self):
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id, data="L3 Hit Data")

        # storing directly in MongoDB
        serialized_data = pickle.dumps(anchor)
        self.verify_mongo["jac_db"]["anchors"].insert_one(
            {"_id": str(anchor_id), "data": serialized_data, "type": "MockAnchor"}
        )

        # check L1 miss
        assert not self.verify_redis.exists(f"anchor:{anchor_id}")

        # requesting using the memory hierarchy
        result = self.memory.find_by_id(anchor_id)

        assert result is not None
        assert result.data == "L3 Hit Data"
        assert self.verify_redis.exists(f"anchor:{anchor_id}")

    def test_l2_hit(self):
        """sabotage strategy"""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id, data="Cached L2 Data")

        serialized_data = pickle.dumps(anchor)
        self.verify_mongo["jac_db"]["anchors"].insert_one(
            {"_id": str(anchor_id), "data": serialized_data, "type": "MockAnchor"}
        )

        first_retrieval = self.memory.find_by_id(
            anchor_id
        )  # fetch from mongo and write to L2
        assert first_retrieval.data == "Cached L2 Data"

        assert self.verify_redis.exists(f"anchor:{anchor_id}"), (
            "data did not get written to L2"
        )

        self.verify_mongo["jac_db"]["anchors"].delete_one(
            {"_id": str(anchor_id)}
        )  # remove from L3

        assert (
            self.verify_mongo["jac_db"]["anchors"].find_one({"_id": str(anchor_id)})
            is None
        )  # confirm removal

        if anchor_id in self.l1_store:
            self.l1_store.pop(anchor_id)  # remove from L1 cache

        second_retrieval = self.memory.find_by_id(anchor_id)  # should fetch from L2 now

        assert second_retrieval is not None, "Cache Miss"
        assert second_retrieval.data == "Cached L2 Data", (
            "Data mismatch on L2 retrieval"
        )

    def test_deletion(self):
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)

        self.memory.commit(anchor)
        assert self.verify_mongo["jac_db"]["anchors"].find_one({"_id": str(anchor_id)})

        self.memory.delete(anchor)

        assert anchor_id not in self.l1_store
        assert not self.verify_redis.exists(f"anchor:{anchor_id}")
        assert (
            self.verify_mongo["jac_db"]["anchors"].find_one({"_id": str(anchor_id)})
            is None
        )


if __name__ == "__main__":
    pytest.main([__file__])
