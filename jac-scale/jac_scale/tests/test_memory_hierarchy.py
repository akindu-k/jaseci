import os
import tempfile
import pytest
from unittest.mock import Mock, patch, MagicMock
from uuid import uuid4, UUID
from dataclasses import dataclass, field
import redis
import shutil
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure

from jac_scale.memory_hierarchy import (
    MultiHierarchyMemory,
    RedisDB,
    MongoDB,
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
    


class TestShelfDB:
    def setup_method(self):
        self.temp_dir = tempfile.mkdtemp()
        self.shelf_path = os.path.join(self.temp_dir, "test_shelf.db")
        self.shelf_db = ShelfDB(shelf_path=self.shelf_path)
        
    def teardown_method(self):
        try:
            self.shelf_db.close()
        except:
            pass
        shutil.rmtree(self.temp_dir, ignore_errors=True)
    
    def test_shelf_initialization(self):
        """Test ShelfDB initialization."""
        assert self.shelf_db.shelf_path == self.shelf_path
        assert self.shelf_db._shelf is not None
        
    def test_set_and_find_anchor(self):
        """Test setting and finding an anchor."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id, data="test_anchor")
        
        self.shelf_db.set(anchor)
        
        found_anchor = self.shelf_db.find_by_id(anchor_id)
        assert found_anchor is not None
        assert found_anchor.id == anchor_id
        assert found_anchor.data == "test_anchor"
        
    def test_remove_anchor(self):
        """Test removing an anchor."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.shelf_db.set(anchor)
        assert self.shelf_db.find_by_id(anchor_id) is not None
        
        self.shelf_db.remove(anchor)
        assert self.shelf_db.find_by_id(anchor_id) is None
        
    def test_commit_single_anchor(self):
        """Test committing a single anchor."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.shelf_db.commit(anchor=anchor)
        found_anchor = self.shelf_db.find_by_id(anchor_id)
        assert found_anchor is not None
        assert found_anchor.id == anchor_id
        
    def test_commit_multiple_anchors(self):
        """Test committing multiple anchors."""
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        
        self.shelf_db.commit(keys=anchors)
        
        for anchor in anchors:
            found_anchor = self.shelf_db.find_by_id(anchor.id)
            assert found_anchor is not None
            assert found_anchor.id == anchor.id
            
class TestRedisDB:
    def setup_method(self):
        self.mock_redis = Mock(spec=redis.Redis)
        self.redis_db = RedisDB()
        self.redis_db.redis_client = self.mock_redis
        
    def test_redis_initialization(self):
        """Test RedisDB initialization."""
        assert self.redis_db.redis_url is not None
        assert self.redis_db.redis_client is not None
        
    def test_redis_is_available_success(self):
        """Test redis availability check when connection succeeds."""
        self.mock_redis.ping.return_value = True
        assert self.redis_db.redis_is_available() is True
        
    def test_redis_is_available_failure(self):
        """Test redis availability check when connection fails."""
        self.mock_redis.ping.side_effect = Exception("Connection failed")
        assert self.redis_db.redis_is_available() is False
    
    def test_redis_is_available_none_client(self):
        """Test redis availability when client is None."""
        self.redis_db.redis_client = None
        assert self.redis_db.redis_is_available() is False

    @patch('jac_scale.memory_hierarchy.dumps')
    def test_set_anchor(self, mock_dumps):
        """Test setting an anchor in Redis."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        mock_dumps.return_value = b"serialized_anchor"
        
        self.redis_db.set(anchor)
        
        expected_key = f"anchor:{str(anchor_id)}"
        self.mock_redis.set.assert_called_once_with(expected_key, b"serialized_anchor")
        
    def test_remove_anchor(self):
        """Test removing an anchor from Redis."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.redis_db.remove(anchor)
        
        expected_key = f"anchor:{str(anchor_id)}"
        self.mock_redis.delete.assert_called_once_with(expected_key)
        
    @patch('jac_scale.memory_hierarchy.loads')
    def test_find_by_id_success(self, mock_loads):
        """Test finding an anchor by ID successfully."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.mock_redis.get.return_value = b"serialized_anchor"
        mock_loads.return_value = anchor
        
        result = self.redis_db.find_by_id(anchor_id)
        
        expected_key = f"anchor:{str(anchor_id)}"
        self.mock_redis.get.assert_called_once_with(expected_key)
        assert result == anchor
        
    def test_find_by_id_not_found(self):
        """Test finding an anchor by ID when not found."""
        anchor_id = uuid4()
        self.mock_redis.get.return_value = None
        
        result = self.redis_db.find_by_id(anchor_id)
        assert result is None
        
    def test_commit_single_anchor(self):
        """Test committing a single anchor."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        with patch.object(self.redis_db, 'set') as mock_set:
            self.redis_db.commit(anchor=anchor)
            mock_set.assert_called_once_with(anchor)
            
    def test_commit_multiple_anchors(self):
        """Test committing multiple anchors."""
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        
        with patch.object(self.redis_db, 'set') as mock_set:
            self.redis_db.commit(keys=anchors)
            assert mock_set.call_count == 3
            

class TestMongoDB:
    def setup_method(self):
        """Setup for each test method."""
        self.mock_collection = Mock()
        
        self.mock_db = Mock()
        self.mock_db.__getitem__ = Mock(return_value=self.mock_collection)
        
        self.mock_client = Mock()
        self.mock_client.__getitem__ = Mock(return_value=self.mock_db)
        
        with patch('jac_scale.memory_hierarchy.MongoClient') as mock_client_class:
            mock_client_class.return_value = self.mock_client
            self.mongo_db = MongoDB()
            
        self.mongo_db.client = self.mock_client
        self.mongo_db.db = self.mock_db
        self.mongo_db.collection = self.mock_collection

    def test_mongo_initialization(self):
        """Test MongoDB initialization."""
        assert self.mongo_db.client is not None
        assert self.mongo_db.db_name == 'jac_db'
        assert self.mongo_db.collection_name == 'anchors'
        
    @patch('jac_scale.memory_hierarchy.MongoClient')
    def test_mongo_is_available_success(self, mock_mongo_client):
        """Test mongo availability check when connection succeeds."""
        mock_client = Mock()
        mock_mongo_client.return_value = mock_client
        mock_client.admin.command.return_value = True
        
        result = self.mongo_db.mongo_is_available()
        assert result is True
        mock_client.close.assert_called_once()
        
    @patch('jac_scale.memory_hierarchy.MongoClient')
    def test_mongo_is_available_failure(self, mock_mongo_client):
        """Test mongo availability check when connection fails."""
        mock_mongo_client.side_effect = ConnectionFailure("Connection failed")
        
        result = self.mongo_db.mongo_is_available()
        assert result is False
        
    @patch('jac_scale.memory_hierarchy.dumps')
    def test_set_anchor(self, mock_dumps):
        """Test setting an anchor in MongoDB."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        mock_dumps.return_value = b"serialized_anchor"
        
        self.mock_collection.find_one.return_value = None
        
        self.mongo_db.set(anchor)
        
        self.mock_collection.update_one.assert_called_once()
        call_args = self.mock_collection.update_one.call_args
        assert call_args[0][0] == {'_id': str(anchor_id)}
        assert call_args[1]['upsert'] is True
        
    def test_remove_anchor(self):
        """Test removing an anchor from MongoDB."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.mongo_db.remove(anchor)
        
        self.mock_collection.delete_one.assert_called_once_with({'_id': str(anchor_id)})
        
    @patch('jac_scale.memory_hierarchy.loads')
    def test_find_by_id_success(self, mock_loads):
        """Test finding an anchor by ID successfully."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.mock_collection.find_one.return_value = {'data': b"serialized_anchor"}
        mock_loads.return_value = anchor
        
        result = self.mongo_db.find_by_id(anchor_id)
        
        self.mock_collection.find_one.assert_called_once_with({'_id': str(anchor_id)})
        assert result == anchor
        
    def test_find_by_id_not_found(self):
        """Test finding an anchor by ID when not found."""
        anchor_id = uuid4()
        self.mock_collection.find_one.return_value = None
        
        result = self.mongo_db.find_by_id(anchor_id)
        assert result is None
    
    def test_commit_single_anchor(self):
        """Test committing a single anchor."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        with patch.object(self.mongo_db, 'set') as mock_set:
            self.mongo_db.commit(anchor=anchor)
            mock_set.assert_called_once_with(anchor)
            
    def test_commit_bulk_anchors(self):
        """Test bulk committing anchors."""
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        
        with patch.object(self.mongo_db, 'commit_bulk') as mock_bulk:
            self.mongo_db.commit(keys=anchors)
            mock_bulk.assert_called_once_with(anchors)
            

class TestMultiHierarchyMemory:
    def setup_method(self):
        """Setup for each test method."""
        self.mock_memory = MagicMock()
        self.mock_redis = Mock()
        self.mock_mongo = Mock()
        self.mock_shelf = Mock()
        
        with patch('jac_scale.memory_hierarchy.Memory') as mock_mem_class:
            mock_mem_class.return_value = self.mock_memory
            with patch('jac_scale.memory_hierarchy.RedisDB') as mock_redis_class:
                mock_redis_class.return_value = self.mock_redis
                with patch('jac_scale.memory_hierarchy.MongoDB') as mock_mongo_class:
                    mock_mongo_class.return_value = self.mock_mongo
                    
                    self.multi_memory = MultiHierarchyMemory()
    
    def test_initialization_with_all_available(self):
        """Test initialization when all storage systems are available."""
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        
        self.mock_redis.redis_is_available.return_value = True
        self.mock_mongo.mongo_is_available.return_value = True
        
        self.multi_memory.__post_init__()
        
        assert self.multi_memory.shelf is None
        
    def test_initialization_with_none_available(self):
        """Test initialization when no external storage is available."""
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        
        with patch('jac_scale.memory_hierarchy.ShelfDB') as mock_shelf_class:
            mock_shelf_class.return_value = self.mock_shelf            
            self.multi_memory.__post_init__()
            
        assert self.multi_memory.shelf == self.mock_shelf
    
    def test_initialization_with_redis_only(self):
        """Test initialization when only Redis is available."""
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = False
        
        self.mock_redis.redis_is_available.return_value = True
        self.mock_mongo.mongo_is_available.return_value = False
        
        self.multi_memory.__post_init__()
        
        assert self.multi_memory.shelf is None
    
    def test_initialization_with_mongo_only(self):
        """Test initialization when only MongoDB is available."""
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = True
        
        self.mock_redis.redis_is_available.return_value = False
        self.mock_mongo.mongo_is_available.return_value = True
        
        self.multi_memory.__post_init__()
        
        assert self.multi_memory.shelf is None
    
    def test_find_by_id_in_memory(self):
        """Test finding anchor in local memory first."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = anchor
        
        result = self.multi_memory.find_by_id(anchor_id)
        
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        
    def test_find_by_id_in_redis(self):
        """Test finding anchor in Redis if not in local memory."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        
        self.mock_redis.find_by_id.return_value = anchor
        
        result = self.multi_memory.find_by_id(anchor_id)
        
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.mock_redis.find_by_id.assert_called_once_with(anchor_id)
    
    def test_find_by_id_in_mongo(self):
        """Test finding anchor in MongoDB if not in local memory or Redis."""
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
    
    def test_find_by_id_in_shelf(self):
        """Test finding anchor in ShelfDB if not in local memory, Redis, or MongoDB."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        
        self.mock_redis.find_by_id.return_value = None
        self.mock_mongo.find_by_id.return_value = None
        
        self.multi_memory.shelf = MagicMock()
        self.multi_memory.shelf.find_by_id.return_value = anchor
        
        result = self.multi_memory.find_by_id(anchor_id)
        
        assert result == anchor
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.mock_redis.find_by_id.assert_called_once_with(anchor_id)
        self.mock_mongo.find_by_id.assert_called_once_with(anchor_id)
        self.multi_memory.shelf.find_by_id.assert_called_once_with(anchor_id)
        
    def test_find_by_id_not_found(self):
        """Test finding anchor when not found in any storage."""
        anchor_id = uuid4()
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.find_by_id.return_value = None
        
        self.mock_redis.find_by_id.return_value = None
        self.mock_mongo.find_by_id.return_value = None
        self.multi_memory.shelf = MagicMock()
        self.multi_memory.shelf.find_by_id.return_value = None
        
        result = self.multi_memory.find_by_id(anchor_id)
        
        assert result is None
        self.multi_memory.mem.find_by_id.assert_called_once_with(anchor_id)
        self.mock_redis.find_by_id.assert_called_once_with(anchor_id)
        self.mock_mongo.find_by_id.assert_called_once_with(anchor_id)
        self.multi_memory.shelf.find_by_id.assert_called_once_with(anchor_id)
    
    def test_set_anchor(self):
        """Test setting an anchor only stores in local memory initially."""
        anchor_id = uuid4()
        anchor = MockAnchor(id=anchor_id)
        
        self.multi_memory.mem = MagicMock()
        
        self.multi_memory.set(anchor)
        
        self.multi_memory.mem.set.assert_called_once_with(anchor)
    
    def test_commit_single_anchor_in_gc(self):
        """Test committing a single anchor that's marked for garbage collection."""
        anchor = MockAnchor(id=uuid4())
        gc_set = {anchor}
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_set
        
        with patch.object(self.multi_memory, 'delete') as mock_delete:
            self.multi_memory.commit(anchor)
            mock_delete.assert_called_once_with(anchor)
            self.multi_memory.mem.remove_from_gc.assert_called_once_with(anchor)
    
    def test_commit_single_anchor_not_in_gc_redis_mongo_available(self):
        """Test committing a single anchor to Redis and MongoDB when both available."""
        anchor = MockAnchor(id=uuid4())
        gc_set = set()
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_set
        
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        
        self.multi_memory.commit(anchor)
        
        self.mock_redis.set.assert_called_once_with(anchor)
        self.mock_mongo.set.assert_called_once_with(anchor)
    
    def test_commit_single_anchor_not_in_gc_shelf_only(self):
        """Test committing a single anchor to shelf when Redis/Mongo unavailable."""
        anchor = MockAnchor(id=uuid4())
        gc_set = set()
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_set
        
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = self.mock_shelf
        
        self.multi_memory.commit(anchor)
        
        self.mock_shelf.set.assert_called_once_with(anchor)

    def test_commit_all_anchors(self):
        """Test committing without specifying anchor (commits all)."""
        gc_anchors = {MockAnchor(id=uuid4())}
        memory_anchors = {uuid4(): MockAnchor(id=uuid4()) for _ in range(3)}
        
        self.multi_memory.mem = MagicMock()
        self.multi_memory.mem.get_gc.return_value = gc_anchors
        self.multi_memory.mem.get_mem.return_value = memory_anchors
        
        with patch.object(self.multi_memory, 'delete') as mock_delete:
            with patch.object(self.multi_memory, 'sync') as mock_sync:
                self.multi_memory.commit()
                
                for anchor in gc_anchors:
                    mock_delete.assert_any_call(anchor)
                    self.multi_memory.mem.remove_from_gc.assert_any_call(anchor)
                
                expected_anchors = set(memory_anchors.values())
                mock_sync.assert_called_once_with(expected_anchors)
                
    def test_sync_with_redis_and_mongo(self):
        """Test syncing anchors to available storage."""
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        
        self.multi_memory.sync(anchors)
        
        self.mock_redis.commit.assert_called_once_with(keys=anchors)
        self.mock_mongo.commit.assert_called_once_with(keys=anchors)
        
    def test_sync_with_shelf_only(self):
        """Test syncing anchors when only shelf is available."""
        anchors = [MockAnchor(id=uuid4()) for _ in range(3)]
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = self.mock_shelf
        
        self.multi_memory.sync(anchors)
        
        self.mock_shelf.commit.assert_called_once_with(keys=anchors)
        
    def test_delete_anchor_with_redis_and_mongo(self):
        """Test deleting an anchor from all storage layers when both available."""
        anchor = MockAnchor(id=uuid4())
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        
        self.multi_memory.mem = MagicMock()
        
        self.multi_memory.delete(anchor)
        
        self.multi_memory.mem.remove.assert_called_once_with(anchor.id)
        self.mock_redis.remove.assert_called_once_with(anchor)
        self.mock_mongo.remove.assert_called_once_with(anchor)

    def test_delete_anchor_with_shelf(self):
        """Test deleting an anchor when using shelf storage."""
        anchor = MockAnchor(id=uuid4())
        self.multi_memory.redis_available = False
        self.multi_memory.mongo_available = False
        self.multi_memory.shelf = self.mock_shelf
        
        self.multi_memory.mem = MagicMock()
        
        self.multi_memory.delete(anchor)
        
        self.multi_memory.mem.remove.assert_called_once_with(anchor.id)
        self.mock_shelf.remove.assert_called_once_with(anchor)
        
    def test_close_with_all_storage(self):
        """Test closing the memory hierarchy with all storage systems."""
        self.multi_memory.redis_available = True
        self.multi_memory.mongo_available = True
        self.multi_memory.shelf = self.mock_shelf
        
        self.mock_redis.redis_client = Mock()
        self.mock_mongo.client = Mock()
        self.multi_memory.mem = MagicMock()
        
        with patch.object(self.multi_memory, 'commit') as mock_commit:
            self.multi_memory.close()
            
            mock_commit.assert_called_once()
            self.multi_memory.mem.close.assert_called_once()
            self.mock_redis.redis_client.close.assert_called_once()
            self.mock_mongo.client.close.assert_called_once()
            self.mock_shelf.close.assert_called_once()
        

if __name__ == "__main__":
    pytest.main([__file__])



