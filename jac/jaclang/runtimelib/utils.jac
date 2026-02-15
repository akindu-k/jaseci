"""Helper for construct."""
import ast as ast3;
import sys;
import logging;
import from collections.abc { Callable, Iterator }
import from contextlib { contextmanager, suppress }
import from types { UnionType }
import from typing { TYPE_CHECKING }
import from uuid { UUID }
import jaclang.jac0core.unitree as uni;

import from jaclang.jac0core.helpers {
    read_file_with_encoding as read_file_with_encoding
}

glob logger = logging.getLogger(__name__);

with entry {
    if TYPE_CHECKING {
        import from jaclang.jac0core.constructs { NodeArchetype }
    }
}

@contextmanager
def sys_path_context(path: str) -> Iterator[None];

def collect_node_connections(
    current_node: NodeArchetype, visited_nodes: set, connections: set, edge_ids: set
) -> None;

def traverse_graph(
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
) -> None;

def extract_type(nd: uni.UniNode) -> list[str];

def extract_params(
    body: uni.FuncCall
) -> tuple[
    dict[(str, uni.Expr)],
    list[tuple[(str, ast3.AST)]],
    list[tuple[(str, ast3.AST)]]
];

def is_instance(
    `obj: object, target: type | UnionType | tuple[((type | UnionType), ...)]
) -> bool;

def all_issubclass(
    classes: type | UnionType | tuple[((type | UnionType), ...)], target: type
) -> bool;

"""Generate a storage key for an anchor ID."""
def storage_key(id: UUID) -> str {
    return f"anchor:{str(id)}";
}

"""Convert string or UUID to UUID."""
def to_uuid(id: (UUID | str)) -> UUID {
    if isinstance(id, UUID) {
        return id;
    }
    return UUID(str(id));
}

"""Bidirectional serializer for Jac objects."""
obj Serializer {
    """Serialize any object to JSON-compatible format.

    Args:
        obj: The object to serialize.
        include_type: If True, embeds __type__/__module__ metadata for round-trip
            deserialization (used by storage backends).
        api_mode: If True, adds _jac_type/_jac_id/_jac_archetype metadata to
            Archetype objects for API responses.
    """
    static def serialize(
        `obj: object, include_type: bool = False, api_mode: bool = False
    ) -> object;

    """Deserialize data back to original object type."""
    static def deserialize(data: dict[str, object]) -> (object | None);

    """Serialize a value recursively."""
    static def _serialize_value(
        val: object, include_type: bool, api_mode: bool = False
    ) -> object;

    """Deserialize a value recursively."""
    static def _deserialize_value(val: object) -> object;

    """Get class by module and name."""
    static def _get_class(module_name: str, class_name: str) -> (type | None);

    """Deserialize Anchor objects."""
    static def _deserialize_anchor(data: dict[str, object]) -> (object | None);

    """Deserialize Permission objects."""
    static def _deserialize_permission(data: object) -> object;

    """Deserialize Access objects."""
    static def _deserialize_access(data: object) -> object;

    """Deserialize Archetype objects."""
    static def _deserialize_archetype(
        data: dict[str, object], anchor: object
    ) -> (object | None);
}
