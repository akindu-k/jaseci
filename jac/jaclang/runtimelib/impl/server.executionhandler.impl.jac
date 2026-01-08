"""Call a function."""
impl ExecutionHandler.call_function(
    name: str, args: dict[(str, Any)], username: str
) -> Response {
    self.introspector.load();
    functions = self.introspector.get_functions();
    if (name not in functions) {
        return Response(status=404, body={'error': f"Function '{name}' not found"});
    }
    result = self.execution_manager.execute_function(functions[name], args, username);
    return Response(status=200, body=result);
}

"""Spawn a walker."""
impl ExecutionHandler.spawn_walker(
    name: str, fields: dict[(str, Any)], username: str
) -> Response {
    self.introspector.load();
    walkers = self.introspector.get_walkers();
    if (name not in walkers) {
        return Response(status=404, body={'error': f"Walker '{name}' not found"});
    }
    result = self.execution_manager.spawn_walker(walkers[name], fields, username);
    return Response(status=200, body=result);
}