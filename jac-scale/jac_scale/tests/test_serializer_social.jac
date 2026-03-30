"""Test serialization and persistence of social graph nodes."""
import contextlib;
import os;
import from jaclang.runtimelib.serializer { Serializer }
import from jac_scale.tests.fixtures.social_graph { User, Post, BuildGraph, QueryGraph }
import from jac_scale.lib { kvstore }
import from jac_scale.db { close_all_db_connections }
import from jac_scale.config_loader { reset_scale_config }
import from testcontainers.mongodb { MongoDbContainer }
import from uuid { uuid4 }
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

test "_id_to_stub creates valid stubs" {
    # NodeAnchor stub
    node_id = uuid4();
    node_stub = Serializer._id_to_stub(NodeAnchor, str(node_id));
    assert node_stub.id == node_id and not node_stub.is_populated();

    # EdgeAnchor stub
    edge_id = uuid4();
    edge_stub = Serializer._id_to_stub(EdgeAnchor, str(edge_id));
    assert edge_stub.id == edge_id and not edge_stub.is_populated();

    # Invalid UUID returns None
    assert Serializer._id_to_stub(NodeAnchor, "bad-uuid") is None;
}

test "NodeAnchor edges restored as lazy stubs" {
    edge_ids = [uuid4(), uuid4(), uuid4()];
    anchor = Serializer._deserialize_anchor(
        {
            '__type__': 'NodeAnchor',
            'id': str(uuid4()),
            'root': str(uuid4()),
            'edges': [str(e) for e in edge_ids]
        }
    );
    assert len(anchor.edges) == 3;
    for (i, edge) in enumerate(anchor.edges) {
        assert edge.id == edge_ids[i] and not edge.is_populated();
    }
}

test "EdgeAnchor source/target restored as lazy stubs" {
    src_id = uuid4();
    tgt_id = uuid4();
    anchor = Serializer._deserialize_anchor(
        {
            '__type__': 'EdgeAnchor',
            'id': str(uuid4()),
            'source': str(src_id),
            'target': str(tgt_id)
        }
    );
    assert anchor.source.id == src_id and not anchor.source.is_populated();
    assert anchor.target.id == tgt_id and not anchor.target.is_populated();
}

# =============================================================================
# Automatic $ref tests for nested Jac objects
# Fixture:
#   city  = City(name="Metropolis")          -- shared by alice and bob
#   alice = Person(name="Alice", city=city)  -- alice.friend = bob (circular)
#   bob   = Person(name="Bob",   city=city)  -- bob.friend = alice (circular)
# =============================================================================
obj City {
    has name: str;
}

obj Person {
    has name: str,
        city: City,
        friend: (Person | None) = None;
}

test "primitive-only object: no $ref emitted" {
    city = City(name="Gotham");
    data = Serializer.serialize(city);

    assert isinstance(data, dict);
    assert data["name"] == "Gotham";
    assert "$ref" not in str(data);
}

test "nested Jac object becomes $ref automatically" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);

    data = Serializer.serialize(alice);

    # alice is root → fully inlined
    assert data["name"] == "Alice";
    # alice.city is a Jac object → stored as $ref
    assert "$ref" in data["city"];
    assert data["city"]["$ref"] == jid(city);
}

test "shared city: both persons reference the same ID" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);

    data_alice = Serializer.serialize(alice);
    data_bob = Serializer.serialize(bob);

    # Both city refs point to the same ID
    assert "$ref" in data_alice["city"];
    assert "$ref" in data_bob["city"];
    assert data_alice["city"]["$ref"] == jid(city);
    assert data_bob["city"]["$ref"] == jid(city);
}

test "circular reference terminates — friend is $ref, no recursion" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);
    alice.friend = bob;
    bob.friend = alice;

    data = Serializer.serialize(alice);

    # alice root → inline
    assert data["name"] == "Alice";
    # alice.city → $ref (no recursion into city)
    assert "$ref" in data["city"];
    # alice.friend = bob → $ref immediately (no recursion into bob's fields)
    assert "$ref" in data["friend"];
    assert data["friend"]["$ref"] == jid(bob);
}

test "mutation is reflected in next serialization" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);

    city.name = "Gotham";
    # city is always referenced by ID, name change doesn't affect the $ref
    data = Serializer.serialize(alice);
    assert "$ref" in data["city"];
    assert data["city"]["$ref"] == jid(city);
}

test "mutating fields does not change object identity" {
    city = City(name="Metropolis");
    city_id = jid(city);

    city.name = "Gotham";
    assert jid(city) == city_id;

    city.name = "Star City";
    assert jid(city) == city_id;
}

test "reassigning friend to a different object is captured" {
    city = City(name="Metropolis");
    other = City(name="Gotham");
    alice = Person(name="Alice", city=city);
    carol = Person(name="Carol", city=other);

    alice.friend = carol;
    data = Serializer.serialize(alice);

    # alice.friend is now carol → $ref to carol
    assert "$ref" in data["friend"];
    assert data["friend"]["$ref"] == jid(carol);
}

test "_deserialize_value: $ref dict is resolved to NodeAnchor stub" {
    ref_id = uuid4();
    hex_id = ref_id.hex;

    stub = Serializer._deserialize_value({"$ref": hex_id});
    assert stub is not None;
    assert stub.id == ref_id;
    assert not stub.is_populated();
}

test "_deserialize_value: invalid $ref returns None" {
    assert Serializer._deserialize_value({"$ref": "not-a-uuid"}) is None;
}
