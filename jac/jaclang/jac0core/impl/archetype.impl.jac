"""Implementation for archetype constructs."""

"""Validate access."""
impl Access.check(self: Access, anchor: str) -> (AccessLevel | None) {
    return self.anchors.get(anchor);
}

"""Filter edge."""
impl ObjectSpatialDestination.edge_filter(
    self: ObjectSpatialDestination, arch: Archetype
) -> bool {
    return (not self.edge or self.edge(arch));
}

"""Filter node."""
impl ObjectSpatialDestination.node_filter(
    self: ObjectSpatialDestination, arch: Archetype
) -> bool {
    return (not self.nd or self.nd(arch));
}

"""Override Init."""
impl ObjectSpatialPath.init(
    self: ObjectSpatialPath,
    origin: (NodeArchetype | list[NodeArchetype]),
    destinations: (list[ObjectSpatialDestination] | None) = None
) -> None {
    if not isinstance(origin, `list) {
        origin = [origin];
    }
    self.origin = origin;
    self.destinations = [] if (destinations is None) else destinations;
    self.edge_only = False;
    self.from_visit = False;
}

"""Convert filter."""
impl ObjectSpatialPath.convert(
    self: ObjectSpatialPath, filter: ObjectSpatialFilter
) -> (Callable[([Archetype], bool)] | None) {
    if not filter {
        return None;
    }
    if callable(filter) {
        return filter;
    } elif isinstance(filter, `list) {
        return lambda i: Any : (i in filter);
    }
    return lambda i: Any : (i == filter);
}

"""Append destination."""
impl ObjectSpatialPath.append(
    self: ObjectSpatialPath,
    direction: EdgeDir,
    `edge: ObjectSpatialFilter,
    nd: ObjectSpatialFilter
) -> ObjectSpatialPath {
    self.destinations.append(
        ObjectSpatialDestination(direction, self.convert(`edge), self.convert(nd))
    );
    return self;
}

"""Override greater than function."""
impl ObjectSpatialPath.edge_out(
    self: ObjectSpatialPath,
    `edge: ObjectSpatialFilter = None,
    nd: ObjectSpatialFilter = None
) -> ObjectSpatialPath {
    return self.append(EdgeDir.OUT, `edge, nd);
}

"""Override greater than function."""
impl ObjectSpatialPath.edge_in(
    self: ObjectSpatialPath,
    `edge: ObjectSpatialFilter = None,
    nd: ObjectSpatialFilter = None
) -> ObjectSpatialPath {
    return self.append(EdgeDir.IN, `edge, nd);
}

"""Override greater than function."""
impl ObjectSpatialPath.edge_any(
    self: ObjectSpatialPath,
    `edge: ObjectSpatialFilter = None,
    nd: ObjectSpatialFilter = None
) -> ObjectSpatialPath {
    return self.append(EdgeDir.ANY, `edge, nd);
}

"""Set edge only."""
impl ObjectSpatialPath.set_edge_only(self: ObjectSpatialPath) -> ObjectSpatialPath {
    self.edge_only = True;
    return self;
}

"""Repr builder."""
impl ObjectSpatialPath.repr_builder(
    self: ObjectSpatialPath, repr_str: str, dest: ObjectSpatialDestination, mark: str
) -> str {
    repr_str += mark;
    repr_str += f" (edge{' filter' if dest.edge else ''}) ";
    repr_str += mark;
    repr_str += f" (node{' filter' if dest.nd else ''}) ";
    return repr_str;
}

"""Override repr."""
impl ObjectSpatialPath.__repr__(self: ObjectSpatialPath) -> str {
    repr_str = 'nodes ';
    for dest in self.destinations {
        if (dest.direction == EdgeDir.IN) {
            repr_str = self.repr_builder(repr_str, dest, '<<');
        } elif (dest.direction == EdgeDir.OUT) {
            repr_str = self.repr_builder(repr_str, dest, '>>');
        } else {
            repr_str = self.repr_builder(repr_str, dest, '--');
        }
    }
    return repr_str.strip();
}

"""Check if state."""
impl Anchor.is_populated(self: Anchor) -> bool {
    return ('archetype' in self.__dict__);
}

"""Return unsynced copy of anchor."""
impl Anchor.make_stub(self: Anchor) -> TANCH {
    if self.is_populated() {
        unloaded = object.__new__(self.__class__);
        unloaded.id = self.id;
        return unloaded;
    }
    return self;
}

