# Research: Supporting Custom Objects in Jac Scale API Endpoints

## Problem Statement

When a Jac walker has a field typed as a custom `obj`, the generated FastAPI endpoint does not produce a proper nested JSON schema. Instead, the custom type falls through to `str` (the default in `_get_python_type`), resulting in a flat, incorrect request body.

**Example:**
```jac
walker mywalker {
    has user: User;
}
obj User {
    has name: str;
    has age: int;
}
```

**Current behavior:** `user` becomes a `str` field in the OpenAPI schema.
**Expected behavior:** `user` becomes a nested object `{"name": "string", "age": 0}`.

---

## Current Architecture (Pipeline Analysis)

The type information flows through 4 stages, and the problem spans all of them:

### Stage 1: Introspection (`introspect_walker`)
**File:** `jac/jaclang/runtimelib/impl/server.impl.jac:778-823`

```
get_type_hints(walker_cls.init)  ->  type_obj (actual Python type)
                                        |
                                 getattr(type_obj, '__name__', str(type_obj))
                                        |
                                   type_name: str  (e.g. "User")
```

**Problem:** The actual `type_obj` (the Python class for `User`) is discarded. Only the string name `"User"` is returned. This is where the type information is lost.

### Stage 2: Parameter Creation (`create_walker_parameters`)
**File:** `jac-scale/jac_scale/impl/serve.endpoints.impl.jac:49-89`

Creates `APIParameter` objects with `data_type: str = "User"`. The `APIParameter.data_type` field is a plain string -- there's no way to carry the actual type object.

### Stage 3: Type Resolution (`_get_python_type`)
**File:** `jac-scale/jac_scale/jserver/impl/jfast_api.impl.jac:188-208`

Maps type strings to Python types via a hardcoded dictionary:
```python
{'str': str, 'int': int, 'float': float, 'bool': bool, 'list': list, 'dict': dict, 'object': dict}
```
`"User"` is not in this map, so it defaults to `str`.

### Stage 4: Pydantic Model Generation (`generate_body_model`)
**File:** `jac-scale/jac_scale/jserver/impl/jfast_api.impl.jac:282-313`

Calls `_get_python_type(param.data_type)` to get the Python type, then uses `create_model('RequestBody', **fields)` to build a dynamic Pydantic model. Since `User` resolved to `str`, the generated model is wrong.

---

## Jac Object Runtime Representation

Understanding how Jac `obj` types exist at runtime is critical:

- Jac `obj` compiles to a Python class inheriting from `ObjectArchetype` (defined in `jac/jaclang/jac0core/archetype.jac:227`)
- `ObjectArchetype` extends `Archetype`, which is a dataclass-like construct
- Each `obj` gets a synthesized `init` method with typed parameters matching `has` fields
- **Type hints are available** via `get_type_hints(UserClass.init)` at runtime
- **Field inspection** works via `inspect.signature(UserClass.init)`

This means we can recursively introspect any custom `obj` type to discover its fields and their types -- the same way `introspect_walker` works for walkers.

---

## Relationship to PR #5387 (ref_mode Serializer)

PR #5387 adds `ref_mode` to the serializer to handle circular/shared references during serialization via `{"$ref": "<uuid>", "$type": "<type>"}` placeholders.

**How this relates:** The ref_mode serializer already solves the output side -- when a walker *returns* data containing custom objects, circular references are handled. Our task is the **input side**: making FastAPI understand custom objects as request body parameters, generating correct OpenAPI schemas, and deserializing incoming JSON into proper Jac object instances.

The `$ref`/`$type` pattern from PR #5387 could be reused on the response model side to handle circular type definitions in OpenAPI schemas (e.g., `obj TreeNode { has children: list[TreeNode]; }`).

---

## Proposed Approach

### Design Principles
1. **Preserve actual type objects** through the pipeline instead of just strings
2. **Recursively generate Pydantic models** from Jac `obj` definitions
3. **Cache generated models** to handle recursive types and avoid duplication
4. **Minimal surface area** -- change only what's necessary in each stage

### Change 1: Extend `introspect_walker` to return type objects

**File:** `jac/jaclang/runtimelib/impl/server.impl.jac`

The introspector currently discards the `type_obj`. We need to preserve it:

```python
# Before:
fields[name] = {
    'type': type_name,
    'required': ...,
    'default': ...
}

# After:
fields[name] = {
    'type': type_name,
    'type_obj': type_obj,    # <-- NEW: preserve the actual type
    'required': ...,
    'default': ...
}
```

This is backward-compatible -- existing code that reads `['type']` still works. The new `type_obj` key is optional and only used by consumers that need it.

### Change 2: Extend `APIParameter` to carry the type object

**File:** `jac-scale/jac_scale/jserver/jserver.jac`

