"""JacScaleUserManager implementation with MongoDB storage."""
import secrets;
import hashlib;
import os;
import from datetime { datetime, timezone }
import from jaclang.jac0core.constructs { Root }
import from jaclang.runtimelib.context { Jac }
import from jac_scale.db { get_mongo_client }

# ============================================================================
# MongoDB Initialization
# ============================================================================

impl JacScaleUserManager.postinit -> None {
    # Initialize parent fields (required by UserManager interface)
    self._db_path = "";  # Not used for MongoDB
    self._conn = None;   # Not used for MongoDB

    # Get MongoDB client from connection pool
    db_config = get_scale_config().get_database_config();
    mongodb_uri = db_config.get('mongodb_uri');

    if not mongodb_uri {
        raise ValueError(
            "MongoDB URI not configured. Please set mongodb_uri in jac.toml "
            "under [plugins.scale.database] or set MONGODB_URI environment variable."
        );
    }

    self._mongo_client = get_mongo_client(mongodb_uri);
    self._users_col = self._mongo_client[self._db_name]['users'];
    self._sso_col = self._mongo_client[self._db_name]['sso_accounts'];

    # Create indexes for better query performance
    self._users_col.create_index('username', unique=True);
    self._users_col.create_index('token', unique=True);
    self._sso_col.create_index([('platform', 1), ('external_id', 1)], unique=True);
    self._sso_col.create_index('user_id');

    # Load SSO config
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
}

impl JacScaleUserManager._ensure_connection -> None {
    # MongoDB connection is managed by the connection pool
    # This method is kept for interface compatibility
    
}

# ============================================================================
# Core UserManager Methods - MongoDB Implementation
# ============================================================================

impl JacScaleUserManager.create_user(username: str, password: str) -> dict[str, str] {
    import from jaclang.jac0core.constructs { Root }

    # Check if user already exists
    if self._users_col.find_one({'username': username}) {
        return {'error': 'User already exists'};
    }

    # Use existing context instead of creating new one
    ctx = Jac.get_context();
    user_root = Root();
    root_anchor = user_root.__jac__;
    Jac.save(root_anchor);
    Jac.commit(root_anchor);
    root_id = root_anchor.id.hex;

    token = secrets.token_urlsafe(32);
    password_hash = hashlib.sha256(password.encode()).hexdigest();

    # Insert user document into MongoDB
    user_doc = {
        'username': username,
        'password_hash': password_hash,
        'token': token,
        'root_id': root_id,
        'role': 'user',
        'requires_password_reset': False,
        'is_password_required': True,
        'user_id': None,
        'created_at': datetime.now(timezone.utc)
    };

    self._users_col.insert_one(user_doc);

    return {'username': username, 'token': token, 'root_id': root_id};
}