"""Retrieve the Archetype from db and return."""
impl Anchor.populate(self: Anchor) -> None {
    import from jaclang { JacRuntimeInterface as Jac }
    ctx = Jac.get_context();
    anchor = ctx.mem.get(self.id);
    if anchor {
        self.__dict__.update(anchor.__dict__);
    }
}

"""Trigger load if detects unloaded state."""
impl Anchor.__getattr__(self: Anchor, name: str) -> object {
    if not self.is_populated() {
        self.populate();
        if not self.is_populated() {
            raise ValueError(
                f"{self.__class__.__name__} [{self.id}] is not a validreference!"
            );
        }
        return getattr(self, name);
    }
    raise AttributeError(
        f"'{self.__class__.__name__} object has not attribute {name}'"
    );
}

"""Serialize Anchor."""
impl Anchor.__getstate__(self: Anchor) -> dict[(str, Any)] {
    if self.is_populated() {
        unlinked = object.__new__(self.archetype.__class__);
        unlinked.__dict__.update(self.archetype.__dict__);
        unlinked.__dict__.pop('__jac__', None);
        return {
            'id': self.id,
            'archetype': unlinked,
            'root': self.root,
            'access': self.access,
            'persistent': self.persistent
        };
    } else {
        return {'id': self.id};
    }
}

"""Deserialize Anchor."""
impl Anchor.__setstate__(self: Anchor, state: dict[(str, Any)]) -> None {
    self.__dict__.update(state);
    if (self.is_populated() and self.archetype) {
        self.archetype.__jac__ = self;
        self.hash = hash(dumps(self));
    }
}

"""Override representation."""
impl Anchor.__repr__(self: Anchor) -> str {
    if self.is_populated() {
        attrs = '';
        for f in fields(self) {
            if (f.name in self.__dict__) {
                attrs += f"{f.name}={self.__dict__[f.name]}, ";
            }
        }
        attrs = attrs[:-2];
    } else {
        attrs = f"id={self.id}";
    }
    return f"{self.__class__.__name__}({attrs})";
}

"""Report Anchor."""
impl Anchor.`report(self: Anchor) -> AnchorReport {
    return AnchorReport(
        id=self.id.hex,
        context=asdict(self.archetype)
            if (
                is_dataclass(self.archetype) and not isinstance(self.archetype, `type)
            )
            else {}
    );
}

"""Override hash for anchor."""
impl Anchor.__hash__(self: Anchor) -> int {
    return hash(self.id);
}

"""Override equal implementation."""
impl Anchor.__eq__(self: Anchor, other: object) -> bool {
    if isinstance(other, Anchor) {
        return ((self.__class__ is other.__class__) and (self.id == other.id));
    }
    return False;
}

"""Check if node anchor is fully populated (has edges)."""
impl NodeAnchor.is_populated(self: NodeAnchor) -> bool {
    d = self.__dict__;
    return 'edges' in d and 'archetype' in d;
}

"""Check if edge anchor is fully populated (has source/target)."""
impl EdgeAnchor.is_populated(self: EdgeAnchor) -> bool {
    d = self.__dict__;
    return 'source' in d and 'target' in d and 'archetype' in d;
}

"""Serialize Node Anchor."""
impl NodeAnchor.__getstate__(self: NodeAnchor) -> dict[(str, object)] {
    state = super.__getstate__();
    if self.is_populated() {
        state['edges'] = [`edge.make_stub() for `edge in self.edges];
        if self.topology_index_data is not None {
            state['topology_index_data'] = self.topology_index_data;
        }
    }
    return state;
}

"""Get decoded topology index (lazy-decoded from blob)."""
impl NodeAnchor.get_topology_index(self: NodeAnchor) -> Any {
    import from jaclang.runtimelib.topology_index { TopologyIndex }
    if self.topology_index_data {
        return TopologyIndex.decode(self.topology_index_data);
    }
    return TopologyIndex();
}

"""Set topology index from TopologyIndex object (encodes to blob)."""
impl NodeAnchor.set_topology_index(self: NodeAnchor, index: Any) -> None {
    self.topology_index_data = index.encode();
}

"""Serialize Edge Anchor."""
impl EdgeAnchor.__getstate__(self: EdgeAnchor) -> dict[(str, object)] {
    state = super.__getstate__();
    if self.is_populated() {
        state.update(
            {
                'source': self.source.make_stub(),
                'target': self.target.make_stub(),
                'is_undirected': self.is_undirected
            }
        );
    }
    return state;
}

"""Create default anchor."""
@cached_property
impl Archetype.__jac__(self: Archetype) -> Anchor {
    return Anchor(archetype=self);
}

