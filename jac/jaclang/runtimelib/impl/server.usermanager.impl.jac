impl UserManager.postinit -> None {
    self._db_path = f"{self.session_path}.users.json";
    self._load_db();
}

"""Load user data from persistent storage."""
impl UserManager._load_db -> None {
    try {
        with open(self._db_path, encoding='utf-8') as fh {
            data = json.load(fh);
            self._users = data.get('__jac_users__', {});
            self._tokens = data.get('__jac_tokens__', {});
        }
    } except Exception {
        (self._users, self._tokens) = ({}, {});
    }
}

"""Save user data to persistent storage."""
impl UserManager._persist -> None {
    with open(self._db_path, 'w', encoding='utf-8') as fh {
        json.dump({'__jac_users__': self._users, '__jac_tokens__': self._tokens}, fh);
    }
}

"""Create a new user with their own root node. Returns dict with user data or error."""
impl UserManager.create_user(username: str, password: str) -> dict[str, str] {
    import from jaclang.pycore.constructs { Root }
    if (username in self._users) {
        return {'error': 'User already exists'};
    }
    # Use existing context instead of creating new one (avoids shelf locking issues)
    ctx = Jac.get_context();
    user_root = Root();
    root_anchor = user_root.__jac__;
    Jac.save(root_anchor);
    Jac.commit(root_anchor);
    root_id = root_anchor.id.hex;
    token = secrets.token_urlsafe(32);
    password_hash = hashlib.sha256(password.encode()).hexdigest();
    self._users[username] = {
        'password_hash': password_hash,
        'token': token,
        'root_id': root_id
    };
    self._tokens[token] = username;
    self._persist();
    return {'username': username, 'token': token, 'root_id': root_id};
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