impl JacScaleUserManager.authenticate(
    username: str, password: str
) -> (dict[(str, str)] | None) {
    password_hash = hashlib.sha256(password.encode()).hexdigest();
    user = self._users_col.find_one(
        {'username': username, 'password_hash': password_hash}
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

impl JacScaleUserManager.get_root_id(username: str) -> (str | None) {
    user = self._users_col.find_one({'username': username});
    return user['root_id'] if user else None;
}

impl JacScaleUserManager.get_user(username: str) -> (dict[(str, str)] | None) {
    user = self._users_col.find_one({'username': username});
    if not user {
        return None;
    }
    return {'email': username, 'token': user['token'], 'root_id': user['root_id']};
}

impl JacScaleUserManager.user_exists(username: str) -> bool {
    return self._users_col.count_documents({'username': username}, limit=1) > 0;
}

impl JacScaleUserManager.update_username(
    current_username: str, new_username: str
) -> dict[str, str] {
    # Check if new username already exists
    if self._users_col.find_one({'username': new_username}) {
        return {'error': 'Username already taken'};
    }

    # Update username
    result = self._users_col.update_one(
        {'username': current_username},
        {'$set': {'username': new_username}}
    );

    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }

    # Get updated user data
    user = self._users_col.find_one({'username': new_username});
    return {
        'username': new_username,
        'token': user['token'],
        'root_id': user['root_id']
    };
}

impl JacScaleUserManager.update_password(
    username: str, current_password: str, new_password: str
) -> dict[str, str] {
    # Verify current password
    current_password_hash = hashlib.sha256(current_password.encode()).hexdigest();
    user = self._users_col.find_one(
        {'username': username, 'password_hash': current_password_hash}
    );

    if not user {
        return {'error': 'Current password is incorrect'};
    }

    # Update password
    new_password_hash = hashlib.sha256(new_password.encode()).hexdigest();
    self._users_col.update_one(
        {'username': username},
        {'$set': {'password_hash': new_password_hash}}
    );

    return {'username': username, 'message': 'Password updated successfully'};
}

impl JacScaleUserManager.close -> None {
    # MongoDB connections are managed by the connection pool
    # Individual operations don't need to close connections
    pass;
}

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

impl JacScaleUserManager.validate_token(token: str) -> (str | None) {
    return self.validate_jwt_token(token);
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

impl JacScaleUserManager.link_sso_account(
    user_id: str, platform: str, external_id: str, email: str
) -> dict[str, str] {
    # Check if this SSO account is already linked to another user
    existing = self._sso_col.find_one({'platform': platform, 'external_id': external_id});

    if existing {
        if existing['user_id'] == user_id {
            return {'message': 'SSO account already linked to this user'};
        }
        return {'error': 'This SSO account is already linked to another user'};
    }

    # Link the SSO account
    sso_doc = {
        'user_id': user_id,
        'platform': platform,
        'external_id': external_id,
        'email': email,
        'linked_at': datetime.now(timezone.utc)
    };

    self._sso_col.insert_one(sso_doc);

    return {
        'message': 'SSO account linked successfully',
        'user_id': user_id,
        'platform': platform
    };
}

impl JacScaleUserManager.unlink_sso_account(
    user_id: str, platform: str
) -> dict[str, str] {
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

impl JacScaleUserManager.get_sso_accounts(user_id: str) -> list[dict[str, str]] {
    accounts = [];
    for doc in self._sso_col.find({'user_id': user_id}).sort('linked_at', -1) {
        accounts.append(
            {
                'platform': doc['platform'],
                'external_id': doc['external_id'],
                'email': doc['email'],
                'linked_at': doc['linked_at'].isoformat() if 'linked_at' in doc else ''
            }
        );
    }
    return accounts;
}

impl JacScaleUserManager.get_user_by_sso(
    platform: str, external_id: str
) -> (dict[str, str] | None) {
    sso_account = self._sso_col.find_one(
        {'platform': platform, 'external_id': external_id}
    );

    if not sso_account {
        return None;
    }

    user_id = sso_account['user_id'];
    user = self._users_col.find_one({'username': user_id});

    if not user {
        return None;
    }

    return {'email': user['username'], 'token': user['token'], 'root_id': user['root_id']};
}

# ============================================================================
# User Role and Admin Management Methods
# ============================================================================

impl JacScaleUserManager.get_user_role(username: str) -> (str | None) {
    user = self._users_col.find_one({'username': username});
    if not user {
        return None;
    }
    return user.get('role', 'user');
}

impl JacScaleUserManager.set_user_role(username: str, role: str) -> dict[str, str] {
    import from jac_scale.user_manager { UserRole }
    # Validate role
    valid_roles = [r.value for r in UserRole];
    if role not in valid_roles {
        return {'error': f"Invalid role. Must be one of: {', '.join(valid_roles)}"};
    }

    result = self._users_col.update_one(
        {'username': username},
        {'$set': {'role': role}}
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

impl JacScaleUserManager.is_admin(username: str) -> bool {
    role = self.get_user_role(username);
    return role == 'admin';
}

impl JacScaleUserManager.requires_password_reset(username: str) -> bool {
    user = self._users_col.find_one({'username': username});
    if not user {
        return False;
    }
    return bool(user.get('requires_password_reset', False));
}

impl JacScaleUserManager.set_requires_password_reset(
    username: str, requires_reset: bool
) -> dict[str, str] {
    result = self._users_col.update_one(
        {'username': username},
        {'$set': {'requires_password_reset': requires_reset}}
    );

    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {'message': 'Password reset requirement updated', 'username': username};
}

impl JacScaleUserManager.is_password_required(username: str) -> bool {
    user = self._users_col.find_one({'username': username});
    if not user {
        return True;
    }
    is_required = user.get('is_password_required');
    return bool(is_required) if is_required is not None else True;
}

impl JacScaleUserManager.set_password_required(
    username: str, required: bool
) -> dict[str, str] {
    result = self._users_col.update_one(
        {'username': username},
        {'$set': {'is_password_required': required}}
    );

    if result.matched_count == 0 {
        return {'error': 'User not found'};
    }
    return {'message': 'Password requirement updated', 'username': username};
}

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
            self._users_col.update_one(
                {'username': admin_username},
                {'$set': {'role': 'admin', 'user_id': self.ADMIN_USER_ID}}
            );
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

impl JacScaleUserManager.list_all_users(
    limit: int = 100, offset: int = 0
) -> list[dict[str, Any]] {
    users = [];
    cursor = self._users_col.find(
        {'username': {'$ne': '__guest__'}}
    ).sort('username', 1).skip(offset).limit(limit);

    for user in cursor {
        users.append(
            {
                'username': user['username'],
                'root_id': user['root_id'],
                'role': user.get('role', 'user'),
                'requires_password_reset': bool(user.get('requires_password_reset', False)),
                'is_password_required': bool(user.get('is_password_required', True)),
                'user_id': user.get('user_id')
            }
        );
    }
    return users;
}

impl JacScaleUserManager.delete_user(username: str) -> dict[str, str] {
    # Prevent deleting admin user with all-zeros UUID
    user = self._users_col.find_one({'username': username});
    if user and user.get('user_id') == self.ADMIN_USER_ID {
        return {'error': 'Cannot delete the primary admin user'};
    }

    # Delete the user
    result = self._users_col.delete_one({'username': username});
    if result.deleted_count == 0 {
        return {'error': 'User not found'};
    }
    return {'message': 'User deleted successfully', 'username': username};
}

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
    result['role'] = role;
    result['user_id'] = user_id;
    result['requires_password_reset'] = str(requires_password_reset);
    return result;
}
