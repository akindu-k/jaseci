impl JacScaleUserManager.postinit -> None {
    db_config = get_scale_config().get_database_config();
    mongodb_uri = db_config.get('mongodb_uri');

    sso_config = get_scale_config().get_sso_config();
    for platform in Platforms {
        key = platform.value.lower();
        platform_config = sso_config.get(key, {});

        client_id = platform_config.get('client_id', '');
        client_secret = platform_config.get('client_secret', '');

        if not client_id or not client_secret {
            continue;
        }

        self.SUPPORTED_PLATFORMS[platform.value] = {
            "client_id": client_id,
            "client_secret": client_secret
        };
    }

    if mongodb_uri is not None {
        import from jac_scale.db { get_mongo_client }
        client = get_mongo_client();
        self._mongo_db = client['jac_db'];
        self._users_col = self._mongo_db['users'];
        self._sso_col = self._mongo_db['sso_accounts'];

        self._users_col.create_index('username', unique=True);
        self._users_col.create_index('token', unique=True, sparse=True);
        self._sso_col.create_index([('platform', 1), ('external_id', 1)], unique=True);
        self._sso_col.create_index('user_id');

        self._using_mongodb = True;
    } else {
        self._using_mongodb = False;
        self._mongo_db = None;
        self._users_col = None;
        self._sso_col = None;
        super.postinit();
        self._ensure_connection();
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sso_accounts (
                user_id TEXT NOT NULL,
                platform TEXT NOT NULL,
                external_id TEXT NOT NULL,
                email TEXT,
                linked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (platform, external_id),
                FOREIGN KEY (user_id) REFERENCES users(username) ON DELETE CASCADE
            )
            """
        );
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_sso_accounts_user_id ON sso_accounts(user_id)"
        );
        cursor = self._conn.execute("PRAGMA table_info(users)");
        existing_columns = {row[1] for row in cursor.fetchall()};
        if 'role' not in existing_columns {
            self._conn.execute("ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'user'");
        }
        if 'requires_password_reset' not in existing_columns {
            self._conn.execute(
                "ALTER TABLE users ADD COLUMN requires_password_reset INTEGER DEFAULT 0"
            );
        }
        if 'is_password_required' not in existing_columns {
            self._conn.execute(
                "ALTER TABLE users ADD COLUMN is_password_required INTEGER DEFAULT 1"
            );
        }
        if 'user_id' not in existing_columns {
            self._conn.execute("ALTER TABLE users ADD COLUMN user_id TEXT");
        }
        self._conn.commit();
    }
}

"""Override parent's _ensure_connection - call parent only if using SQLite."""
impl JacScaleUserManager._ensure_connection -> None {
    if self._users_col is None {
        super._ensure_connection();
    }
}

"""Create a new user with their own root node. Returns dict with user data or error."""
impl JacScaleUserManager.create_user(username: str, password: str) -> dict[str, str] {
    if self._users_col is None {
        return super.create_user(username, password);
    }
    import from jaclang.jac0core.constructs { Root }
    import from jaclang { JacRuntime as Jac }
    import secrets;

    if self._users_col.count_documents({'username': username}, limit=1) > 0 {
        return {'error': 'User already exists'};
    }
    # Create user root node
    user_root = Root();
    Jac.save(user_root);
    Jac.commit(user_root);
    root_id = user_root.__jac__.id.hex;
    token = secrets.token_urlsafe(32);
    password_hash = hashlib.sha256(password.encode()).hexdigest();
    self._users_col.insert_one(
        {
            'username': username,
            'password_hash': password_hash,
            'token': token,
            'root_id': root_id,
            'role': 'user',
            'requires_password_reset': False,
            'is_password_required': True,
            'user_id': None
        }
    );
    return {'username': username, 'token': token, 'root_id': root_id};
}

"""Authenticate a user and return their data."""
impl JacScaleUserManager.authenticate(
    username: str, password: str
) -> (dict[(str, str)] | None) {
    if self._users_col is None {
        return super.authenticate(username, password);
    }
    password_hash = hashlib.sha256(password.encode()).hexdigest();
    user = self._users_col.find_one(
        {'username': username, 'password_hash': password_hash},
        {'token': 1, 'root_id': 1, '_id': 0}
    );
    if user {
        return {
            'username': username,
            'token': user['token'],
            'root_id': user['root_id']
        };
    }
    return None;
}

"""Validate token and return username."""
impl JacScaleUserManager.validate_token(token: str) -> (str | None) {
    return self.validate_jwt_token(token);
}

"""Get user's root node ID."""
impl JacScaleUserManager.get_root_id(username: str) -> (str | None) {
    if self._users_col is None {
        return super.get_root_id(username);
    }
    user = self._users_col.find_one({'username': username}, {'root_id': 1, '_id': 0});
    return user['root_id'] if user else None;
}

"""Get user data by username."""
impl JacScaleUserManager.get_user(username: str) -> (dict[(str, str)] | None) {
    if self._users_col is None {
        return super.get_user(username);
    }
    user = self._users_col.find_one(
        {'username': username}, {'token': 1, 'root_id': 1, '_id': 0}
    );
    if not user {
        return None;
    }
    return {'email': username, 'token': user['token'], 'root_id': user['root_id']};
}

"""Check if a user exists."""
impl JacScaleUserManager.user_exists(username: str) -> bool {
    if self._users_col is None {
        return super.user_exists(username);
    }
    return self._users_col.count_documents({'username': username}, limit=1) > 0;
}

"""Update user's username."""
impl JacScaleUserManager.update_username(
    current_username: str, new_username: str
) -> dict[str, str] {
    if self._users_col is None {
        return super.update_username(current_username, new_username);
    }
    if self._users_col.count_documents({'username': new_username}, limit=1) > 0 {
        return {'error': 'Username already taken'};
    }
    result = self._users_col.update_one(
        {'username': current_username}, {'$set': {'username': new_username}}
    );
    if result.modified_count == 0 {
        return {'error': 'User not found'};
    }
    # Update SSO references
    self._sso_col.update_many(
        {'user_id': current_username}, {'$set': {'user_id': new_username}}
    );

    user = self._users_col.find_one(
        {'username': new_username}, {'token': 1, 'root_id': 1, '_id': 0}
    );
    return {
        'username': new_username,
        'token': user['token'],
        'root_id': user['root_id']
    };
}

"""Update user's password."""
impl JacScaleUserManager.update_password(
    username: str, current_password: str, new_password: str
) -> dict[str, str] {
    if self._users_col is None {
        return super.update_password(username, current_password, new_password);
    }
    # Verify current password
    current_password_hash = hashlib.sha256(current_password.encode()).hexdigest();
    if self._users_col.count_documents(
        {'username': username, 'password_hash': current_password_hash}, limit=1
    ) == 0 {
        return {'error': 'Current password is incorrect'};
    }
    # Update password
    new_password_hash = hashlib.sha256(new_password.encode()).hexdigest();
    self._users_col.update_one(
        {'username': username}, {'$set': {'password_hash': new_password_hash}}
    );
    return {'username': username, 'message': 'Password updated successfully'};
}

"""Close connection — no-op with MongoDB connection pooling."""
impl JacScaleUserManager.close -> None { }

# ============================================================================
# JWT Methods
# ============================================================================
impl JacScaleUserManager.create_jwt_token(
    username: str, include_role: bool = True
) -> str {
    now = datetime.now(UTC);
    payload: dict[(str, Any)] = {
        'username': username,
        'exp': (now + timedelta(days=JWT_EXP_DELTA_DAYS)),
        'iat': now.timestamp()
    };
    # Include role in JWT claims if requested
    if include_role {
        role = self.get_user_role(username);
        if role {
            payload['role'] = role;
        }
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM);
}

"""Get JWT claims from token without full validation."""
impl JacScaleUserManager.get_jwt_claims(token: str) -> (dict | None) {
    try {
        decoded = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM]);
        return decoded;
    } except Exception {
        return None;
    }
}

