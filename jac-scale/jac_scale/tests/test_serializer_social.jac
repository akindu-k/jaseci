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
# ref_mode tests
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

"""Build the canonical circular graph (city, alice, bob) for ref_mode tests."""
def make_ref_graph -> tuple {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city, friend=alice);
    alice.friend = bob;
    return (city, alice, bob);
}

test "ref_mode=False: both city occurrences fully inline, no $ref emitted" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);

    data = Serializer.serialize([alice, bob], ref_mode=False);

    assert isinstance(data[0]["city"], dict) and "name" in data[0]["city"];
    assert isinstance(data[1]["city"], dict) and "name" in data[1]["city"];
    assert data[0]["city"]["name"] == "Metropolis";
    assert data[1]["city"]["name"] == "Metropolis";
    assert "$ref" not in str(data);
}

test "ref_mode: lone object is fully inlined, no $ref emitted" {
    city = City(name="Gotham");
    data = Serializer.serialize(city, ref_mode=True);

    assert isinstance(data, dict);
    assert data["name"] == "Gotham";
    assert "$ref" not in str(data);
}

test "ref_mode: city shared by two persons — first inline, second is $ref" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);

    data = Serializer.serialize([alice, bob], ref_mode=True);

    # alice.city — first encounter → full inline
    assert isinstance(data[0]["city"], dict) and "name" in data[0]["city"];
    assert data[0]["city"]["name"] == "Metropolis";

    # bob.city — second encounter → $ref pointing to the same ID
    assert "$ref" in data[1]["city"];
    assert data[1]["city"]["$ref"] == jid(city);
}

test "ref_mode: circular alice→bob→alice terminates — no infinite recursion" {
    (city, alice, bob) = make_ref_graph();

    data = Serializer.serialize(alice, ref_mode=True);

    # alice root is fully inlined
    assert data["name"] == "Alice";

    # alice.city — first encounter of city → inline
    assert isinstance(data["city"], dict) and data["city"]["name"] == "Metropolis";

    # alice.friend = bob — fully inlined (first encounter of bob)
    assert isinstance(data["friend"], dict) and data["friend"]["name"] == "Bob";

    # bob.city — second encounter of city → $ref
    assert "$ref" in data["friend"]["city"];
    assert data["friend"]["city"]["$ref"] == jid(city);

    # bob.friend = alice — second encounter of alice → $ref (circular stop)
    assert "$ref" in data["friend"]["friend"];
    assert data["friend"]["friend"]["$ref"] == jid(alice);
}

test "ref_mode: mutated field value is reflected in next serialization" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);

    city.name = "Gotham";
    data = Serializer.serialize(alice, ref_mode=True);

    assert data["city"]["name"] == "Gotham";
}

test "ref_mode: mutated name is inlined; $ref still points to stable object ID" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);

    city_id = jid(city);
    city.name = "Gotham";  # mutate after capturing the ID

    data = Serializer.serialize([alice, bob], ref_mode=True);

    # alice.city inline with the updated name
    assert data[0]["city"]["name"] == "Gotham";
    # bob.city is $ref pointing to the same stable ID
    assert data[1]["city"]["$ref"] == city_id;
}

test "ref_mode: assigning friend after construction is serialized correctly" {
    city = City(name="Metropolis");
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);

    alice.friend = bob;
    data = Serializer.serialize(alice, ref_mode=True);

    assert data["friend"]["name"] == "Bob";
    # bob.city already seen via alice.city → $ref
    assert "$ref" in data["friend"]["city"];
}

test "ref_mode: reassigning friend to a different object is captured" {
    city = City(name="Metropolis");
    other = City(name="Gotham");
    alice = Person(name="Alice", city=city);
    carol = Person(name="Carol", city=other);

    alice.friend = carol;
    data = Serializer.serialize(alice, ref_mode=True);

    assert data["friend"]["name"] == "Carol";
    assert data["friend"]["city"]["name"] == "Gotham";
}

test "ref_mode: mutating fields does not change object identity" {
    city = City(name="Metropolis");
    id_before = jid(city);

    city.name = "Gotham";
    assert jid(city) == id_before;

    city.name = "Star City";
    assert jid(city) == id_before;
}

