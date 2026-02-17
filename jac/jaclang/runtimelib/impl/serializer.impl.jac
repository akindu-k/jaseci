import logging;
import from contextlib { suppress }
import from enum { Enum, IntEnum }
import from uuid { UUID }

glob logger = logging.getLogger(__name__);

"""Serialize any object to JSON-compatible format."""
impl Serializer.serialize(
    `obj: object, include_type: bool = False, api_mode: bool = False
) -> object {
    return Serializer._serialize_value(`obj, include_type, api_mode);
}

"""Serialize a value recursively."""
impl Serializer._serialize_value(
    val: object, include_type: bool, api_mode: bool = False
) -> object {
    import from jaclang.jac0core.archetype {
        Anchor,
        NodeAnchor,
        EdgeAnchor,
        Permission,
        Access
    }
    import from jaclang.jac0core.constructs {
        Archetype,
        NodeArchetype,
        WalkerArchetype
    }
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
        return [
            Serializer._serialize_value(item, include_type, api_mode) for item in val
        ];
    }
    # Dict
    if isinstance(val, dict) {
        return {
            str(k): Serializer._serialize_value(v, include_type, api_mode)
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
            'roots': Serializer._serialize_value(val.roots, include_type, api_mode)
        };
    }
    # Anchor types (NodeAnchor, EdgeAnchor, Anchor)
    if isinstance(val, Anchor) {
        result: dict[str, object] = {
            '__type__': type(val).__name__,
            '__module__': type(val).__module__
        }
        if include_type
        else {};
        result['id'] = str(val.id);
        result['root'] = str(val.root) if val.root else None;
        result['persistent'] = val.persistent;
        result['access'] = Serializer._serialize_value(
            val.access, include_type, api_mode
        );
        # Archetype (the user's node/edge/walker class)
        if val.is_populated() {
            arch = val.archetype;
            arch_data: dict[str, object] = {
                '__type__': type(arch).__name__,
                '__module__': type(arch).__module__
            }
            if include_type
            else {};
            arch_data |= {
                a: Serializer._serialize_value(
                    getattr(arch, a), include_type, api_mode
                )
                for a in dir(arch)
                if not a.startswith('_')
                and a != '__jac__'
                and not callable(getattr(arch, a, None))
            };
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
        result: dict[str, object] = {
            '__type__': type(val).__name__,
            '__module__': type(val).__module__,
            '_jac_id': val.__jac__.id.hex if val?.__jac__ else None
        }
        if include_type
        else {};
        # api_mode: inject _jac_ metadata for API consumers
        if api_mode {
            result['_jac_type'] = type(val).__name__;
            result['_jac_id'] = val.__jac__.id.hex if val?.__jac__ else None;
            result['_jac_archetype'] = 'node'
            if isinstance(val, NodeArchetype)
            else 'walker' if isinstance(val, WalkerArchetype) else 'archetype';
        }
        result |= {
            a: Serializer._serialize_value(getattr(val, a), include_type, api_mode=api_mode)
            for a in dir(val)
            if not a.startswith('_')
            and a != '__jac__'
            and not callable(getattr(val, a, None))
        };
        return result;
    }
    # Generic object with __dict__
    if val?.__dict__ {
        with suppress(Exception) {
            result: dict[str, object] = {
                '__type__': type(val).__name__,
                '__module__': type(val).__module__
            }
            if include_type
            else {};
            for (k, v) in val.__dict__.items() {
                if not k.startswith('_') {
                    result[k] = Serializer._serialize_value(v, include_type, api_mode);
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
    import from jaclang.jac0core.archetype { Permission, Access }
    if not isinstance(data, dict) {
        return data;
    }
    type_name = data.get('__type__');
    module_name = data.get('__module__');
    if not type_name {
        # No type info, return as-is (recursively deserialize values)
        return {k: Serializer._deserialize_value(v) for (k, v) in data.items()};
    }
    _dispatch = {
        'Anchor': Serializer._deserialize_anchor,
        'NodeAnchor': Serializer._deserialize_anchor,
        'EdgeAnchor': Serializer._deserialize_anchor,
        'Permission': Serializer._deserialize_permission,
        'Access': Serializer._deserialize_access
    };
    if (handler := _dispatch.get(type_name)) {
        return handler(data);
    }
    # Try to get the class and reconstruct
    cls = Serializer._get_class(module_name, type_name);
    if cls {
        try {
            instance = cls.__new__(cls);
            for (k, v) in data.items() {
                if not k.startswith('__') {
                    setattr(instance, k, Serializer._deserialize_value(v));
                }
            }
            return instance;
        } except Exception as e {
            logger.error(f"Failed to deserialize {type_name}: {e}");
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

"""Register a class for safe deserialization."""
impl Serializer.register(cls: type) -> None {
    Serializer._registry[f"{cls.__module__}.{cls.__name__}"] = cls;
}

"""Look up a class in the registry by module and name.

Only classes explicitly registered via Serializer.register() (auto-called by
Archetype.__init_subclass__) can be reconstructed. This prevents arbitrary
module import attacks where tampered storage data sets __module__ to a
dangerous stdlib namespace (e.g. subprocess.Popen).
"""
impl Serializer._get_class(module_name: str, class_name: str) -> (type | None) {
    if not module_name or not class_name {
        return None;
    }
    key = f"{module_name}.{class_name}";
    cls = Serializer._registry.get(key);
    if not cls {
        logger.warning(f"Refused to deserialize unregistered class: {key}");
    }
    return cls;
}

"""Helper to deserialize Anchor objects."""
impl Serializer._deserialize_anchor(data: dict[str, object]) -> (Anchor | None) {
    import from jaclang.jac0core.archetype {
        Anchor,
        NodeAnchor,
        EdgeAnchor,
        Permission
    }
    anchor_cls = {'NodeAnchor': NodeAnchor, 'EdgeAnchor': EdgeAnchor}.get(
        data.get('__type__', ''), Anchor
    );
    try {
        anchor = anchor_cls.__new__(anchor_cls);
        anchor.id = UUID(data['id']) if data.get('id') else None;
        anchor.root = UUID(data['root']) if data.get('root') else None;
        anchor.persistent = data.get('persistent', False);
        anchor.access = Serializer._deserialize_permission(perm_data)
        if (perm_data := data.get('access'))
        else Permission();
        if (arch_data := data.get('archetype')) {
            anchor.archetype = Serializer._deserialize_archetype(arch_data, anchor);
        }
        if isinstance(anchor, NodeAnchor) {
            anchor._edge_ids = data.get('edges', []);
            anchor.edges = [];
        }
        if isinstance(anchor, EdgeAnchor) {
            anchor._source_id = data.get('source');
            anchor._target_id = data.get('target');
            anchor.is_undirected = data.get('is_undirected', False);
        }
        return anchor;
    } except Exception as e {
        logger.error(f"Failed to deserialize anchor: {e}");
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
    import from jaclang.jac0core.archetype { Anchor }
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
            arch = cls.__new__(cls);
        for (k, v) in data.items() {
            if not k.startswith('__') {
                setattr(arch, k, Serializer._deserialize_value(v));
            }
        }
        arch.__jac__ = anchor;
        return arch;
    } except Exception as e {
        logger.error(f"Failed to deserialize archetype {type_name}: {e}");
        return None;
    }
}