impl JacScaleUserManager.validate_jwt_token(token: str) -> (str | None) {
    try {
        decoded = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM]);
        username = decoded['username'];
        if not self.user_exists(username) {
            return None;
        }
        return username;
    } except Exception {
        return None;
    }
}

impl JacScaleUserManager.refresh_jwt_token(token: str) -> (str | None) {
    try {
        decoded = jwt.decode(
            token, JWT_SECRET, algorithms=[JWT_ALGORITHM], options={"verify_exp": True}
        );
        username = decoded.get('username');

        if not username {
            return None;
        }

        return self.create_jwt_token(username);
    } except Exception {
        return None;
    }
}

# ============================================================================
# SSO Methods
# ============================================================================
impl JacScaleUserManager.get_sso(platform: str, operation: str) -> (SSOProvider | None) {
    if (platform not in self.SUPPORTED_PLATFORMS) {
        return None;
    }
    credentials = self.SUPPORTED_PLATFORMS[platform];
    redirect_uri = f"{SSO_HOST}/{platform}/{operation}/callback";
    if (platform == Platforms.GOOGLE.value) {
        import from jac_scale.google_sso_provider { GoogleSSOProvider }
        return GoogleSSOProvider(
            client_id=credentials['client_id'],
            client_secret=credentials['client_secret'],
            redirect_uri=redirect_uri,
            allow_insecure_http=True
        );
    }
    return None;
}

