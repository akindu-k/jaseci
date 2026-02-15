"""Check if all classes is subclass of target type."""

impl all_issubclass(
    classes: type | UnionType | tuple[((type | UnionType), ...)], target: type
) -> bool {
    match classes {
        case type():
            return issubclass(classes, target);

        case UnionType():
            return all(all_issubclass(cls, target) for cls in classes.__args__);

        case tuple():
            return all(all_issubclass(cls, target) for cls in classes);

        case _:
            return False;

    }
}

"""Check if object is instance of target type."""
impl is_instance(
    `obj: object, target: type | UnionType | tuple[((type | UnionType), ...)]
) -> bool {
    match target {
        case UnionType():
            return any(is_instance(`obj, trg) for trg in target.__args__);

        case tuple():
            return any(is_instance(`obj, trg) for trg in target);

        case type():
            return isinstance(`obj, target);

        case _:
            return False;

    }
}

"""Extract model parameters, include and exclude information."""
impl extract_params(
    body: uni.FuncCall
) -> tuple[
    dict[(str, uni.Expr)],
    list[tuple[(str, ast3.AST)]],
    list[tuple[(str, ast3.AST)]]
] {
    model_params = {};
    include_info = [];
    exclude_info = [];
    if body.params {
        for param in body.params {
            if (isinstance(param, uni.KWPair) and isinstance(param.key, uni.Name)) {
                key = param.key.value;
                value = param.value;
                if (key not in ['incl_info', 'excl_info']) {
                    model_params[key] = value;
                } elif (key == 'incl_info') {
                    if isinstance(value, uni.AtomUnit) {
                        var_name = value.value.right.value
                        if (
                            isinstance(value.value, uni.AtomTrailer)
                            and isinstance(value.value.right, uni.Name)
                        )
                        else value.value.value
                        if isinstance(value.value, uni.Name)
                        else '';
                        include_info.append((var_name, value.gen.py_ast[0]));
                    } elif (isinstance(value, uni.TupleVal) and value.values) {
                        for i in value.values {
                            var_name = i.right.value
                            if (
                                isinstance(i, uni.AtomTrailer)
                                and isinstance(i.right, uni.Name)
                            )
                            else i.value if isinstance(i, uni.Name) else '';
                            include_info.append((var_name, i.gen.py_ast[0]));
                        }
                    }
                } elif (key == 'excl_info') {
                    if isinstance(value, uni.AtomUnit) {
                        var_name = value.value.right.value
                        if (
                            isinstance(value.value, uni.AtomTrailer)
                            and isinstance(value.value.right, uni.Name)
                        )
                        else value.value.value
                        if isinstance(value.value, uni.Name)
                        else '';
                        exclude_info.append((var_name, value.gen.py_ast[0]));
                    } elif (isinstance(value, uni.TupleVal) and value.values) {
                        for i in value.values {
                            var_name = i.right.value
                            if (
                                isinstance(i, uni.AtomTrailer)
                                and isinstance(i.right, uni.Name)
                            )
                            else i.value if isinstance(i, uni.Name) else '';
                            exclude_info.append((var_name, i.gen.py_ast[0]));
                        }
                    }
                }
            }
        }
    }
    return (model_params, include_info, exclude_info);
}

"""Collect type information in assignment using bfs."""
impl extract_type(nd: uni.UniNode) -> list[str] {
    extracted_type = [];
    if isinstance(nd, (uni.BuiltinType, uni.Token)) {
        extracted_type.append(nd.value);
    }
    for child in nd.kid {
        extracted_type.extend(extract_type(child));
    }
    return extracted_type;
}

