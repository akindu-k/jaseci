# Microservices with `sv import`

A Jac codebase can run as a single monolith or as several independently-deployed microservices, with no source changes between the two. The trick is the `sv import` keyword: when both the importer and the importee are server-context modules, the compiler generates an HTTP client stub for the imported function instead of pulling the provider into the consumer's process. Calls become RPCs over the wire, but the source still reads like a normal import.

This tutorial walks through splitting a tiny app into two services and watching the round-trip happen, then shows how to point the consumer at a real provider URL and how to test the boundary in-process.

> **Prerequisites**
>
> - Completed: [Local API Server](local.md)
> - Time: ~20 minutes
> - Reference: [Microservice Interop in jac-scale](../../reference/plugins/jac-scale.md#microservice-interop-sv-to-sv)

---

## Overview

Two services, two `jac start` processes, one HTTP boundary between them. The consumer's `sv import` looks identical to a regular import, but every call out to the provider is a `POST /function/<name>` over the wire.

```mermaid
graph LR
    Client["Client<br/>(curl, browser)"] -- "POST /function/sum_list" --> Calc["calculator_service<br/>jac start :8002"]
    Calc -- "POST /function/add (x5)" --> Math["math_service<br/>jac start :8001"]
    Math -- "result" --> Calc
    Calc -- "result" --> Client
```

The consumer never imports the provider into its own process. After the call, the consumer's `sys.modules` does not contain `math_service`.

---

## 1. Set Up the Project

Create a working directory with a `jac.toml` so `jac start` recognizes it as a project. The two services live side by side in the same directory.

```bash
mkdir microservices-demo && cd microservices-demo
cat > jac.toml <<'EOF'
[project]
name = "microservices-demo"
version = "0.1.0"
EOF
```

> **Why `jac.toml`?** `jac start <relative-path>` requires a `jac.toml` in the current directory. Without one, you get `Error: No jac.toml found`. You can also pass an absolute path to `jac start`, but the auto-spawn fallback (covered later) needs both services to live in the same directory anyway, so a project layout is the simplest path.

---

## 2. Create the Provider

`math_service.jac` exposes three public functions and one boundary type.

```jac
# math_service.jac
obj DivResult {
    has result: float | None = None,
        error: str = "";
}

def:pub add(a: int, b: int) -> int {
    return a + b;
}

def:pub multiply(a: int, b: int) -> int {
    return a * b;
}

def:pub divide(a: float, b: float) -> DivResult {
    if b == 0.0 {
        return DivResult(error="division by zero");
    }
    return DivResult(result=a / b);
}
```

The `def:pub` modifier is required: only public functions get registered as `/function/<name>` endpoints, and the consumer's generated stub will 404 against anything else. `DivResult` is a boundary type -- it crosses the wire as JSON and gets re-hydrated on the consumer side.

---

## 3. Create the Consumer

`calculator_service.jac` imports from the provider with `sv import` and uses the imported functions like ordinary local calls.

```jac
# calculator_service.jac
sv import from math_service { add, multiply, divide, DivResult }

def:pub sum_list(numbers: list[int]) -> int {
    result = 0;
    for n in numbers {
        result = add(result, n);  # HTTP call to math_service
    }
    return result;
}

def:pub dot_product(a: list[int], b: list[int]) -> int {
    result = 0;
    for i in range(len(a)) {
        result = add(result, multiply(a[i], b[i]));
    }
    return result;
}

def:pub safe_divide(a: float, b: float) -> DivResult {
    return divide(a, b);  # boundary type round-trips
}
```

Read this file as if `add`, `multiply`, and `divide` were local functions. The compiler swaps them out for HTTP stubs at compile time, but the call site does not change.

---

## 4. Run Both Services

Open two terminals, both in the `microservices-demo` directory.

**Terminal 1 -- start the provider:**

```bash
jac start math_service.jac --port 8001
```

**Terminal 2 -- start the consumer with the provider URL:**

```bash
JAC_SV_MATH_SERVICE_URL=http://localhost:8001 \
    jac start calculator_service.jac --port 8002
```

The `JAC_SV_<UPPERCASED_MODULE>_URL` env var tells the consumer where to find the named provider. The module name is exactly what you wrote after `sv import from`, upper-cased.

> **Avoid ports 18000-18999.** That range is reserved for the auto-spawn fallback (next section). Pick something in the 8000s for explicit external ports.

---

## 5. Watch the Round-Trip

From a third terminal, exercise the consumer:

```bash
# Cross-service: 5 add() calls under the hood
curl -X POST http://localhost:8002/function/sum_list \
  -H "Content-Type: application/json" \
  -d '{"numbers":[1,2,3,4,5]}'
```

```json
{"ok":true,"data":{"result":15,"reports":[]},"error":null,"meta":{"extra":{"http_status":200}}}
```

Now look at the **provider** terminal -- you will see five `POST /function/add` lines, one per iteration of the consumer's loop:

```text
Executing function 'add' with params: {'a': 0, 'b': 1}
  127.0.0.1:41112 - "POST /function/add HTTP/1.1" 200
Executing function 'add' with params: {'a': 1, 'b': 2}
  127.0.0.1:41124 - "POST /function/add HTTP/1.1" 200
...
```

That is the proof: the consumer's loop is fanning out to the provider on each iteration. The two services are real processes talking over real HTTP.

### Boundary Type Round-Trip

`safe_divide` returns a `DivResult` from the provider, which the consumer hands back to its own caller. The compiler generates a Python stub class for `DivResult` on the consumer side with `from_wire` / `to_wire` helpers, so the wrapped object behaves like a normal `obj` instance.

```bash
curl -X POST http://localhost:8002/function/safe_divide \
  -H "Content-Type: application/json" \
  -d '{"a":10.0,"b":2.0}'
```

```json
{"ok":true,"data":{"result":{"_jac_type":"DivResult","error":"","result":5.0},"reports":[]},...}
```

```bash
curl -X POST http://localhost:8002/function/safe_divide \
  -H "Content-Type: application/json" \
  -d '{"a":10.0,"b":0.0}'
```

```json
{"ok":true,"data":{"result":{"_jac_type":"DivResult","error":"division by zero","result":null},"reports":[]},...}
```

Both error and success cases survive the boundary intact. The `_jac_type` metadata lets the consumer's runtime hand the caller a real `DivResult` instance, not a raw dict.

---

## 6. Auto-Spawn Fallback (Prototyping)

For fast local iteration you can skip the second `jac start` entirely. If no `JAC_SV_*_URL` env var is set, the consumer's first call to a missing service triggers `JacAPIServer.ensure_sv_service`, which spawns the provider as a background daemon thread inside the consumer process and registers it under `127.0.0.1` on a port in the 18000-18999 range.

Stop both services from the previous step, clear any leftover state, and start only the consumer:

```bash
rm -rf .jac/data/
jac start calculator_service.jac --port 8002
```

Now hit `sum_list` again:

```bash
curl -X POST http://localhost:8002/function/sum_list \
  -H "Content-Type: application/json" \
  -d '{"numbers":[1,2,3]}'
```

```json
{"ok":true,"data":{"result":6,"reports":[]},...}
```

The first call takes a fraction of a second longer because the consumer is spawning the sibling listener and polling it for readiness; subsequent calls are direct.

> **The auto-spawned sibling is loopback-only.** It binds `127.0.0.1`, not `0.0.0.0`. That makes it convenient for single-binary local dev and tests, but it cannot serve traffic to other hosts. For real deployments, run each service as its own `jac start` and wire them with `JAC_SV_*_URL` env vars (or [override the plugin hook](../../reference/plugins/jac-scale.md#plugin-hook-ensure_sv_service)).

The auto-spawn fallback also requires both services to live in the same directory: it loads the missing module from the consumer's `base_path_dir`, so `jac start` from the project root works, but `jac start /some/abs/path/calc.jac` from an unrelated cwd does not.

---

## 7. Test the Boundary In-Process

When you write tests for the consumer, you do not want them to hit a real provider over HTTP. Register an in-process `TestClient` instead, and the consumer's stub calls route through it directly.

```jac
# test_microservices.jac
import sys;
import shutil;
import tempfile;
import from pathlib { Path }
import from jaclang { JacRuntime as Jac }
import from jaclang.jac0core.constant { Constants as Con }
import from jaclang.runtimelib { sv_client }
import from starlette.testclient { TestClient }
import from jac_scale.serve { JacAPIServer }

glob HERE: Path = Path(__file__).parent;

def make_server(mod: str, base_path: str) -> TestClient {
    if mod in Jac.loaded_modules { del Jac.loaded_modules[mod]; }
    if mod in sys.modules { del sys.modules[mod]; }
    Jac.jac_import(target=mod, base_path=base_path, lng="jac");
    srv = JacAPIServer(module_name=mod, port=0, base_path=base_path);
    srv.load_module();
    srv.register_health_endpoint();
    srv.register_walkers_endpoints();
    srv.register_functions_endpoints();
    srv.register_create_user_endpoint();
    srv.register_login_endpoint();
    srv.user_manager.create_user(Con.GUEST.value, '__no_password__');
    srv.server.create_server();
    client = TestClient(srv.server.app, raise_server_exceptions=False);
    sv_client.register_test_client(mod, client);
    return client;
}

test "calculator routes through math via TestClient" {
    tmp = tempfile.mkdtemp();
    try {
        shutil.copy2(HERE / "math_service.jac", Path(tmp) / "math_service.jac");
        shutil.copy2(HERE / "calculator_service.jac", Path(tmp) / "calculator_service.jac");
        Jac.set_base_path(tmp);
        Jac.set_context(Jac.create_j_context(user_root=None));
        sv_client.clear_test_clients();

        prov = make_server("math_service", tmp);
        cons = make_server("calculator_service", tmp);

        resp = cons.post(
            "/function/sum_list", json={"numbers": [1, 2, 3, 4, 5]}
        ).json();
        assert resp["ok"] is True;
        assert resp["data"]["result"] == 15;
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}
```

```bash
python -m pytest test_microservices.jac -v
```

Always call `sv_client.clear_test_clients()` between tests to avoid bleed-over from a previous test's registration. With `register_test_client` in place, no real HTTP, port allocation, or background threads are involved -- everything runs in-process through the ASGI test app, which makes the suite fast and deterministic.

---

## 8. Going to Production

For real deployments, each service runs as its own `Deployment` (or VM, container, systemd unit) and the consumer is told where the provider lives via `JAC_SV_*_URL`.

### Kubernetes

```yaml
# inventory-service: provider
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory-service
spec:
  template:
    spec:
      containers:
      - name: inventory-service
        image: my-registry/inventory-service:latest
        ports:
        - containerPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: inventory-service
spec:
  selector:
    app: inventory-service
  ports:
  - port: 8000
---
# order-service: consumer, points at inventory-service via cluster DNS
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  template:
    spec:
      containers:
      - name: order-service
        image: my-registry/order-service:latest
        env:
        - name: JAC_SV_INVENTORY_SERVICE_URL
          value: "http://inventory-service.default.svc.cluster.local:8000"
```

The convention is `JAC_SV_<UPPERCASED_MODULE_NAME>_URL`. The module name is exactly the value used in `sv import from <module_name>`. Hyphens in module names become underscores; dots stay as dots.

For the full Kubernetes deployment story (image building, ingress, autoscaling), see the [Kubernetes tutorial](kubernetes.md) -- it applies here unchanged, you just deploy each service separately and wire them with env vars.

### Local Multi-Service

The same pattern works locally with shell exports:

```bash
export JAC_SV_INVENTORY_SERVICE_URL=http://localhost:8001
export JAC_SV_MATH_SERVICE_URL=http://localhost:8002
jac start order_service.jac --port 8000
```

Each consumer process picks up its `JAC_SV_*_URL` vars at the moment of the first cross-service call, so you can `export` them in your shell profile or a `.env` file loaded by your dev workflow.

---

## Common Pitfalls

- **`{"detail":"Invalid anchor id ..."}` 500s.** Stale anchor data persisted from a previous run with a different schema. Stop the server, `rm -rf .jac/data/`, and restart. Not specific to sv-to-sv -- any `def:pub` call can hit this after a schema change.
- **`No module named '<provider>'` from the auto-spawn fallback.** The consumer's `base_path_dir` does not contain the provider source. Run the consumer from the project root, or set `JAC_SV_<MODULE>_URL` so the fallback never runs.
- **Stub call returns 404.** The provider function is not declared `def:pub`. Walkers similarly need `walker:pub`.
- **`Error: No jac.toml found`.** `jac start <relative-path>` requires a `jac.toml` in the current directory. Run `jac create` (or just create an empty one), or pass an absolute path.
- **Cross-service errors arrive as `RuntimeError`.** Network failures, missing services, and provider-side error envelopes all surface in the consumer as `RuntimeError("sv-to-sv RPC '{module}.{func}' failed: {msg}")`. Catch them at boundaries where you want graceful degradation.

---

## What You Built

Two services that read like a single program. The split happens at deploy time, not source time -- the same `calculator_service.jac` runs unchanged whether `math_service` is a module in the same process, a sibling thread, a separate `jac start`, or a Kubernetes Deployment two clusters away.

## Next Steps

- [Microservice Interop reference](../../reference/plugins/jac-scale.md#microservice-interop-sv-to-sv) for the resolution chain, `sv_client` API, and plugin hook details.
- [Kubernetes tutorial](kubernetes.md) for the full deployment pipeline that packages each service into its own image.
- [Backend Integration](../fullstack/backend.md) for the cl-to-sv flavor of `sv import`, where a browser client calls a server.
