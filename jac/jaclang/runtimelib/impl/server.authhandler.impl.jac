"""Create new user."""
impl AuthHandler.create_user(username: str, password: str) -> Response {
    if (not username or not password) {
        return Response(status=400, body={'error': 'Username and password required'});
    }
    result = self.user_manager.create_user(username, password);
    if ('error' in result) {
        return Response(status=400, body=result);
    }
    return Response(status=201, body=result);
}

"""Authenticate user."""
impl AuthHandler.login(username: str, password: str) -> Response {
    if (not username or not password) {
        return Response(status=400, body={'error': 'Username and password required'});
    }
    result = self.user_manager.authenticate(username, password);
    if not result {
        return Response(status=401, body={'error': 'Invalid credentials'});
    }
    return Response(status=200, body=result);
}