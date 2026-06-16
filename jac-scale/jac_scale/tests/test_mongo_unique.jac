"""Integration tests for declared archetype uniqueness (issue #6266)."""

import atexit;
import os;
import from uuid { uuid4, UUID }
import from pymongo { MongoClient }
import from testcontainers.mongodb { MongoDbContainer }

import from jaclang.jac0core.archetype { NodeAnchor, NodeArchetype, Root }
import from jaclang.runtimelib.changeset { ChangeSet }
import from jaclang.runtimelib.exceptions { UniqueViolation }
import from jaclang.runtimelib.index_registry { register_unique_index }
import from jac_scale.memory_hierarchy {
    _process_cache,
    MongoBackend,
    ScaleTieredMemory
}

glob _shared: dict = {};


obj _UniqProfile(Root) {
    has user_id: str = "";
}

obj _UniqEmail(Root) {
    has email: str = "";
}


"""Lazily start a shared MongoDB container; return (MongoClient, uri)."""
def _get_mongo -> tuple {
    if "mongo_client" not in _shared {
        container = MongoDbContainer("mongo:latest");
        container.start();
        uri = container.get_connection_url();
        _shared["mongo_container"] = container;
        _shared["mongo_uri"] = uri;
        _shared["mongo_client"] = MongoClient(uri);
        atexit.register(container.stop);
    }
    return (_shared["mongo_client"], _shared["mongo_uri"]);
}


"""Drop all non-system databases between tests."""
def _reset_mongo -> None {
    if "mongo_client" not in _shared {
        return;
    }
    system_dbs = {"admin", "config", "local"};
    for db_name in _shared["mongo_client"].list_database_names() {
        if db_name not in system_dbs {
            _shared["mongo_client"].drop_database(db_name);
        }
    }
}


"""Build a persistent node anchor of `arch` owned by `root_id`."""
def _make_node(arch: NodeArchetype, root_id: UUID) -> NodeAnchor {
    anchor = arch.__jac__;
    anchor.persistent = True;
    setattr(anchor, 'root', root_id);
    return anchor;
}


test "root-scoped unique index is created from the registry" {
    _reset_mongo();
    (client, uri) = _get_mongo();
    register_unique_index(_UniqProfile, scope="root");
    backend = MongoBackend(mongo_url=uri, db_name="jac_test_uniq");
    names = {ix['name'] for ix in client["jac_test_uniq"]["_anchors"].list_indexes()};
    assert "uniq_root__UniqProfile" in names;
    backend.close();
}


test "duplicate root-scoped node raises typed UniqueViolation, one doc persists" {
    _reset_mongo();
    (client, uri) = _get_mongo();
    register_unique_index(_UniqProfile, scope="root");
    backend = MongoBackend(mongo_url=uri, db_name="jac_test_uniq");
    root_id = uuid4();

    first = _make_node(_UniqProfile(user_id=str(uuid4())), root_id);
    backend._write_to_db(first);

    second = _make_node(_UniqProfile(user_id=str(uuid4())), root_id);
    raised = False;
    try {
        backend._write_to_db(second);
    } except UniqueViolation as uv {
        raised = True;
        assert uv.archetype_type == "_UniqProfile";
        assert uv.scope == "root";
    }
    assert raised;
    count = client["jac_test_uniq"]["_anchors"].count_documents(
        {'arch_type': '_UniqProfile'}
    );
    assert count == 1;
    backend.close();
}


test "global field-scoped duplicate carries field and value" {
    _reset_mongo();
    (client, uri) = _get_mongo();
    register_unique_index(_UniqEmail, fields=["email"], scope="global");
    backend = MongoBackend(mongo_url=uri, db_name="jac_test_uniq");

    first = _make_node(_UniqEmail(email="a@a.com"), uuid4());
    backend._write_to_db(first);

    # Different owning root, same email: global scope still collides.
    second = _make_node(_UniqEmail(email="a@a.com"), uuid4());
    captured: (UniqueViolation | None) = None;
    try {
        backend._write_to_db(second);
    } except UniqueViolation as uv {
        captured = uv;
    }
    assert captured is not None;
    assert captured.scope == "global";
    assert "email" in captured.fields;
    assert captured.values.get("email") == "a@a.com";
    backend.close();
}


test "apply records the violation instead of inserting a duplicate" {
    _reset_mongo();
    (client, uri) = _get_mongo();
    register_unique_index(_UniqProfile, scope="root");
    backend = MongoBackend(mongo_url=uri, db_name="jac_test_uniq");
    root_id = uuid4();

    first = _make_node(_UniqProfile(user_id=str(uuid4())), root_id);
    cs1 = ChangeSet();
    cs1.record_create(first);
    backend.apply(cs1);

    second = _make_node(_UniqProfile(user_id=str(uuid4())), root_id);
    cs2 = ChangeSet();
    cs2.record_create(second);
    rep = backend.apply(cs2);

    assert len(rep.violations) == 1;
    assert rep.violations[0].archetype_type == "_UniqProfile";
    count = client["jac_test_uniq"]["_anchors"].count_documents(
        {'arch_type': '_UniqProfile'}
    );
    assert count == 1;
    backend.close();
}


test "commit raises UniqueViolation when two creates collide in one unit" {
    _reset_mongo();
    (client, uri) = _get_mongo();
    _process_cache.clear();
    register_unique_index(_UniqProfile, scope="root");
    os.environ["MONGODB_URI"] = str(uri);
    try {
        mem = ScaleTieredMemory();
        mem.postinit();
        assert mem.l3 is not None , "MongoDB backend must be available";
        root_id = uuid4();
        a = _make_node(_UniqProfile(user_id=str(uuid4())), root_id);
        b = _make_node(_UniqProfile(user_id=str(uuid4())), root_id);
        mem.put(a);
        mem.put(b);
        raised = False;
        try {
            mem.commit();
        } except UniqueViolation as uv {
            raised = True;
            assert uv.scope == "root";
            assert uv.archetype_type == "_UniqProfile";
        }
        assert raised , "commit must surface the duplicate as UniqueViolation";
        count = mem.l3.collection.count_documents({'arch_type': '_UniqProfile'});
        assert count == 1;
    } finally {
        os.environ.pop("MONGODB_URI", None);
        _process_cache.clear();
    }
}