impl JacScaleUserManager.sso_initiate(
    platform: str, operation: str
) -> (Response | TransportResponse) {
    import from jaclang.runtimelib.server { JsonValue }
    if (platform not in [p.value for p in Platforms]) {
        return TransportResponse.fail(
            code='INVALID_PLATFORM',
            message=f"Invalid platform '{platform}'. Supported platforms: {', '.join(
                [p.value for p in Platforms]
            )}",
            meta=Meta(extra={'http_status': 400})
        );
    }
    if (platform not in self.SUPPORTED_PLATFORMS) {
        return TransportResponse.fail(
            code='SSO_NOT_CONFIGURED',
            message=f"SSO for platform '{platform}' is not configured. Please set SSO_{platform.upper()}_CLIENT_ID and SSO_{platform.upper()}_CLIENT_SECRET environment variables.",
            meta=Meta(extra={'http_status': 501})
        );
    }
    if (operation not in [o.value for o in Operations]) {
        return TransportResponse.fail(
            code='INVALID_OPERATION',
            message=f"Invalid operation '{operation}'. Must be 'login' or 'register'",
            meta=Meta(extra={'http_status': 400})
        );
    }
    sso = self.get_sso(platform, operation);
    if not sso {
        return TransportResponse.fail(
            code='SSO_INIT_FAILED',
            message=f"Failed to initialize SSO for platform '{platform}'",
            meta=Meta(extra={'http_status': 500})
        );
    }
    return await sso.initiate_auth(operation);
}

impl JacScaleUserManager.sso_callback(
    request: Request, platform: str, operation: str
) -> TransportResponse {
    import from jaclang.runtimelib.server { JsonValue }
    if (platform not in [p.value for p in Platforms]) {
        return TransportResponse.fail(
            code='INVALID_PLATFORM',
            message=f"Invalid platform '{platform}'. Supported platforms: {', '.join(
                [p.value for p in Platforms]
            )}",
            meta=Meta(extra={'http_status': 400})
        );
    }
    if (platform not in self.SUPPORTED_PLATFORMS) {
        return TransportResponse.fail(
            code='SSO_NOT_CONFIGURED',
            message=f"SSO for platform '{platform}' is not configured. Please set SSO_{platform.upper()}_CLIENT_ID and SSO_{platform.upper()}_CLIENT_SECRET environment variables.",
            meta=Meta(extra={'http_status': 501})
        );
    }
    if (operation not in [o.value for o in Operations]) {
        return TransportResponse.fail(
            code='INVALID_OPERATION',
            message=f"Invalid operation '{operation}'. Must be 'login' or 'register'",
            meta=Meta(extra={'http_status': 400})
        );
    }
    sso = self.get_sso(platform, operation);
    if not sso {
        return TransportResponse.fail(
            code='SSO_INIT_FAILED',
            message=f"Failed to initialize SSO for platform '{platform}'",
            meta=Meta(extra={'http_status': 500})
        );
    }
    try {
        user_info = await sso.handle_callback(request);
        email = user_info.email;
        if not email {
            return TransportResponse.fail(
                code='EMAIL_MISSING',
                message=f"Email not provided by {platform}",
                meta=Meta(extra={'http_status': 400})
            );
        }
        if (operation == Operations.LOGIN.value) {
            user = self.get_user(email);
            if not user {
                return TransportResponse.fail(
                    code='USER_NOT_FOUND',
                    message='User not found. Please register first.',
                    meta=Meta(extra={'http_status': 404})
                );
            }
            token = self.create_jwt_token(email);
            return TransportResponse.success(
                data={
                    'message': 'Login successful',
                    'email': email,
                    'token': token,
                    'platform': platform,
                    'user': dict[(str, JsonValue)](user)
                },
                meta=Meta(extra={'http_status': 200})
            );
        } elif (operation == Operations.REGISTER.value) {
            existing_user = self.get_user(email);
            if existing_user {
                return TransportResponse.fail(
                    code='USER_EXISTS',
                    message='User already exists. Please login instead.',
                    meta=Meta(extra={'http_status': 400})
                );
            }
            random_password = generate_random_password();
            result = self.create_user(email, random_password);
            if ('error' in result) {
                return TransportResponse.fail(
                    code='USER_CREATION_FAILED',
                    message=result.get('error', 'User creation failed'),
                    meta=Meta(extra={'http_status': 400})
                );
            }
            token = self.create_jwt_token(email);
            result['token'] = token;
            result['platform'] = platform;
            return TransportResponse.success(
                data=result, meta=Meta(extra={'http_status': 201})
            );
        }
    } except Exception as e {
        return TransportResponse.fail(
            code='AUTHENTICATION_FAILED',
            message=f"Authentication failed: {str(e)}",
            meta=Meta(extra={'http_status': 500})
        );
    }
    return TransportResponse.fail(
        code='UNKNOWN_ERROR',
        message='An unknown error occurred',
        meta=Meta(extra={'http_status': 500})
    );
}

