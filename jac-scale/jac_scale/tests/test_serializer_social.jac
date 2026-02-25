"""Test serialization and persistence of social graph nodes."""
import contextlib;
import os;
import from jaclang.runtimelib.serializer { Serializer }
import from jac_scale.tests.fixtures.social_graph { User, Post, BuildGraph, QueryGraph }
import from jac_scale.lib { kvstore }
import from jac_scale.db { close_all_db_connections }
import from jac_scale.config_loader { reset_scale_config }
import from testcontainers.mongodb { MongoDbContainer }
import from uuid { UUID, uuid4 }
import from jaclang.jac0core.archetype { NodeAnchor, EdgeAnchor }

def cleanup_connections {
    with contextlib.suppress(Exception) {
        close_all_db_connections();
    }
}

glob _mongo_container = MongoDbContainer("mongo:7.0"),
     MONGO_URI: str = "";

with entry {
    _mongo_container.start();
}

glob MONGO_URI = _mongo_container.get_connection_url();

# Set environment variable so ScaleTieredMemory uses the testcontainer's MongoDB
with entry {
    os.environ['MONGODB_URI'] = MONGO_URI;
    reset_scale_config();  # Reset config cache to pick up the new env var
}

test "serialize user node" {
    u = User(name="Alice", role="admin", age=30);
    serialized = Serializer.serialize(u, include_type=True);
    deserialized = Serializer.deserialize(serialized);
    assert deserialized.name == "Alice"
    and deserialized.role == "admin"
    and deserialized.age == 30;
    assert type(deserialized) == User;
}

test "serialize post node" {
    p = Post(title="Hello", content="World");
    serialized = Serializer.serialize(p, include_type=True);
    deserialized = Serializer.deserialize(serialized);
    assert deserialized.title == "Hello" and deserialized.content == "World";
    assert type(deserialized) == Post;
}

test "find_nodes queries persisted graph with BuildGraph" {
    # Clean up any leftover connections from previous tests
    cleanup_connections();

    db = kvstore(db_name='jac_db', db_type='mongodb', uri=MONGO_URI);

    # Drop collection to ensure clean state before test
    db._get_mongo_collection('_anchors').drop();

    graph = BuildGraph() spawn root;

    # Query using the QueryGraph walker
    result = QueryGraph(mongo_uri=MONGO_URI) spawn root;
    report_data = result.reports[0];

    young = report_data['young'];
    admins = report_data['admins'];
    posts = report_data['posts'];

    # Verify counts and data
    assert len(young) == 1 and young[0].name == 'Bob' and young[0].age == 25;
    assert len(admins) == 1 and admins[0].name == 'Alice' and admins[0].role == 'admin';
    assert len(posts) == 3;

    # Cleanup
    db._get_mongo_collection('_anchors').drop();
    cleanup_connections();
}

"""Test _id_to_stub creates proper unpopulated stubs."""
test "id_to_stub creates proper stubs" {
    print("Testing _id_to_stub...");

    # Test NodeAnchor stub creation
    node_id = uuid4();
    node_stub = Serializer._id_to_stub(NodeAnchor, str(node_id));
    assert node_stub is not None , "NodeAnchor stub should not be None";
    assert node_stub.id == node_id , f"ID mismatch: {node_stub.id} != {node_id}";
    assert not node_stub.is_populated() , "Stub should not be populated";

    # Test EdgeAnchor stub creation
    edge_id = uuid4();
    edge_stub = Serializer._id_to_stub(EdgeAnchor, str(edge_id));
    assert edge_stub is not None , "EdgeAnchor stub should not be None";
    assert edge_stub.id == edge_id , f"ID mismatch: {edge_stub.id} != {edge_id}";
    assert not edge_stub.is_populated() , "Stub should not be populated";

    # Test invalid UUID string
    invalid_stub = Serializer._id_to_stub(NodeAnchor, "not-a-uuid");
    assert invalid_stub is None , "Invalid UUID should return None";
}