```jac
obj APIParameter {
    has name: str,
        `type: ParameterType = ParameterType.QUERY,
        data_type: str = 'str',
        type_obj: (type[Any] | None) = None,   // <-- NEW
        required: bool = True,
        `default: Any = None,
        description: str = '';
}
```

### Change 3: Pass `type_obj` through `create_walker_parameters`

**File:** `jac-scale/jac_scale/impl/serve.endpoints.impl.jac`

When creating `APIParameter`, also pass the `type_obj` from introspection:

```python
parameters.append(APIParameter(
    name=field_name,
    data_type=field_type,
    type_obj=walker_fields[field_name].get('type_obj'),  # <-- NEW
    required=...,
    ...
))
```

### Change 4: Build Pydantic models from Jac `obj` types

**File:** `jac-scale/jac_scale/jserver/impl/jfast_api.impl.jac`

This is the core change. Enhance `_get_python_type` (or add a new method) to handle custom objects:

```python
def _resolve_type(self, type_string: str, type_obj: type | None = None) -> type:
    # 1. Try the existing primitive mapping first
    primitive = self._primitive_type_map.get(type_string.lower())
    if primitive:
        return primitive

    # 2. If we have the actual type object, check if it's a Jac obj
    if type_obj is not None and _is_jac_object(type_obj):
        return self._build_pydantic_model(type_obj)

    # 3. Handle generic types: list[User], dict[str, User], Optional[User]
    origin = getattr(type_obj, '__origin__', None)
    if origin is list:
        args = get_args(type_obj)
        inner = self._resolve_type(str(args[0]), args[0]) if args else Any
        return list[inner]
    if origin is dict:
        args = get_args(type_obj)
        k = self._resolve_type(str(args[0]), args[0]) if args else str
        v = self._resolve_type(str(args[1]), args[1]) if len(args) > 1 else Any
        return dict[k, v]
    # Union / Optional
    if origin is Union:
        resolved_args = tuple(self._resolve_type(str(a), a) for a in get_args(type_obj))
        return Union[resolved_args]

    # 4. Fallback
    return str
```

The key new method -- `_build_pydantic_model` -- dynamically creates a Pydantic model from a Jac `obj`:

```python
def _build_pydantic_model(self, jac_cls: type) -> type[BaseModel]:
    model_name = jac_cls.__name__

    # Return cached model if already built (handles recursive types)
    if model_name in self._models:
        return self._models[model_name]

    # Register a forward-ref placeholder to handle circular references
    # (Inspired by PR #5387's approach to circular graphs)
    placeholder = create_model(model_name)
    self._models[model_name] = placeholder

    # Introspect the Jac obj's fields
    sig = inspect.signature(jac_cls.init)
    type_hints = get_type_hints(jac_cls.init)

    fields = {}
    for name, param in sig.parameters.items():
        if name == 'self':
            continue
        field_type_obj = type_hints.get(name, str)
        resolved_type = self._resolve_type(
            getattr(field_type_obj, '__name__', str(field_type_obj)),
            field_type_obj
        )
        if param.default != inspect.Parameter.empty:
            fields[name] = (resolved_type, Field(param.default))
        else:
            fields[name] = (resolved_type, Field(...))

    # Build the real model and replace the placeholder
    real_model = create_model(model_name, **fields)
    self._models[model_name] = real_model
    return real_model
```

### Change 5: Update `JSONBodyParameterHandler.generate_body_model`

Use `_resolve_type` instead of `_get_python_type`, passing the `type_obj`:

```python
# Before:
param_type = self.type_converter._get_python_type(param.data_type)

# After:
param_type = self.type_converter._resolve_type(param.data_type, param.type_obj)
```

### Change 6: Deserialize incoming JSON to Jac objects

When FastAPI receives the request, the Pydantic model validates the JSON, but the walker callback needs actual Jac `obj` instances -- not Pydantic model instances or dicts.

In `_create_endpoint_function`, after extracting body data, convert Pydantic models back to Jac objects:

```python
# In the generated endpoint wrapper, after extracting from body_data:
for param in body_params:
    if param.type_obj and _is_jac_object(param.type_obj):
        raw = getattr(body_data, param.name)
        callback_args[param.name] = _pydantic_to_jac(raw, param.type_obj)
```

The `_pydantic_to_jac` helper recursively constructs Jac objects:

```python
def _pydantic_to_jac(data, jac_cls):
    if isinstance(data, BaseModel):
        data = data.model_dump()
    if isinstance(data, dict):
        # Introspect jac_cls to get field types for nested conversion
        hints = get_type_hints(jac_cls.init)
        kwargs = {}
        for key, value in data.items():
            field_type = hints.get(key)
            if field_type and _is_jac_object(field_type):
                kwargs[key] = _pydantic_to_jac(value, field_type)
            else:
                kwargs[key] = value
        return jac_cls(**kwargs)
    return data
```