# ============================================================================
# SSO Account Linking Methods
# ============================================================================
"""Link an SSO account to a user."""
impl JacScaleUserManager.link_sso_account(
    user_id: str, platform: str, external_id: str, email: str
) -> dict[str, str] {
    if self._sso_col is None {
        self._ensure_connection();
        # Check if this SSO account is already linked
        cursor = self._conn.execute(
            "SELECT user_id FROM sso_accounts WHERE platform = ? AND external_id = ?",
            (platform, external_id)
        );
        existing = cursor.fetchone();
        if existing {
            if existing[0] == user_id {
                return {'message': 'SSO account already linked to this user'};
            }
            return {'error': 'This SSO account is already linked to another user'};
        }
        # Link the SSO account
        self._conn.execute(
            """
            INSERT INTO sso_accounts (user_id, platform, external_id, email)
            VALUES (?, ?, ?, ?)
            """,
            (user_id, platform, external_id, email)
        );
        self._conn.commit();
        return {
            'message': 'SSO account linked successfully',
            'user_id': user_id,
            'platform': platform
        };
    }
    # MongoDB implementation
    # Check if this SSO account is already linked
    existing = self._sso_col.find_one(
        {'platform': platform, 'external_id': external_id}
    );
    if existing {
        if existing['user_id'] == user_id {
            return {'message': 'SSO account already linked to this user'};
        }
        return {'error': 'This SSO account is already linked to another user'};
    }
    # Link the SSO account
    import from datetime { datetime, UTC }
    self._sso_col.insert_one(
        {
            'user_id': user_id,
            'platform': platform,
            'external_id': external_id,
            'email': email,
            'linked_at': datetime.now(UTC)
        }
    );
    return {
        'message': 'SSO account linked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

"""Unlink an SSO account from a user."""
impl JacScaleUserManager.unlink_sso_account(
    user_id: str, platform: str
) -> dict[str, str] {
    if self._sso_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "DELETE FROM sso_accounts WHERE user_id = ? AND platform = ?",
            (user_id, platform)
        );
        self._conn.commit();
        if cursor.rowcount == 0 {
            return {'error': 'SSO account not found'};
        }
        return {
            'message': 'SSO account unlinked successfully',
            'user_id': user_id,
            'platform': platform
        };
    }
    # MongoDB implementation
    result = self._sso_col.delete_one({'user_id': user_id, 'platform': platform});
    if result.deleted_count == 0 {
        return {'error': 'SSO account not found'};
    }
    return {
        'message': 'SSO account unlinked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

"""Get all SSO accounts linked to a user."""
impl JacScaleUserManager.get_sso_accounts(user_id: str) -> list[dict[str, str]] {
    if self._sso_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            """
            SELECT platform, external_id, email, linked_at
            FROM sso_accounts
            WHERE user_id = ?
            ORDER BY linked_at DESC
            """,
            (user_id, )
        );
        accounts = [];
        for row in cursor.fetchall() {
            accounts.append(
                {
                    'platform': row[0],
                    'external_id': row[1],
                    'email': row[2],
                    'linked_at': row[3]
                }
            );
        }
        return accounts;
    }
    # MongoDB implementation
    cursor = self._sso_col.find(
        {'user_id': user_id},
        {'_id': 0, 'platform': 1, 'external_id': 1, 'email': 1, 'linked_at': 1}
    ).sort(
        'linked_at', -1
    );
    accounts = [];
    for doc in cursor {
        accounts.append(
            {
                'platform': doc['platform'],
                'external_id': doc['external_id'],
                'email': doc.get('email', ''),
                'linked_at': str(doc.get('linked_at', ''))
            }
        );
    }
    return accounts;
}

