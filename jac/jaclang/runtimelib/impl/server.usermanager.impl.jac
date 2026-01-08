impl UserManager._find_user_by_username(username: str) -> (User | None) {
    for anc in self.memory.query(
        filter=lambda a: isinstance(a, NodeAnchor)
                            and isinstance(a.archetype, User)
                            and a.archetype.username == username
    ) {
        return anc.archetype;
    }
    return None;
}

"""Create a new user with their own root node. Returns dict with user data or error."""
impl UserManager.create_user(username: str, password: str) -> dict[str, str] {
    import from jaclang.pycore.constructs { Root }

    if (self._find_user_by_username(username)){
        return {'error': 'User already exists'};
    }
    # Use existing context instead of creating new one (avoids shelf locking issues)
    ctx = Jac.get_context();
    user_root = Root();
    root_anchor = user_root.__jac__;
    Jac.save(root_anchor);
    Jac.commit(root_anchor);

    user = User(
        username=username,
        password_hash=hashlib.sha256(password.encode()).hexdigest(),
        token = secrets.token_urlsafe(32),
        root_id = root_anchor.id.hex;
    );
    
    user_anchor = user.__jac__;
    Jac.save(user_anchor);
    Jac.commit(user_anchor);

    return {
        "username" : username,
        "token" : user.token,
        "root_id" : root_anchor.id.hex
    };


}

"""Authenticate a user and return their data."""
impl UserManager.authenticate(
    username: str, password: str
) -> (dict[(str, str)] | None) {
    if (username not in self._users) {
        return None;
    }
    user = self._users[username];
    password_hash = hashlib.sha256(password.encode()).hexdigest();
    if (user['password_hash'] == password_hash) {
        return {
            'username': username,
            'token': user['token'],
            'root_id': user['root_id']
        };
    }
    return None;
}

"""Validate token and return username."""
impl UserManager.validate_token(token: str) -> (str | None) {
    return self._tokens.get(token);
}

"""Get user's root node ID."""
impl UserManager.get_root_id(username: str) -> (str | None) {
    return self._users[username]['root_id'] if (username in self._users) else None;
}

"""Get user data by username."""
impl UserManager.get_user(username: str) -> (dict[(str, str)] | None) {
    if (username not in self._users) {
        return None;
    }
    user = self._users[username];
    return {'email': username, 'token': user['token'], 'root_id': user['root_id']};
}

"""Close and persist user data."""
impl UserManager.close -> None {
    self._persist();
}