test "ref_mode: full lifecycle — shared city, circular friends, and mutable fields" {
    # ── Build fixture ──────────────────────────────────────────────────────────
    city = City(name="Metropolis");  # shared by alice and bob
    alice = Person(name="Alice", city=city);
    bob = Person(name="Bob", city=city);
    alice.friend = bob;
    bob.friend = alice;  # circular: alice → bob → alice

    city_id = jid(city);
    alice_id = jid(alice);
    bob_id = jid(bob);

    # ── Phase 1: initial serialization of alice ───────────────────────────────
    data = Serializer.serialize(alice, ref_mode=True);

    assert data["name"] == "Alice";
    # alice.city — first encounter of city → fully inline
    assert isinstance(data["city"], dict) and data["city"]["name"] == "Metropolis";
    # alice.friend = bob — first encounter of bob → fully inline
    assert isinstance(data["friend"], dict) and data["friend"]["name"] == "Bob";
    # bob.city — second encounter of city → $ref
    assert "$ref" in data["friend"]["city"];
    assert data["friend"]["city"]["$ref"] == city_id;
    # bob.friend = alice — second encounter of alice → $ref (circular stop)
    assert "$ref" in data["friend"]["friend"];
    assert data["friend"]["friend"]["$ref"] == alice_id;

    # ── Phase 2: mutate city.name — inline reflects change, $ref ID is stable ─
    city.name = "Gotham";
    data2 = Serializer.serialize(alice, ref_mode=True);

    assert data2["city"]["name"] == "Gotham";  # inline has new name
    assert "$ref" in data2["friend"]["city"];
    assert data2["friend"]["city"]["$ref"] == city_id;  # $ref still stable
    assert jid(city) == city_id;  # identity unchanged

    # ── Phase 3: break the cycle (alice.friend = None) ────────────────────────
    alice.friend = None;
    data3 = Serializer.serialize(alice, ref_mode=True);

    assert data3["friend"] is None;
    assert data3["city"]["name"] == "Gotham";  # city still inline

    # bob independently: bob.friend = alice (inline), bob.city = $ref
    data_bob = Serializer.serialize(bob, ref_mode=True);
    assert data_bob["name"] == "Bob";
    assert isinstance(data_bob["friend"], dict)
    and data_bob["friend"]["name"] == "Alice";
    assert "$ref" in data_bob["friend"]["city"];
    assert data_bob["friend"]["city"]["$ref"] == city_id;

    # ── Phase 4: reassign alice.friend to a new person with a different city ──
    carol = Person(name="Carol", city=City(name="Star City"));
    alice.friend = carol;
    data4 = Serializer.serialize(alice, ref_mode=True);

    assert data4["friend"]["name"] == "Carol";
    assert isinstance(data4["friend"]["city"], dict);
    assert data4["friend"]["city"]["name"] == "Star City";  # new city → fully inline

    # ── Phase 5: jid() stability across all mutations ─────────────────────────
    assert jid(alice) == alice_id;
    assert jid(bob) == bob_id;
    assert jid(city) == city_id;
}

test "_is_jac_ref: correctly identifies $ref dicts" {
    assert Serializer._is_jac_ref({"$ref": "abc123"});
    assert not Serializer._is_jac_ref({"name": "Alice"});
    assert not Serializer._is_jac_ref({});
    assert not Serializer._is_jac_ref("not a dict");
    assert not Serializer._is_jac_ref(None);
    assert not Serializer._is_jac_ref(42);
}

test "_deserialize_jac_ref: returns Anchor stub with matching ID" {
    # Use uuid4() directly so we have a known UUID to round-trip
    ref_id = uuid4();
    hex_id = ref_id.hex;

    stub = Serializer._deserialize_jac_ref({"$ref": hex_id});
    assert stub is not None;
    assert stub.id == ref_id;
}

test "_deserialize_jac_ref: invalid UUID or missing key returns None" {
    assert Serializer._deserialize_jac_ref({"$ref": "not-a-uuid"}) is None;
    assert Serializer._deserialize_jac_ref({}) is None;
}

test "_deserialize_value: $ref dict is resolved to Anchor stub" {
    ref_id = uuid4();
    hex_id = ref_id.hex;

    stub = Serializer._deserialize_value({"$ref": hex_id});
    assert stub is not None;
    assert stub.id == ref_id;
}
