"""Initialize JScaleExecutionContext.

Storage backend is configured via environment variables (e.g., MONGODB_URI),
not per-context parameters.
"""

impl JScaleExecutionContext.init(self: JScaleExecutionContext) -> None {
    import from jac_scale.memory_hierarchy { ScaleTieredMemory }
    import from jaclang.jac0core.constructs { Anchor, NodeAnchor, Root }
    # ScaleTieredMemory gets storage config from environment variables
    self.mem = ScaleTieredMemory();
    self.reports: list[Any] = [];
    self.custom: Any = MISSING;
    system_root_anchor: (Anchor | None) = self.mem.get(UUID(Con.SUPER_ROOT_UUID));
    if not isinstance(system_root_anchor, NodeAnchor) {
        # Only create a new system root if one does NOT already exist in storage.
        # If l3 (persistent backend) has the key, deserialization failed - raise
        # rather than silently overwriting previously stored user data.
        super_root_id = UUID(Con.SUPER_ROOT_UUID);
        if self.mem.l3 is not None and self.mem.l3.`has(super_root_id) {
            raise RuntimeError(
                f"System root anchor (id={Con.SUPER_ROOT_UUID}) exists in "
                f"persistent storage but could not be deserialized. "
                f"This likely means the stored data is from an incompatible version. "
                f"Check logs for details. Refusing to overwrite existing data."
            );
        }
        system_root_anchor = Root().__jac__;
        system_root_anchor.id = super_root_id;
        self.mem.put(system_root_anchor);
    }
    self.system_root = system_root_anchor;
    # Default user_root and entry_node to system_root
    self.user_root = self.system_root;
    self.entry_node = self.system_root;
    self.call_state: ContextVar[CallState] = ContextVar('call_state');
}
