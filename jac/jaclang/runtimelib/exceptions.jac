"""Typed runtime exceptions raised by the persistence layer."""

import from uuid { UUID }


"""Raised when a write violates a declared archetype uniqueness constraint."""
obj UniqueViolation(Exception) {
    has archetype_type: str,
        fields: list[str],
        values: dict[str, object],
        scope: str = "global",
        existing_id: (UUID | None) = None;

    def postinit {
        super.init(self.message());
    }

    """Human-readable summary of the violated constraint."""
    def message -> str {
        scoped = "per root" if self.scope == "root" else "globally";
        if self.fields {
            pairs = ", ".join([f"{f}={self.values.get(f)}" for f in self.fields]);
            return f"UniqueViolation: {self.archetype_type}({pairs}) must be unique {scoped}";
        }
        return f"UniqueViolation: only one {self.archetype_type} allowed {scoped}";
    }

    """Serializable form for the API error envelope."""
    def to_dict -> dict[str, object] {
        return {
            "archetype": self.archetype_type,
            "fields": self.fields,
            "values": self.values,
            "scope": self.scope
        };
    }
}