"""Test that NodeAnchor edges are properly restored from serialized data."""
test "NodeAnchor edges restoration" {
    print("Testing NodeAnchor edges restoration...");

    # Create test data with edges
    edge_ids = [uuid4(), uuid4(), uuid4()];
    data = {
        '__type__': 'NodeAnchor',
        'id': str(uuid4()),
        'root': str(uuid4()),
        'persistent': True,
        'edges': [str(eid) for eid in edge_ids]
    };

    # Deserialize
    anchor = Serializer._deserialize_anchor(data);

    assert anchor is not None , "Deserialized anchor should not be None";
    assert isinstance(anchor, NodeAnchor) , "Should be NodeAnchor";
    assert len(anchor.edges) == 3 , f"Should have 3 edges, got {len(anchor.edges)}";

    # Verify each edge is a proper stub
    i = 0;
    for edge in anchor.edges {
        assert edge is not None , f"Edge {i} should not be None";
        assert isinstance(edge, EdgeAnchor) , f"Edge {i} should be EdgeAnchor";
        assert edge.id == edge_ids[i] , f"Edge {i} ID mismatch";
        assert not edge.is_populated() , f"Edge {i} should not be populated (lazy load)";
        i += 1;
    }
}

"""Test that EdgeAnchor source/target are properly restored from serialized data."""
test "EdgeAnchor source/target restoration" {
    print("Testing EdgeAnchor source/target restoration...");

    # Create test data with source and target
    source_id = uuid4();
    target_id = uuid4();
    data = {
        '__type__': 'EdgeAnchor',
        'id': str(uuid4()),
        'root': str(uuid4()),
        'persistent': True,
        'source': str(source_id),
        'target': str(target_id),
        'is_undirected': False
    };

    # Deserialize
    anchor = Serializer._deserialize_anchor(data);

    assert anchor is not None , "Deserialized anchor should not be None";
    assert isinstance(anchor, EdgeAnchor) , "Should be EdgeAnchor";
    assert anchor.source is not None , "Source should not be None";
    assert anchor.target is not None , "Target should not be None";

    # Verify source and target are proper stubs
    assert isinstance(anchor.source, NodeAnchor) , "Source should be NodeAnchor";
    assert anchor.source.id == source_id , f"Source ID mismatch";
    assert not anchor.source.is_populated() , "Source should not be populated (lazy load)";

    assert isinstance(anchor.target, NodeAnchor) , "Target should be NodeAnchor";
    assert anchor.target.id == target_id , f"Target ID mismatch";
    assert not anchor.target.is_populated() , "Target should not be populated (lazy load)";
}

"""Test that NodeAnchor with no edges works correctly."""
test "NodeAnchor with empty edges" {
    print("Testing NodeAnchor with empty edges...");

    data = {
        '__type__': 'NodeAnchor',
        'id': str(uuid4()),
        'root': str(uuid4()),
        'persistent': True
    };

    anchor = Serializer._deserialize_anchor(data);

    assert anchor is not None , "Deserialized anchor should not be None";
    assert isinstance(anchor, NodeAnchor) , "Should be NodeAnchor";
    assert anchor.edges == [] , f"Should have empty edges list, got {anchor.edges}";
}

"""Test that EdgeAnchor with null source/target handles gracefully."""
test "EdgeAnchor with null source/target" {
    print("Testing EdgeAnchor with null source/target...");

    data = {
        '__type__': 'EdgeAnchor',
        'id': str(uuid4()),
        'root': str(uuid4()),
        'persistent': True,
        'source': None,
        'target': None,
        'is_undirected': False
    };

    anchor = Serializer._deserialize_anchor(data);

    assert anchor is not None , "Deserialized anchor should not be None";
    assert isinstance(anchor, EdgeAnchor) , "Should be EdgeAnchor";
}
