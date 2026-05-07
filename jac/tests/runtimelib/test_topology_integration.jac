"""Integration tests for topology index — config, instrumentation, serialization."""

import os;
import shutil;
import from tempfile { mkdtemp }
import from uuid { uuid4 }
import from jaclang.runtimelib.topology_index { TopologyIndex }

test "topology index config from toml" {
    import from jaclang.project.config { JacConfig }
    toml_str = "[project]\nname = \"test\"\n\n[run]\ntopology_index = false\n";
    cfg = JacConfig.from_toml_str(toml_str);
    assert cfg.run.topology_index is False;
}

test "l3 fetch counter" {
    import from jaclang.runtimelib.memory { SqliteMemory }
    import from jaclang.jac0core.archetype { Root }
    tmpdir = mkdtemp();
    try {
        mem = SqliteMemory(path=os.path.join(tmpdir, "test.db"));
        assert mem.l3_fetch_count == 0;
        r = Root();
        anchor = r.__jac__;
        anchor.persistent = True;
        mem.put(anchor);
        mem.sync();
        mem.__mem__.clear();
        mem.get(anchor.id);  # Cache miss, hits DB
        assert mem.l3_fetch_count == 1;
        # Cache hit — no increment
        mem.get(anchor.id);
        assert mem.l3_fetch_count == 1;
    } finally {
        mem.close();
        shutil.rmtree(tmpdir, ignore_errors=True);
    }
}

test "topology index survives anchor serialization" {
    import pickle;
    import from jaclang.jac0core.archetype { Root, NodeAnchor }
    r = Root();
    anchor = r.__jac__;
    idx = TopologyIndex();
    n1 = uuid4();
    idx.add_node(anchor.id, "Root");
    idx.add_node(n1, "NodeA");
    idx.add_edge(anchor.id, n1, "EdgeX");
    anchor.set_topology_index(idx);

    state = anchor.__getstate__();
    assert "topology_index_data" in state;

    restored = object.__new__(NodeAnchor);
    restored.__setstate__(state);
    decoded = restored.get_topology_index();
    assert len(decoded.adj_list) == 1;
    assert len(decoded.node_table) == 2;
}

test "is_topology_dirty set on content change cleared on sync" {
    import from jaclang.runtimelib.memory { SqliteMemory }
    import from jaclang.jac0core.archetype { Root }
    tmpdir = mkdtemp();
    try {
        mem = SqliteMemory(path=os.path.join(tmpdir, "test.db"));
        r = Root();
        anchor = r.__jac__;
        anchor.persistent = True;

        idx = TopologyIndex();
        idx.add_node(anchor.id, "Root");
        anchor.set_topology_index(idx);
        assert anchor.is_topology_dirty is True , "flag must be set after first write";

        mem.put(anchor);
        mem.sync();
        assert anchor.is_topology_dirty is False , "flag must be cleared after sync";
        mem.close();
    } finally {
        shutil.rmtree(tmpdir, ignore_errors=True);
    }
}

test "is_topology_dirty not set when content unchanged" {
    import from jaclang.jac0core.archetype { Root }
    r = Root();
    anchor = r.__jac__;

    idx = TopologyIndex();
    idx.add_node(anchor.id, "Root");
    anchor.set_topology_index(idx);
    anchor.is_topology_dirty = False;  # manually reset

    # Re-encoding the same content must not re-raise the flag
    anchor.set_topology_index(idx);
    assert anchor.is_topology_dirty is False , "no-op update must not set dirty flag";
}

