"""Bidirectional serializer for Jac objects."""
import from enum { Enum }
import from uuid { UUID }
import from jaclang.jac0core.archetype {
    Anchor,
    NodeAnchor,
    EdgeAnchor,
    Permission,
    Access,
    AccessLevel
}
import from jaclang.jac0core.constructs { Archetype, NodeArchetype, WalkerArchetype }

obj Serializer {
    """Registry of classes that may be deserialized.

    Populated automatically via Archetype.__init_subclass__ for all user-defined
    nodes, walkers, and edges. Only classes in this registry can be reconstructed
    from storage data, preventing arbitrary module import attacks.
    """
    static has _registry: dict[str, type] = {};

    """Register a class for deserialization by its fully-qualified name."""
    static def register(cls: type) -> None;

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

    """Deserialize data back to original object type.

    After field restoration, calls ``__jac_post_deserialize__(self)`` on the
    reconstructed object if that method is defined.  Use this hook to
    re-establish any invariants that ``__init__`` or ``__post_init__`` would
    normally set up (e.g. derived caches, threading locks, or validated
    computed fields) — all of which are bypassed when ``__new__`` is used for
    reconstruction.

    Example::

        obj MyNode {
            has count: int;

            def __jac_post_deserialize__(self: MyNode) -> None {
                self._cached_result = expensive_compute(self.count);
            }
        }
    """
    static def deserialize(data: dict[str, object]) -> (object | None);

    """Serialize a value recursively."""
    static def _serialize_value(
        val: object, include_type: bool, api_mode: bool = False
    ) -> object;

    """Deserialize a value recursively."""
    static def _deserialize_value(val: object) -> object;

    """Look up a registered class by module and name."""
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

# Install the registration hook onto Archetype once, at module load time.
# Archetype.__init_subclass__ calls each hook in _subclass_hooks for every
# new user-defined subclass. This keeps archetype.jac free of any knowledge
# of serializer.jac, eliminating the circular import.
glob _register_hook: object = Archetype._subclass_hooks.append(
         lambda cls: type :
             (
                 Serializer.register(cls)
                 if not cls.__module__.startswith('jaclang.')
                 else None
             )
     );
