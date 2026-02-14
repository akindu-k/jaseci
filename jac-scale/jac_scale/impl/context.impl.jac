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
        super_root_id = UUID(Con.SUPER_ROOT_UUID);
        if self.mem.l3 is not None and self.mem.l3.`has(super_root_id) {
            raise RuntimeError(
                f"System root anchor (id={Con.SUPER_ROOT_UUID}) exists in "
                f"persistent storage but could not be deserialized. "
            ) ;
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