test "topology-only update persisted in sqlite after hash unchanged" {
    # Regression: second walker updates only topology_index_data; hash stays
    # the same (topology excluded from hash), so sync must still write it.
    import from jaclang.runtimelib.memory { SqliteMemory }
    import from jaclang.jac0core.archetype { Root, NodeAnchor }
    tmpdir = mkdtemp();
    try {
        db_path = os.path.join(tmpdir, "test.db");

        # --- Request 1: create root with initial topology ---
        mem1 = SqliteMemory(path=db_path);
        r = Root();
        root_anchor = r.__jac__;
        root_anchor.persistent = True;
        idx1 = TopologyIndex();
        idx1.add_node(root_anchor.id, "Root");
        n1 = uuid4();
        idx1.add_node(n1, "UserProfile");
        idx1.add_edge(root_anchor.id, n1, "default");
        root_anchor.set_topology_index(idx1);
        mem1.put(root_anchor);
        mem1.sync();
        mem1.close();

        # --- Request 2: ONLY update topology (add new node type) ---
        mem2 = SqliteMemory(path=db_path);
        loaded = mem2.get(root_anchor.id);
        assert loaded is not None;
        assert isinstance(loaded, NodeAnchor);
        loaded_node: NodeAnchor = loaded;

        idx2 = loaded_node.get_topology_index();
        n2 = uuid4();
        idx2.add_node(n2, "Project");
        idx2.add_edge(root_anchor.id, n2, "default");
        loaded_node.set_topology_index(idx2);
        assert loaded_node.is_topology_dirty is True;
        # No other changes — hash will be identical to pre-change hash
        mem2.sync();
        assert loaded_node.is_topology_dirty is False , "flag must clear after sync";
        mem2.close();

        # --- Request 3: verify Project type is in the persisted index ---
        mem3 = SqliteMemory(path=db_path);
        final = mem3.get(root_anchor.id);
        assert final is not None and isinstance(final, NodeAnchor);
        final_node: NodeAnchor = final;
        final_idx = final_node.get_topology_index();
        type_names = set(final_idx.type_table);
        assert "Project" in type_names , f"Project type lost — only found: {type_names}";
        assert "UserProfile" in type_names , "UserProfile type unexpectedly missing";
        mem3.close();
    } finally {
        shutil.rmtree(tmpdir, ignore_errors=True);
    }
}

test "concurrent edge adds merged in sqlite sync" {
    import from jaclang.runtimelib.memory { SqliteMemory }
    import from jaclang.jac0core.archetype { Root, NodeAnchor, EdgeAnchor }
    tmpdir = mkdtemp();
    try {
        db_path = os.path.join(tmpdir, "test.db");

        # Create root with one initial edge
        mem0 = SqliteMemory(path=db_path);
        r = Root();
        anchor = r.__jac__;
        anchor.persistent = True;
        e0: EdgeAnchor = EdgeAnchor.__new__(EdgeAnchor);
        e0.id = uuid4();
        e0.persistent = True;
        anchor.edges = [e0];
        mem0.put(anchor);
        mem0.close();  # close() must flush pending writes

        # Two "requests" load the same root
        mem_a = SqliteMemory(path=db_path);
        mem_b = SqliteMemory(path=db_path);
        got_a = mem_a.get(anchor.id);
        got_b = mem_b.get(anchor.id);
        assert got_a is not None and got_b is not None;
        assert isinstance(got_a, NodeAnchor) and isinstance(got_b, NodeAnchor);
        a: NodeAnchor = got_a;
        b: NodeAnchor = got_b;

        # A adds edge_a, B adds edge_b
        ea: EdgeAnchor = EdgeAnchor.__new__(EdgeAnchor);
        ea.id = uuid4();
        a.edges.append(ea);

        eb: EdgeAnchor = EdgeAnchor.__new__(EdgeAnchor);
        eb.id = uuid4();
        b.edges.append(eb);

        # Commit A then B — B must not overwrite A's edge
        mem_a.sync();
        mem_b.sync();
        mem_a.close();
        mem_b.close();

        # Verify all 3 edges exist
        mem_c = SqliteMemory(path=db_path);
        got_c = mem_c.get(anchor.id);
        assert got_c is not None and isinstance(got_c, NodeAnchor);
        result: NodeAnchor = got_c;
        ids = set(e.id for e in result.edges);
        assert e0.id in ids , "Initial edge lost";
        assert ea.id in ids , "Edge A lost — overwritten by B";
        assert eb.id in ids , "Edge B lost";
        assert len(ids) == 3 , f"Expected 3, got {len(ids)}";
        mem_c.close();
    } finally {
        shutil.rmtree(tmpdir, ignore_errors=True);
    }
}