"""Traverse the graph using Breadth-First Search (BFS) or Depth-First Search (DFS)."""
impl traverse_graph(
    nd: NodeArchetype,
    cur_depth: int,
    depth: int,
    edge_type: list[str],
    traverse: bool,
    connections: list,
    node_depths: dict[(NodeArchetype, int)],
    visited_nodes: list,
    queue: list,
    bfs: bool,
    dfs: Callable,
    node_limit: int,
    edge_limit: int
) -> None {
    for `edge in nd.__jac__.edges {
        is_self_loop = id(`edge.source) == id(`edge.target);
        is_in_edge = `edge.target == nd.__jac__;
        if (
            (traverse and is_in_edge)
            or (`edge.archetype.__class__.__name__ in edge_type)
        ) {
            continue;
        }
        if is_self_loop {
            continue;
        } elif (
            (other_nda := (`edge.target if not is_in_edge else `edge.source))
            and (other_nd := other_nda.archetype)
        ) {
            new_con = (nd, other_nd, `edge.archetype)
            if not is_in_edge
            else (other_nd, nd, `edge.archetype);
            if ((nd in node_depths) and (node_depths[nd] is not None)) {
                if (other_nd in node_depths) {
                    node_depths[nd] = min(
                        cur_depth, node_depths[nd], (node_depths[other_nd] + 1)
                    );
                    node_depths[other_nd] = min(
                        (cur_depth + 1), (node_depths[nd] + 1), node_depths[other_nd]
                    );
                } elif other_nd {
                    node_depths[other_nd] = min((cur_depth + 1), (node_depths[nd] + 1));
                } else {
                    raise ValueError('Edge is detached from node in graph') ;
                }
            }
            if (
                other_nd
                and (new_con not in connections)
                and (
                    (
                        (depth < 0)
                        or ((min(node_depths[nd], node_depths[other_nd]) + 1) <= depth)
                    )
                    and (node_limit > len(visited_nodes))
                    and (edge_limit > len(connections))
                )
            ) {
                connections.append(new_con);
                if bfs {
                    queue.append([other_nd, (cur_depth + 1)]);
                } else {
                    dfs(other_nd, (cur_depth + 1));
                }
            }
        }
    }
}

"""Nodes and edges representing the graph are collected in visited_nodes and connections."""
impl collect_node_connections(
    current_node: NodeArchetype, visited_nodes: set, connections: set, edge_ids: set
) -> None {
    if (current_node not in visited_nodes) {
        visited_nodes.add(current_node);
        edges = current_node.__jac__.edges;
        for edge_ in edges {
            if (edge_.id in edge_ids) {
                continue;
            }
            edge_ids.add(edge_.id);
            target = edge_.target;
            if target {
                connections.add(
                    (
                        edge_.id,
                        edge_.source.archetype,
                        target.archetype,
                        edge_.archetype
                    )
                );
                collect_node_connections(
                    target.archetype, visited_nodes, connections, edge_ids
                );
            }
        }
    }
}

"""Add a path to sys.path temporarily."""
impl sys_path_context(path: str) -> Iterator[None] {
    novel_path = path not in sys.path;
    try {
        if novel_path {
            sys.path.append(path);
        }
        yield ;
        ;
    } finally {
        if novel_path {
            sys.path.remove(path);
        }
    }
}

# Serializer Implementation
"""Serialize any object to JSON-compatible format."""
impl Serializer.serialize(`obj: object, include_type: bool = False) -> object {
    return Serializer._serialize_value(`obj, include_type);
}

"""Serialize a value recursively."""
impl Serializer._serialize_value(val: object, include_type: bool) -> object {
    import from uuid { UUID }
    import from enum { Enum, IntEnum }
    import from jaclang.jac0core.archetype {
        Anchor,
        NodeAnchor,
        EdgeAnchor,
        Permission,
        Access,
        AccessLevel
    }
    import from jaclang.jac0core.constructs { Archetype }
    # Primitives
    if val is None or isinstance(val, (str, int, float, bool)) {
        return val;
    }
    # UUID -> string
    if isinstance(val, UUID) {
        return str(val);
    }
    # Enum -> value (int or str)
    if isinstance(val, (Enum, IntEnum)) {
        return val.value;
    }
    # List/tuple
    if isinstance(val, (list, tuple)) {
        return [Serializer._serialize_value(item, include_type) for item in val];
    }
    # Dict
    if isinstance(val, dict) {
        return {
            str(k): Serializer._serialize_value(v, include_type)
            for (k, v) in val.items()
        };
    }
    # Access
    if isinstance(val, Access) {
        return {'anchors': {str(k): v.value for (k, v) in val.anchors.items()}};
    }
    # Permission
    if isinstance(val, Permission) {
        return {
            'all': val.all.value,
            'roots': Serializer._serialize_value(val.roots, include_type)
        };
    }
    # Anchor types (NodeAnchor, EdgeAnchor, Anchor)
    if isinstance(val, Anchor) {
        result: dict[str, object] = {};
        if include_type {
            result['__type__'] = type(val).__name__;
            result['__module__'] = type(val).__module__;
        }
        result['id'] = str(val.id);
        result['root'] = str(val.root) if val.root else None;
        result['persistent'] = val.persistent;
        result['access'] = Serializer._serialize_value(val.access, include_type);
        # Archetype (the user's node/edge/walker class)
        if val.is_populated() {
            arch = val.archetype;
            arch_data: dict[str, object] = {};
            if include_type {
                arch_data['__type__'] = type(arch).__name__;
                arch_data['__module__'] = type(arch).__module__;
            }
            # Serialize archetype fields
            for attr_name in dir(arch) {
                if not attr_name.startswith('_') and attr_name != '__jac__' {
                    with suppress(Exception) {
                        attr_val = getattr(arch, attr_name);
                        if not callable(attr_val) {
                            arch_data[attr_name] = Serializer._serialize_value(
                                attr_val, include_type
                            );
                        }
                    }
                }
            }
            result['archetype'] = arch_data;
        }
        # NodeAnchor specific: edges (store only IDs to avoid cycles)
        if isinstance(val, NodeAnchor) {
            result['edges'] = [str(e.id) for e in val.edges];
        }
        # EdgeAnchor specific: source, target, is_undirected
        if isinstance(val, EdgeAnchor) {
            result['source'] = str(val.source.id);
            result['target'] = str(val.target.id);
            result['is_undirected'] = val.is_undirected;
        }
        return result;
    }
    # Archetype (standalone, not wrapped in Anchor)
    if isinstance(val, Archetype) {
        result: dict[str, object] = {};
        if include_type {
            result['__type__'] = type(val).__name__;
            result['__module__'] = type(val).__module__;
            result['_jac_id'] = val.__jac__.id.hex if val?.__jac__ else None;
        }
        for attr_name in dir(val) {
            if not attr_name.startswith('_') and attr_name != '__jac__' {
                with suppress(Exception) {
                    attr_val = getattr(val, attr_name);
                    if not callable(attr_val) {
                        result[attr_name] = Serializer._serialize_value(
                            attr_val, include_type
                        );
                    }
                }
            }
        }
        return result;
    }
    # Generic object with __dict__
    if val?.__dict__ {
        with suppress(Exception) {
            result: dict[str, object] = {};
            if include_type {
                result['__type__'] = type(val).__name__;
                result['__module__'] = type(val).__module__;
            }
            for (k, v) in val.__dict__.items() {
                if not k.startswith('_') {
                    result[k] = Serializer._serialize_value(v, include_type);
                }
            }
            return result;
        }
    }
    # Fallback: string representation
    return str(val);
}

"""Deserialize data back to original object type."""
impl Serializer.deserialize(data: dict[str, object]) -> (object | None) {
    import from uuid { UUID }
    import from jaclang.jac0core.archetype {
        Anchor,
        NodeAnchor,
        EdgeAnchor,
        Permission,
        Access,
        AccessLevel
    }
    if not isinstance(data, dict) {
        return data;
    }
    type_name = data.get('__type__');
    module_name = data.get('__module__');
    if not type_name {
        # No type info, return as-is (recursively deserialize values)
        return {k: Serializer._deserialize_value(v) for (k, v) in data.items()};
    }
    # Handle Anchor types
    if type_name in ('Anchor', 'NodeAnchor', 'EdgeAnchor') {
        return Serializer._deserialize_anchor(data);
    }
    # Handle Permission
    if type_name == 'Permission' {
        return Serializer._deserialize_permission(data);
    }
    # Handle Access
    if type_name == 'Access' {
        return Serializer._deserialize_access(data);
    }
    # Try to get the class and reconstruct
    cls = Serializer._get_class(module_name, type_name);
    if cls {
        try {
            # Create instance and populate
            instance = object.__new__(cls);
            for (k, v) in data.items() {
                if not k.startswith('__') {
                    setattr(instance, k, Serializer._deserialize_value(v));
                }
            }
            return instance;
        } except Exception as e {
            logger.debug(f"Failed to deserialize {type_name}: {e}");
            return None;
        }
    }
    return None;
}

"""Deserialize a value recursively."""
impl Serializer._deserialize_value(val: object) -> object {
    if val is None or isinstance(val, (str, int, float, bool)) {
        return val;
    }
    if isinstance(val, list) {
        return [Serializer._deserialize_value(item) for item in val];
    }
    if isinstance(val, dict) {
        if '__type__' in val {
            return Serializer.deserialize(val);
        }
        return {k: Serializer._deserialize_value(v) for (k, v) in val.items()};
    }
    return val;
}

"""Get class by module and name."""
impl Serializer._get_class(module_name: str, class_name: str) -> (type | None) {
    import importlib;
    if not module_name or not class_name {
        return None;
    }
    try {
        module = importlib.import_module(module_name);
        return getattr(module, class_name, None);
    } except (ImportError, ModuleNotFoundError) as e {
        logger.debug(f"Failed to import {module_name}.{class_name}: {e}");
        return None;
    }
}

"""Helper to deserialize Anchor objects."""
impl Serializer._deserialize_anchor(data: dict[str, object]) -> (Anchor | None) {
    import from uuid { UUID }
    import from jaclang.jac0core.archetype {
        Anchor,
        NodeAnchor,
        EdgeAnchor,
        Permission
    }
    type_name = data.get('__type__', 'Anchor');
    # Determine anchor class
    if type_name == 'NodeAnchor' {
        anchor_cls = NodeAnchor;
    } elif type_name == 'EdgeAnchor' {
        anchor_cls = EdgeAnchor;
    } else {
        anchor_cls = Anchor;
    }
    try {
        # Create anchor instance
        anchor = object.__new__(anchor_cls);
        anchor.id = UUID(data['id']) if data.get('id') else None;
        anchor.root = UUID(data['root']) if data.get('root') else None;
        anchor.persistent = data.get('persistent', False);
        anchor.hash = 0;

        # Deserialize permission
        if (perm_data := data.get('access')) {
            anchor.access = Serializer._deserialize_permission(perm_data);
        } else {
            anchor.access = Permission();
        }
        # Deserialize archetype
        if (arch_data := data.get('archetype')) {
            anchor.archetype = Serializer._deserialize_archetype(arch_data, anchor);
        }

        # NodeAnchor: edges (stored as IDs, need lazy loading)
        if isinstance(anchor, NodeAnchor) {
            # Store edge IDs for lazy loading
            anchor._edge_ids = data.get('edges', []);
            anchor.edges = [];  # Will be populated on load
        }

        # EdgeAnchor: source/target stored as IDs
        if isinstance(anchor, EdgeAnchor) {
            anchor._source_id = data.get('source');
            anchor._target_id = data.get('target');
            anchor.is_undirected = data.get('is_undirected', False);
        }

        return anchor;
    } except Exception as e {
        logger.debug(f"Failed to deserialize anchor: {e}");
        return None;
    }
}

"""Helper to deserialize Permission."""
impl Serializer._deserialize_permission(data: object) -> Permission {
    import from jaclang.jac0core.archetype { Permission, Access, AccessLevel }
    if not isinstance(data, dict) {
        return Permission();
    }
    perm = Permission();
    perm.all = AccessLevel(data.get('all', -1));
    if (roots_data := data.get('roots')) {
        perm.roots = Serializer._deserialize_access(roots_data);
    }
    return perm;
}

"""Helper to deserialize Access."""
impl Serializer._deserialize_access(data: object) -> Access {
    import from jaclang.jac0core.archetype { Access, AccessLevel }
    if not isinstance(data, dict) {
        return Access();
    }
    access = Access();
    if (anchors := data.get('anchors')) {
        access.anchors = {k: AccessLevel(v) for (k, v) in anchors.items()};
    }
    return access;
}

"""Helper to deserialize Archetype."""
impl Serializer._deserialize_archetype(
    data: dict[str, object], anchor: Anchor
) -> (object | None) {
    type_name = data.get('__type__');
    module_name = data.get('__module__');
    if not type_name or not module_name {
        return None;
    }
    cls = Serializer._get_class(module_name, type_name);
    if not cls {
        return None;
    }
    try {
        # Create archetype instance without calling __init__
        arch = object.__new__(cls);

        # Populate fields
        for (k, v) in data.items() {
            if not k.startswith('__') {
                setattr(arch, k, Serializer._deserialize_value(v));
            }
        }

        # Link to anchor
        arch.__jac__ = anchor;

        return arch;
    } except Exception as e {
        logger.debug(f"Failed to deserialize archetype {type_name}: {e}");
        return None;
    }
}