"""Find a user by their SSO account credentials."""
impl JacScaleUserManager.get_user_by_sso(
    platform: str, external_id: str
) -> (dict[str, str] | None) {
    if self._sso_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            """
            SELECT sa.user_id, u.token, u.root_id
            FROM sso_accounts sa
            JOIN users u ON sa.user_id = u.username
            WHERE sa.platform = ? AND sa.external_id = ?
            """,
            (platform, external_id)
        );
        row = cursor.fetchone();
        if not row {
            return None;
        }
        return {'email': row[0], 'token': row[1], 'root_id': row[2]};
    }
    # MongoDB implementation
    sso_doc = self._sso_col.find_one({'platform': platform, 'external_id': external_id});
    if not sso_doc {
        return None;
    }
    user = self._users_col.find_one(
        {'username': sso_doc['user_id']}, {'token': 1, 'root_id': 1, '_id': 0}
    );
    if not user {
        return None;
    }
    return {
        'email': sso_doc['user_id'],
        'token': user['token'],
        'root_id': user['root_id']
    };
}

# ============================================================================
# User Role and Admin Management Methods
# ============================================================================
"""Get user's role."""
impl JacScaleUserManager.get_user_role(username: str) -> (str | None) {
    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "SELECT role FROM users WHERE username = ?", (username, )
        );
        row = cursor.fetchone();
        if not row {
            return None;
        }
        return row[0] or 'user';
    }
    # MongoDB implementation
    user = self._users_col.find_one({'username': username}, {'role': 1, '_id': 0});
    if not user {
        return None;
    }
    return user.get('role', 'user') or 'user';
}

"""Set user's role."""
impl JacScaleUserManager.set_user_role(username: str, role: str) -> dict[str, str] {
    import from jac_scale.user_manager { UserRole }
    # Validate role
    valid_roles = [r.value for r in UserRole];
    if role not in valid_roles {
        return {'error': f"Invalid role. Must be one of: {', '.join(valid_roles)}"};
    }

    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "UPDATE users SET role = ? WHERE username = ?", (role, username)
        );
        self._conn.commit();
        if cursor.rowcount == 0 {
            return {'error': 'User not found'};
        }
        return {
            'message': f"Role updated to '{role}'",
            'username': username,
            'role': role
        };
    }
    # MongoDB implementation
    result = self._users_col.update_one(
        {'username': username}, {'$set': {'role': role}}
    );
    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {
        'message': f"Role updated to '{role}'",
        'username': username,
        'role': role
    };
}

"""Check if user is an admin."""
impl JacScaleUserManager.is_admin(username: str) -> bool {
    role = self.get_user_role(username);
    return role == 'admin';
}

"""Check if user requires password reset."""
impl JacScaleUserManager.requires_password_reset(username: str) -> bool {
    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "SELECT requires_password_reset FROM users WHERE username = ?",
            (username, )
        );
        row = cursor.fetchone();
        if not row {
            return False;
        }
        return bool(row[0]);
    }
    # MongoDB implementation
    user = self._users_col.find_one(
        {'username': username}, {'requires_password_reset': 1, '_id': 0}
    );
    if not user {
        return False;
    }
    return bool(user.get('requires_password_reset', False));
}

"""Set whether user requires password reset."""
impl JacScaleUserManager.set_requires_password_reset(
    username: str, requires_reset: bool
) -> dict[str, str] {
    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "UPDATE users SET requires_password_reset = ? WHERE username = ?",
            (1 if requires_reset else 0, username)
        );
        self._conn.commit();
        if cursor.rowcount == 0 {
            return {'error': 'User not found'};
        }
        return {'message': 'Password reset requirement updated', 'username': username};
    }
    # MongoDB implementation
    result = self._users_col.update_one(
        {'username': username}, {'$set': {'requires_password_reset': requires_reset}}
    );
    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {'message': 'Password reset requirement updated', 'username': username};
}

