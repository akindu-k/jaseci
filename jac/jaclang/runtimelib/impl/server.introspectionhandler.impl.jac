"""List all functions."""
impl IntrospectionHandler.list_functions -> Response {
    self.introspector.load();
    return Response(
        status=200,
        body={'functions': <>list(self.introspector.get_functions().keys())}
    );
}

"""List all walkers."""
impl IntrospectionHandler.list_walkers -> Response {
    self.introspector.load();
    return Response(
        status=200, body={'walkers': <>list(self.introspector.get_walkers().keys())}
    );
}

"""Get function signature."""
impl IntrospectionHandler.get_function_info(name: str) -> Response {
    self.introspector.load();
    functions = self.introspector.get_functions();
    if (name not in functions) {
        return Response(status=404, body={'error': f"Function '{name}' not found"});
    }
    signature = self.introspector.introspect_callable(functions[name]);
    return Response(status=200, body={'name': name, 'signature': signature});
}

"""Get walker info."""
impl IntrospectionHandler.get_walker_info(name: str) -> Response {
    self.introspector.load();
    walkers = self.introspector.get_walkers();
    if (name not in walkers) {
        return Response(status=404, body={'error': f"Walker '{name}' not found"});
    }
    info = self.introspector.introspect_walker(walkers[name]);
    return Response(status=200, body={'name': name, 'info': info});
}