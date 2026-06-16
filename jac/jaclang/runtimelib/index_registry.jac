"""App-declared archetype uniqueness, the source of truth for backend unique indexes."""

"""One declared uniqueness constraint on an archetype."""
obj UniqueIndexSpec {
    has archetype_cls: type,
        fields: list[str],
        scope: str = "global",
        name: (str | None) = None;

    """Archetype class name as stored in `arch_type`."""
    def arch_name -> str {
        return getattr(self.archetype_cls, '__name__', str(self.archetype_cls));
    }
}


glob _unique_indexes: list[UniqueIndexSpec] = [];


"""Declare an archetype unique on `fields` within `scope` (`fields=[]` means one per scope)."""
def register_unique_index(
    archetype_cls: type,
    fields: (list[str] | None) = None,
    scope: str = "global",
    name: (str | None) = None
) -> None {
    spec = UniqueIndexSpec(
        archetype_cls=archetype_cls,
        fields=fields if fields is not None else [],
        scope=scope,
        name=name
    );
    for existing in _unique_indexes {
        if (
            existing.arch_name() == spec.arch_name()
            and existing.fields == spec.fields
            and existing.scope == spec.scope
        ) {
            return;
        }
    }
    _unique_indexes.append(spec);
}


"""All registered uniqueness specs (a copy, safe to iterate while mutating)."""
def get_unique_indexes -> list[UniqueIndexSpec] {
    return list(_unique_indexes);
}


"""Clear the registry (test isolation; not used by production code)."""
def clear_unique_indexes -> None {
    _unique_indexes.clear();
}


"""Scope declared for `arch_type` covering `field`, or "global" if none."""
def lookup_scope(arch_type: str, field: str) -> str {
    for spec in _unique_indexes {
        if spec.arch_name() == arch_type
        and (not spec.fields or field in spec.fields) {
            return spec.scope;
        }
    }
    return "global";
}
