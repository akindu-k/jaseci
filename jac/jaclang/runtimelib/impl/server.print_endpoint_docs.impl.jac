"""Print comprehensive documentation for all endpoints that would be generated."""
impl print_endpoint_docs(server: JacAPIServer) -> None {
    server.introspector.load();
    functions = server.introspector.get_functions();
    walkers = server.introspector.get_walkers();
    client_exports = server.introspector._client_manifest.get('exports', []);
    """Print section header.""";
    def section(title: str, auth: str = '') -> None {
        print(f"{title}{f' ({auth})' if auth else ''}{('-' * 80)}");
    }
    """Print endpoint with description.""";
    def endpoint(method: str, path: str, desc: str, details: str = '') -> None {
        print(f"{method:6} {path}");
        print(f"       {desc}");
        if details {
            print(f"       {details}");
        }
    }
    """Format parameter info.""";
    def format_param(name: str, info: dict[(str, Any)]) -> str {
        req = 'required' if info['required'] else 'optional';
        <>default = f", default: {info['default']}" if info.get('default') else '';
        return f"{name}: {info['type']} ({req}{default})";
    }
    print(('\n' + ('=' * 80)));
    print(f"JAC API SERVER - {server.module_name}");
    print(('=' * 80));
    section('AUTHENTICATION');
    endpoint(
        'POST',
        '/user/register',
        'Create new user account',
        'Body: { "username": str, "password": str }'
    );
    endpoint(
        'POST',
        '/user/login',
        'Authenticate and get token',
        'Body: { "username": str, "password": str }'
    );
    section('INTROSPECTION', 'Authenticated');
    endpoint('GET', '/functions', 'List all functions → string[]');
    endpoint('GET', '/walkers', 'List all walkers → string[]');
    if functions {
        section('FUNCTIONS', 'Authenticated');
        for (name, func) in functions.items() {
            sig = server.introspector.introspect_callable(func);
            params = [format_param(n, i) for (n, i) in sig['parameters'].items()];
            params_str = ', '.join(params) if params else 'none';
            endpoint('GET', f"/function/{name}", 'Get signature');
            endpoint(
                'POST',
                f"/function/{name}",
                f"Call function → {sig['return_type']}",
                f"Args: {{ {params_str} }}" if params else 'No arguments'
            );
        }
    }
    if walkers {
        section('WALKERS', 'Authenticated');
        for (name, walker_cls) in walkers.items() {
            info = server.introspector.introspect_walker(walker_cls);
            fields = [format_param(n, i) for (n, i) in info['fields'].items()];
            fields_str = ', '.join(fields[:3]);
            if (len(fields) > 3) {
                fields_str += f", ... (+{(len(fields) - 3)} more)";
            }
            endpoint('GET', f"/walker/{name}", 'Get walker fields');
            endpoint(
                'POST',
                f"/walker/{name}",
                'Spawn walker',
                f"Fields: {{ {fields_str} }}" if fields else 'No fields'
            );
        }
    }
    config = get_config();
    cl_route_prefix = config.serve.cl_route_prefix if config else "cl";
    base_route_app = config.serve.base_route_app if config else "";
    section('CLIENT PAGES', 'Public');
    if client_exports {
        funcs_list = ', '.join(sorted(client_exports)[:8]);
        if (len(client_exports) > 8) {
            funcs_list += f" (+{(len(client_exports) - 8)} more)";
        }
        print(f"Available ({len(client_exports)}): {funcs_list}");
        endpoint(
            'GET',
            f'/{cl_route_prefix}/<name>',
            'Render HTML for client function',
            f'Example: /{cl_route_prefix}/App?arg1=value1'
        );
    } else {
        print(
            "\nNo client functions. Define with 'cl def' for browser-side rendering."
        );
    }
    section('STATIC');
    if base_route_app {
        endpoint('GET', '/', f'Serves client app: {base_route_app}');
    } else {
        endpoint('GET', '/', 'API information and endpoint list');
    }
    endpoint('GET', '/static/client.js', 'Client JavaScript bundle');
    total = 2 + 2 + (len(functions) * 2) + (len(walkers) * 2) + 2;
    print(('\n' + ('=' * 80)));
    print(
        f"TOTAL: {len(functions)} functions · {len(walkers)} walkers · {len(
            client_exports
        )} client functions · {total} endpoints"
    );
    print(('=' * 80));
    print('\nAuth: Bearer token (Authorization: Bearer <token>)\n');
}