"""Check if password is required for user (SSO users may not need password)."""
impl JacScaleUserManager.is_password_required(username: str) -> bool {
    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "SELECT is_password_required FROM users WHERE username = ?", (username, )
        );
        row = cursor.fetchone();
        if not row {
            return True;
        }
        val = row[0];
        return bool(val) if val is not None else True;
    }
    # MongoDB implementation
    user = self._users_col.find_one(
        {'username': username}, {'is_password_required': 1, '_id': 0}
    );
    if not user {
        return True;
    }
    val = user.get('is_password_required');
    return bool(val) if val is not None else True;
}

"""Set whether password is required for user."""
impl JacScaleUserManager.set_password_required(
    username: str, required: bool
) -> dict[str, str] {
    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            "UPDATE users SET is_password_required = ? WHERE username = ?",
            (1 if required else 0, username)
        );
        self._conn.commit();
        if cursor.rowcount == 0 {
            return {'error': 'User not found'};
        }
        return {'message': 'Password requirement updated', 'username': username};
    }
    # MongoDB implementation
    result = self._users_col.update_one(
        {'username': username}, {'$set': {'is_password_required': required}}
    );
    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {'message': 'Password requirement updated', 'username': username};
}

"""Bootstrap the admin user with UUID all zeros if it doesn't exist."""
impl JacScaleUserManager.bootstrap_admin_user -> dict[str, str] {
    import logging;
    logger = logging.getLogger(__name__);
    admin_config = get_scale_config().get_admin_config();
    if not admin_config.get('enabled', True) {
        return {'message': 'Admin portal is disabled'};
    }
    admin_username = admin_config.get('username', 'admin');
    admin_email = admin_config.get('email', 'admin@localhost');
    default_password = admin_config.get('default_password', 'changeme');
    require_reset = admin_config.get('require_password_reset', True);
    # Check if admin already exists
    existing_admin = self.get_user(admin_username);
    if existing_admin {
        # Ensure existing user has admin role
        current_role = self.get_user_role(admin_username);
        if current_role != 'admin' {
            # Set admin role
            if self._users_col is not None {
                # MongoDB
                self._users_col.update_one(
                    {'username': admin_username},
                    {'$set': {'role': 'admin', 'user_id': self.ADMIN_USER_ID}}
                );
            } else {
                # SQLite - use parent's set_user_role method
                result = self.set_user_role(admin_username, 'admin');
                if 'error' not in result {
                    # Try to set user_id if column exists
                    self._ensure_connection();
                    try {
                        self._conn.execute(
                            "UPDATE users SET user_id = ? WHERE username = ?",
                            (self.ADMIN_USER_ID, admin_username)
                        );
                        self._conn.commit();
                    } except Exception { }  # Column may not exist in parent's schema
                }
            }
            logger.info(f"Existing user '{admin_username}' promoted to admin role");
        }
        return {'message': 'Admin user already exists', 'username': admin_username};
    }
    # Create admin user
    result = self.create_user(admin_username, default_password);
    if 'error' in result {
        return result;
    }
    # Set admin role and user_id
    if self._users_col is not None {
        # MongoDB
        self._users_col.update_one(
            {'username': admin_username},
            {
                '$set': {
                    'role': 'admin',
                    'user_id': self.ADMIN_USER_ID,
                    'requires_password_reset': require_reset
                }
            }
        );
    } else {
        # SQLite - use individual methods to ensure compatibility
        self.set_user_role(admin_username, 'admin');
        self.set_requires_password_reset(admin_username, require_reset);
        # Try to set user_id if column exists
        self._ensure_connection();
        try {
            self._conn.execute(
                "UPDATE users SET user_id = ? WHERE username = ?",
                (self.ADMIN_USER_ID, admin_username)
            );
            self._conn.commit();
        } except Exception { }  # Column may not exist in parent's schema
    }
    logger.warning(
        f"Admin user '{admin_username}' created with default password. "
        "Please change the password immediately!"
    );
    return {
        'message': 'Admin user created successfully',
        'username': admin_username,
        'user_id': self.ADMIN_USER_ID,
        'requires_password_reset': str(require_reset)
    };
}