"""Configure subclasses."""
impl Archetype.__init_subclass__(cls: Any, **kwargs: object) -> None {
    super.__init_subclass__(**kwargs);
    if not cls.__dict__.get('__jac_base__', False) {
        import from jaclang { JacRuntimeInterface as _ }
        _.make_archetype(cls);
        for hook in Archetype._subclass_hooks {
            hook(cls);
        }
    }
}

"""Override repr for archetype."""
impl Archetype.__repr__(self: Archetype) -> str {
    return f"{self.__class__.__name__}";
}

"""Override access validation."""
impl Archetype.__jac_access__(self: Archetype) -> (AccessLevel | str | int | None) {
    return None;
}

"""Override setattr to track field changes for automatic partial updates."""
impl Archetype.__setattr__(self: Archetype, name: str, value: object) -> None {
    # Skip tracking for internal/private fields and __jac__ anchor
    if name.startswith('_') or name == 'reports' {
        object.__setattr__(self, name, value);
        return;
    }
    # Set the value
    object.__setattr__(self, name, value);

    # Only track dirty fields if this is a persistent archetype
    # Check __dict__ directly to avoid triggering @cached_property during initialization
    if '__jac__' in self.__dict__ {
        anchor = self.__dict__['__jac__'];
        if anchor.persistent {
            # Track this field as dirty for partial update
            if '__jac_dirty_fields__' not in self.__dict__ {
                object.__setattr__(self, '__jac_dirty_fields__', set());
            }
            dirty_fields = self.__dict__['__jac_dirty_fields__'];

            # Add the field to dirty set first
            dirty_fields.add(name);

            # Dynamic threshold: switch to full sync if >80% of fields are dirty
            # This scales automatically: 10 fields → switch at 8, 200 fields → switch at 160
            # Get total fields from class (excluding private/internal fields)
            total_fields = len(
                [
                    f
                    for f in self.__class__.__dict__.keys()
                    if not f.startswith('_') and f != 'reports'
                ]
            );

            # If we don't have field metadata, use a conservative threshold of 50 fields
            if total_fields == 0 {
                total_fields = 50;
            }

            # Calculate dynamic threshold (80% of total fields)
            dirty_threshold = max(int(total_fields * 0.80), 10);  # Minimum 10 fields

            if len(dirty_fields) >= dirty_threshold {
                import from jaclang { logger }
                logger.debug(
                    f"Dirty fields threshold reached for {self.__class__.__name__} "
                    f"[{anchor.id}]: {len(dirty_fields)}/{total_fields} fields modified "
                    f"({len(dirty_fields) / total_fields * 100:.1f}%). "
                    f"Switching to full sync for efficiency."
                );
                # Mark that we need a full sync by setting a special flag
                # Keep dirty_fields intact for potential debugging
                object.__setattr__(self, '__jac_force_full_sync__', True);
            }
        }
    }
}

"""Get the set of dirty (modified) fields for partial update."""
impl Archetype.__jac_dirty_fields__(self: Archetype) -> (set[str] | None) {
    return self.__dict__.get('__jac_dirty_fields__');
}

"""Clear dirty fields tracking after persistence."""
impl Archetype.__jac_clear_dirty__(self: Archetype) -> None {
    if '__jac_dirty_fields__' in self.__dict__ {
        self.__dict__['__jac_dirty_fields__'].clear();
    }
    # Also clear force full sync flag if present
    if '__jac_force_full_sync__' in self.__dict__ {
        del self.__dict__['__jac_force_full_sync__'];
    }
}

"""Override repr for archetype."""
impl GenericEdge.__repr__(self: GenericEdge) -> str {
    return f"{self.__class__.__name__}()";
}

"""Create default anchor."""
@cached_property
impl Root.__jac__(self: Root) -> NodeAnchor {
    return NodeAnchor(archetype=self, persistent=True, edges=[]);
}

"""Override repr for archetype."""
impl Root.__repr__(self: Root) -> str {
    return f"{self.__class__.__name__}()";
}

"""Get function parameter annotations."""
@cached_property
impl ObjectSpatialFunction.trigger(
    self: ObjectSpatialFunction
) -> (type | UnionType | tuple[((type | UnionType), ...)] | None) {
    parameters = signature(self.func, eval_str=True).parameters;
    if (len(parameters) >= 2) {
        second_param = `list(parameters.values())[1];
        ty = second_param.annotation;
        return ty if (ty != _empty) else None;
    }
    return None;
}