---

## Helper: `_is_jac_object`

A utility to detect whether a type is a Jac `obj`:

```python
def _is_jac_object(cls):
    """Check if cls is a Jac obj/node/edge/walker archetype (not a built-in)."""
    try:
        return (
            isinstance(cls, type)
            and issubclass(cls, Archetype)
            and not getattr(cls, '__jac_base__', False)
        )
    except TypeError:
        return False
```

The `__jac_base__` check excludes base archetypes (Root, GenericEdge, etc.) so we only generate models for user-defined types.

---

## Handling Edge Cases

### 1. Recursive / Self-referencing Types
```jac
obj TreeNode {
    has value: str;
    has children: list[TreeNode];
}
```

**Solution:** The model cache (`self._models`) with placeholder registration handles this. When `_build_pydantic_model` encounters `TreeNode` while building `TreeNode`, it returns the placeholder. Pydantic's `model_rebuild()` can resolve forward references after all models are registered.

### 2. Optional Custom Objects
```jac
walker mywalker {
    has user: User | None = None;
}
```

**Solution:** The `_resolve_type` method handles `Union` types (which `X | None` desugars to). It resolves each union member individually, so `User` gets converted to a Pydantic model and the result is `Optional[UserModel]`.

### 3. Collections of Custom Objects
```jac
walker mywalker {
    has users: list[User];
    has lookup: dict[str, User];
}
```

**Solution:** The `_resolve_type` method handles `list[X]` and `dict[K, V]` generics by recursively resolving type arguments.

### 4. Nested Custom Objects
```jac
obj Address {
    has street: str;
    has city: str;
}
obj User {
    has name: str;
    has address: Address;
}
walker mywalker {
    has user: User;
}
```

**Solution:** `_build_pydantic_model` calls `_resolve_type` for each field, which recursively builds Pydantic models for nested `obj` types. The expected schema:
```json
{
  "user": {
    "name": "string",
    "address": {
      "street": "string",
      "city": "string"
    }
  }
}
```

### 5. Node/Edge/Walker Types as Parameters
```jac
walker mywalker {
    has target_node: MyNode;
}
```

**Decision:** Node/Edge/Walker archetypes should probably NOT be expanded into Pydantic models (they have internal Jac machinery like anchors, paths, etc.). Instead, they should be accepted as their serialized ID (string UUID) and resolved from the context memory. This aligns with PR #5387's `$ref` pattern.

### 6. Enum Types
```jac
enum Color { RED, GREEN, BLUE }
walker mywalker {
    has color: Color;
}
```

**Solution:** Detect Python `Enum` subclasses in `_resolve_type` and pass them directly to Pydantic (which has native Enum support).

---

## Files to Modify

| File | Change | Risk |
|------|--------|------|
| `jac/jaclang/runtimelib/impl/server.impl.jac` | Add `type_obj` to introspection output | Low -- additive, backward-compatible |
| `jac-scale/jac_scale/jserver/jserver.jac` | Add `type_obj` field to `APIParameter` | Low -- optional field with default |
| `jac-scale/jac_scale/impl/serve.endpoints.impl.jac` | Pass `type_obj` when creating parameters | Low -- straightforward plumbing |
| `jac-scale/jac_scale/jserver/impl/jfast_api.impl.jac` | Add `_resolve_type`, `_build_pydantic_model`, `_pydantic_to_jac`; update `generate_body_model` | **Medium** -- core logic change |
| `jac-scale/jac_scale/jserver/jfast_api.jac` | Add method declarations for new methods | Low -- interface update |

---

## Implementation Order

1. **Introspector change** (return `type_obj`) -- enables everything downstream
2. **APIParameter extension** (add `type_obj` field) -- data structure update
3. **Parameter creation plumbing** (pass `type_obj` through) -- connects 1 to 4
4. **`_resolve_type` + `_build_pydantic_model`** -- core Pydantic model generation
5. **Update `generate_body_model`** to use `_resolve_type` -- activates for JSON body
6. **`_pydantic_to_jac` deserialization** -- converts validated input back to Jac objects
7. **Tests** -- walker with custom obj, nested obj, list[obj], optional obj, recursive obj

---

## Why This Approach

- **Preserves type objects** rather than trying to reconstruct them from strings (which is fragile and requires a type registry)
- **Uses Pydantic's own `create_model`** for dynamic model generation, which is the idiomatic FastAPI approach and automatically generates correct OpenAPI schemas
- **Model caching** handles recursive types and avoids duplicate model generation
- **Minimal changes to the introspector** (additive only) means no risk to other consumers
- **Deserialization step** ensures walker callbacks receive actual Jac objects, not raw dicts
- **Builds on PR #5387's patterns**: model caching mirrors the `_seen` set approach; the node/edge `$ref` handling aligns with ref_mode serialization for round-trip consistency