"""List all users (admin only)."""
impl JacScaleUserManager.list_all_users(
    limit: int = 100, offset: int = 0
) -> list[dict[str, Any]] {
    if self._users_col is None {
        self._ensure_connection();
        cursor = self._conn.execute(
            """
            SELECT username, root_id, role, requires_password_reset, is_password_required, user_id
            FROM users
            WHERE username != ?
            ORDER BY username
            LIMIT ? OFFSET ?
            """,
            ('__guest__', limit, offset)
        );
        users = [];
        for row in cursor.fetchall() {
            users.append(
                {
                    'username': row[0] or '',
                    'root_id': row[1] or '',
                    'role': row[2] or 'user',
                    'requires_password_reset': bool(row[3]),
                    'is_password_required': bool(row[4])
                        if row[4] is not None
                        else True,
                    'user_id': row[5]
                }
            );
        }
        return users;
    }
    # MongoDB implementation
    cursor = self._users_col.find(
        {'username': {'$ne': '__guest__'}}, {'_id': 0, 'password_hash': 0}
    ).sort(
        'username', 1
    ).skip(
        offset
    ).limit(
        limit
    );
    users = [];
    for doc in cursor {
        users.append(
            {
                'username': doc.get('username', ''),
                'root_id': doc.get('root_id', ''),
                'role': doc.get('role', 'user') or 'user',
                'requires_password_reset': bool(
                    doc.get('requires_password_reset', False)
                ),
                'is_password_required': bool(doc.get('is_password_required', True))
                    if doc.get('is_password_required') is not None
                    else True,
                'user_id': doc.get('user_id')
            }
        );
    }
    return users;
}

"""Delete a user (admin only)."""
impl JacScaleUserManager.delete_user(username: str) -> dict[str, str] {
    if self._users_col is None {
        self._ensure_connection();
        # Prevent deleting admin user with all-zeros UUID
        cursor = self._conn.execute(
            "SELECT user_id FROM users WHERE username = ?", (username, )
        );
        user = cursor.fetchone();
        if user and user[0] == self.ADMIN_USER_ID {
            return {'error': 'Cannot delete the primary admin user'};
        }
        # Delete the user
        cursor = self._conn.execute(
            "DELETE FROM users WHERE username = ?", (username, )
        );
        self._conn.commit();
        if cursor.rowcount == 0 {
            return {'error': 'User not found'};
        }
        # Also delete SSO accounts
        self._conn.execute("DELETE FROM sso_accounts WHERE user_id = ?", (username, ));
        self._conn.commit();
        return {'message': 'User deleted successfully', 'username': username};
    }
    # MongoDB implementation
    # Prevent deleting admin user with all-zeros UUID
    user = self._users_col.find_one({'username': username}, {'user_id': 1, '_id': 0});
    if user and user.get('user_id') == self.ADMIN_USER_ID {
        return {'error': 'Cannot delete the primary admin user'};
    }
    # Delete the user
    result = self._users_col.delete_one({'username': username});
    if result.deleted_count == 0 {
        return {'error': 'User not found'};
    }
    # Also delete SSO accounts
    self._sso_col.delete_many({'user_id': username});
    return {'message': 'User deleted successfully', 'username': username};
}

"""Create a user as admin (sets requires_password_reset by default)."""
impl JacScaleUserManager.create_user_as_admin(
    username: str,
    password: str,
    role: str = 'user',
    requires_password_reset: bool = True
) -> dict[str, Any] {
    import from jac_scale.user_manager { UserRole }
    import uuid;
    # Validate role
    valid_roles = [r.value for r in UserRole];
    if role not in valid_roles {
        return {'error': f"Invalid role. Must be one of: {', '.join(valid_roles)}"};
    }
    # Create the base user
    result = self.create_user(username, password);
    if 'error' in result {
        return result;
    }
    # Update with admin-specific fields
    user_id = str(uuid.uuid4());
    if self._users_col is None {
        # SQLite
        self._ensure_connection();
        self._conn.execute(
            """
            UPDATE users
            SET role = ?, user_id = ?, requires_password_reset = ?
            WHERE username = ?
            """,
            (role, user_id, 1 if requires_password_reset else 0, username)
        );
        self._conn.commit();
    } else {
        # MongoDB
        self._users_col.update_one(
            {'username': username},
            {
                '$set': {
                    'role': role,
                    'user_id': user_id,
                    'requires_password_reset': requires_password_reset
                }
            }
        );
    }
    result['role'] = role;
    result['user_id'] = user_id;
    result['requires_password_reset'] = str(requires_password_reset);
    return result;
}
