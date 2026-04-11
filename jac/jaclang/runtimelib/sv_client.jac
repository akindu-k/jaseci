"""Runtime client for sv-to-sv microservice calls.

When a Jac server module does sv import from another_module { func },
the compiler generates HTTP stub functions that call into this module
to route the request to the provider service.

The wire contract is identical to cl-to-sv interop:
  POST /function/{name}
  Body: JSON dict of kwargs
  Response: TransportResponse envelope {ok, data, error, meta}
"""

import os;
import from typing { Any }

# Module name -> base URL (set by jac start orchestration or test code)
glob _registry: dict[str, str] = {},
     # Module name -> TestClient instance (set by tests for in-process routing)
     _test_clients: dict[str, Any] = {};

"""Register a service URL for sv-to-sv resolution."""
def register(module_name: str, url: str) {
    _registry[module_name] = url;
}

"""Remove a service registration."""
def unregister(module_name: str) {
    if module_name in _registry {
        del _registry[module_name];
    }
}

"""Register an in-process TestClient for a service (testing only)."""
def register_test_client(module_name: str, client: Any) {
    _test_clients[module_name] = client;
}

"""Remove a TestClient registration."""
def unregister_test_client(module_name: str) {
    if module_name in _test_clients {
        del _test_clients[module_name];
    }
}

"""Clear all TestClient registrations (between tests)."""
def clear_test_clients {
    _test_clients.clear();
}

"""Resolve a service URL via registry or environment."""
def resolve_url(module_name: str) -> str {
    if module_name in _registry {
        return _registry[module_name];
    }
    env_var = f"JAC_SV_{module_name.upper()}_URL";
    if env_var in os.environ {
        return os.environ[env_var];
    }
    raise RuntimeError(
        f"sv-to-sv service '{module_name}' not registered. " + f"Set {env_var} or call sv_client.register()."
    );
}

"""Lazily ensure a service is available, invoking the plugin hook if needed.

Resolution order:
  1. TestClient registered via register_test_client()
  2. URL registered via register()
  3. JAC_SV_{MODULE}_URL environment variable
  4. JacAPIServer.ensure_sv_service() plugin hook (default: spawn local server)
"""
def _ensure_available(module_name: str) -> None {
    if module_name in _test_clients {
        return;
    }
    if module_name in _registry {
        return;
    }
    env_var = f"JAC_SV_{module_name.upper()}_URL";
    if env_var in os.environ {
        register(module_name, os.environ[env_var]);
        return;
    }
    import jaclang;
    base_path = getattr(jaclang.JacRuntime, 'base_path_dir', None) or '.';
    jaclang.JacRuntime.ensure_sv_service(module_name, base_path);
}

"""Make an sv-to-sv RPC call.

Resolution order:
  1. TestClient registered via register_test_client()
  2. URL registered via register()
  3. JAC_SV_{MODULE}_URL environment variable
  4. JacAPIServer.ensure_sv_service() plugin hook on cache miss

Returns the unwrapped result from the TransportResponse envelope.
Raises RuntimeError on failure.
"""
def call(module_name: str, func_name: str, args: dict) -> Any {
    _ensure_available(module_name);
    if module_name in _test_clients {
        resp = _test_clients[module_name].post(f"/function/{func_name}", json=args);
        data = resp.json();
    } else {
        url = resolve_url(module_name);
        try {
            import httpx;
        } except ImportError {
            raise RuntimeError(
                "httpx is required for sv-to-sv RPC calls. " + "Install it via `pip install httpx`."
            );
        }
        resp = httpx.post(f"{url}/function/{func_name}", json=args);
        data = resp.json();
    }

    if isinstance(data, dict) and data.get("ok") {
        result_envelope = data.get("data");
        if isinstance(result_envelope, dict) and ("result" in result_envelope) {
            return result_envelope["result"];
        }
        return result_envelope;
    }

    err = (data.get("error") if isinstance(data, dict) else None) or {};
    msg = err.get("message") if isinstance(err, dict) else str(err);
    raise RuntimeError(
        f"sv-to-sv RPC '{module_name}.{func_name}' failed: {msg or 'unknown error'}"
    );
}
