# jac-scale Reference

Complete reference for jac-scale, the cloud-native deployment and scaling plugin for Jac.

---

## Installation

```bash
pip install jac-scale
```

---

## Starting a Server

### Basic Server

```bash
jac start app.jac
```

### Server Options

| Option | Description | Default |
|--------|-------------|---------|
| `--port` | Server port | 8000 |
| `--host` | Bind address | 0.0.0.0 |
| `--workers` | Number of workers | 1 |
| `--reload` | Hot reload on changes | false |
| `--scale` | Deploy to Kubernetes | false |
| `--build` `-b` | Build and push Docker image (with --scale) | false |
| `--experimental` `-e` | Install from repo instead of PyPI (with --scale) | false |
| `--target` | Deployment target (kubernetes, aws, gcp) | kubernetes |
| `--registry` | Image registry (dockerhub, ecr, gcr) | dockerhub |

### Examples

```bash
# Custom port
jac start app.jac --port 3000

# Multiple workers
jac start app.jac --workers 4

# Development with hot reload
jac start app.jac --reload

# Production
jac start app.jac --host 0.0.0.0 --port 8000 --workers 4
```

---

## API Endpoints

### Automatic Endpoint Generation

Each walker becomes an API endpoint:

```jac
walker get_users {
    can fetch with Root entry {
        report [];
    }
}
```

Becomes: `POST /walker/get_users`

### Request Format

Walker parameters become request body:

```jac
walker search {
    has query: str;
    has limit: int = 10;
}
```

```bash
curl -X POST http://localhost:8000/walker/search \
  -H "Content-Type: application/json" \
  -d '{"query": "hello", "limit": 20}'
```

### Response Format

Walker `report` values become the response.

---

## @restspec Decorator

The `@restspec` decorator customizes how walkers and functions are exposed as REST API endpoints.

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `method` | `HTTPMethod` | `POST` | HTTP method for the endpoint |
| `path` | `str` | `""` (auto-generated) | Custom URL path for the endpoint |
| `webhook` | `bool` | `False` | Expose as a webhook endpoint instead of a regular walker endpoint |

### Custom HTTP Method

By default, walkers are exposed as `POST` endpoints. Use `@restspec` to change this:

```jac
import from http { HTTPMethod }

@restspec(method=HTTPMethod.GET)
walker :pub get_users {
    can fetch with Root entry {
        report [];
    }
}
```

This walker is now accessible at `GET /walker/get_users` instead of `POST`.

### Custom Path

Override the auto-generated path:

```jac
@restspec(method=HTTPMethod.GET, path="/custom/users")
walker :pub list_users {
    can fetch with Root entry {
        report [];
    }
}
```

Accessible at `GET /custom/users`.

### Functions

`@restspec` also works on standalone functions:

```jac
@restspec(method=HTTPMethod.GET)
def :pub health_check() -> dict {
    return {"status": "healthy"};
}

@restspec(method=HTTPMethod.GET, path="/custom/status")
def :pub app_status() -> dict {
    return {"status": "running", "version": "1.0.0"};
}
```

### Webhook Mode

See the [Webhooks](#webhooks) section below.

---

## Authentication

### User Registration

```bash
curl -X POST http://localhost:8000/user/register \
  -H "Content-Type: application/json" \
  -d '{"email": "user@example.com", "password": "secret"}'
```

### User Login

```bash
curl -X POST http://localhost:8000/user/login \
  -H "Content-Type: application/json" \
  -d '{"email": "user@example.com", "password": "secret"}'
```

Returns:

```json
{
  "access_token": "eyJ...",
  "token_type": "bearer"
}
```

### Authenticated Requests

```bash
curl -X POST http://localhost:8000/walker/my_walker \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

### JWT Configuration

Configure JWT authentication via environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `JWT_SECRET` | Secret key for JWT signing | `supersecretkey` |
| `JWT_ALGORITHM` | JWT algorithm | `HS256` |
| `JWT_EXP_DELTA_DAYS` | Token expiration in days | `7` |

### SSO (Single Sign-On)

jac-scale supports SSO with external identity providers. Currently supported: Google.

**Configuration:**

| Variable | Description |
|----------|-------------|
| `SSO_HOST` | SSO callback host URL (default: `http://localhost:8000/sso`) |
| `SSO_GOOGLE_CLIENT_ID` | Google OAuth client ID |
| `SSO_GOOGLE_CLIENT_SECRET` | Google OAuth client secret |

**SSO Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/sso/{platform}/login` | Redirect to provider login page |
| GET | `/sso/{platform}/register` | Redirect to provider registration |
| GET | `/sso/{platform}/login/callback` | OAuth callback handler |

**Example:**

```bash
# Redirect user to Google login
curl http://localhost:8000/sso/google/login
```

---

## Permissions & Access Control

### Access Levels

| Level | Value | Description |
|-------|-------|-------------|
| `NO_ACCESS` | `-1` | No access to the object |
| `READ` | `0` | Read-only access |
| `CONNECT` | `1` | Can traverse edges to/from this object |
| `WRITE` | `2` | Full read/write access |

### Granting Permissions

#### To Everyone

Use `perm_grant` to allow all users to access an object at a given level:

```jac
with entry {
    # Allow everyone to read this node
    perm_grant(node, READ);

    # Allow everyone to write
    perm_grant(node, WRITE);
}
```

#### To a Specific Root

Use `allow_root` to grant access to a specific user's root graph:

```jac
with entry {
    # Allow a specific user to read this node
    allow_root(node, target_root_id, READ);

    # Allow write access
    allow_root(node, target_root_id, WRITE);
}
```

### Revoking Permissions

#### From Everyone

```jac
with entry {
    # Revoke all public access
    perm_revoke(node);
}
```

#### From a Specific Root

```jac
with entry {
    # Revoke a specific user's access
    disallow_root(node, target_root_id, READ);
}
```

### Walker Access Levels

Walkers have three access levels when served as API endpoints:

| Access | Description |
|--------|-------------|
| Public (`:pub`) | Accessible without authentication |
| Protected (default) | Requires JWT authentication |
| Private (`:priv`) | Only accessible by directly defined walkers (not imported) |

### Permission Functions Reference

| Function | Signature | Description |
|----------|-----------|-------------|
| `perm_grant` | `perm_grant(archetype, level)` | Allow everyone to access at given level |
| `perm_revoke` | `perm_revoke(archetype)` | Remove all public access |
| `allow_root` | `allow_root(archetype, root_id, level)` | Grant access to a specific root |
| `disallow_root` | `disallow_root(archetype, root_id, level)` | Revoke access from a specific root |

---

## Webhooks

Webhooks allow external services (payment processors, CI/CD systems, messaging platforms, etc.) to send real-time notifications to your Jac application.

### Features

- Dedicated `/webhook/` endpoints for webhook walkers
- API key authentication for secure access
- HMAC-SHA256 signature verification to validate request integrity
- Automatic endpoint generation based on walker configuration

### Configuration

Configure webhooks in `jac.toml`:

```toml
[plugins.scale.webhook]
secret = "your-webhook-secret-key"
signature_header = "X-Webhook-Signature"
verify_signature = true
api_key_expiry_days = 365
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `secret` | string | `"webhook-secret-key"` | Secret key for HMAC signature verification. Also settable via `WEBHOOK_SECRET` env var. |
| `signature_header` | string | `"X-Webhook-Signature"` | HTTP header name for the HMAC signature |
| `verify_signature` | boolean | `true` | Whether to verify HMAC signatures on incoming requests |
| `api_key_expiry_days` | integer | `365` | Default expiry period for API keys in days. `0` for permanent keys. |

### Creating Webhook Walkers

Use `@restspec(webhook=True)` to create a webhook endpoint:

```jac
@restspec(webhook=True)
walker PaymentReceived {
    has payment_id: str,
        amount: float,
        currency: str = 'USD';

    can process with Root entry {
        report {
            "status": "success",
            "message": f"Payment {self.payment_id} received",
            "amount": self.amount,
            "currency": self.currency
        };
    }
}
```

This walker is accessible at `POST /webhook/PaymentReceived`.

Webhook walkers are **only** accessible via `/webhook/{walker_name}` endpoints -- they are **not** accessible via the standard `/walker/{walker_name}` endpoint.

### API Key Management

Webhook endpoints require API key authentication. Users must create an API key before calling webhook endpoints.

**Create API Key:**

```bash
curl -X POST http://localhost:8000/api-key/create \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "My Webhook Key", "expiry_days": 30}'
```

Response:

```json
{
    "api_key": "eyJhbGciOiJIUzI1NiIs...",
    "api_key_id": "a1b2c3d4e5f6...",
    "name": "My Webhook Key",
    "created_at": "2024-01-15T10:30:00Z",
    "expires_at": "2024-02-14T10:30:00Z"
}
```

**List API Keys:**

```bash
curl -X GET http://localhost:8000/api-key/list \
  -H "Authorization: Bearer <jwt_token>"
```

**Revoke API Key:**

```bash
curl -X DELETE http://localhost:8000/api-key/<api_key_id> \
  -H "Authorization: Bearer <jwt_token>"
```

### Calling Webhook Endpoints

Webhook endpoints require two headers:

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | Yes | Must be `application/json` |
| `X-API-Key` | Yes | API key from `/api-key/create` |
| `X-Webhook-Signature` | If `verify_signature` enabled | HMAC-SHA256 signature of request body |

The signature is computed as: `HMAC-SHA256(request_body, api_key)`

**Example (cURL):**

```bash
API_KEY="eyJhbGciOiJIUzI1NiIs..."
PAYLOAD='{"payment_id":"PAY-12345","amount":99.99,"currency":"USD"}'
SIGNATURE=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$API_KEY" | cut -d' ' -f2)

curl -X POST "http://localhost:8000/webhook/PaymentReceived" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $API_KEY" \
    -H "X-Webhook-Signature: $SIGNATURE" \
    -d "$PAYLOAD"
```

### Webhook vs Regular Walkers

| Feature | Regular Walker (`/walker/`) | Webhook Walker (`/webhook/`) |
|---------|----------------------------|------------------------------|
| Authentication | JWT Bearer token | API Key + HMAC Signature |
| Use Case | User-facing APIs | External service callbacks |
| Access Control | User-scoped | Service-scoped |
| Signature Verification | No | Yes (HMAC-SHA256) |
| Endpoint Path | `/walker/{name}` | `/webhook/{name}` |

### Webhook API Reference

| Method | Path | Description |
|--------|------|-------------|
| POST | `/webhook/{walker_name}` | Execute webhook walker |
| POST | `/api-key/create` | Create a new API key (requires JWT) |
| GET | `/api-key/list` | List all API keys for user (requires JWT) |
| DELETE | `/api-key/{api_key_id}` | Revoke an API key (requires JWT) |

---

## Storage

Jac provides a built-in storage abstraction for file and blob operations. The core runtime ships with a local filesystem implementation, and jac-scale can override it with cloud storage backends -- all through the same `store()` builtin.

### The `store()` Builtin

The recommended way to get a storage instance is the `store()` builtin. It requires no imports and is automatically hookable by plugins:

```jac
# Get a storage instance (no imports needed)
glob storage = store();

# With custom base path
glob storage = store(base_path="./uploads");

# With all options
glob storage = store(base_path="./uploads", create_dirs=True);
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `base_path` | `str` | `"./storage"` | Root directory for all files |
| `create_dirs` | `bool` | `True` | Create base directory if it doesn't exist |

Without jac-scale, `store()` returns a `LocalStorage` instance. With jac-scale installed, it returns a configuration-driven backend (reading from `jac.toml` and environment variables).

### Storage Interface

All storage instances provide these methods:

| Method | Signature | Description |
|--------|-----------|-------------|
| `upload` | `upload(source, destination, metadata=None) -> str` | Upload a file (from path or file object) |
| `download` | `download(source, destination=None) -> bytes\|None` | Download a file (returns bytes if no destination) |
| `delete` | `delete(path) -> bool` | Delete a file or directory |
| `exists` | `exists(path) -> bool` | Check if a path exists |
| `list_files` | `list_files(prefix="", recursive=False)` | List files (yields paths) |
| `get_metadata` | `get_metadata(path) -> dict` | Get file metadata (size, modified, created, is_dir, name) |
| `copy` | `copy(source, destination) -> bool` | Copy a file within storage |
| `move` | `move(source, destination) -> bool` | Move a file within storage |

### Usage Example

```jac
import from http { UploadFile }
import from uuid { uuid4 }

glob storage = store(base_path="./uploads");

walker :pub upload_file {
    has file: UploadFile;
    has folder: str = "documents";

    can process with Root entry {
        unique_name = f"{uuid4()}.dat";
        path = f"{self.folder}/{unique_name}";

        # Upload file
        storage.upload(self.file.file, path);

        # Get metadata
        metadata = storage.get_metadata(path);

        report {
            "success": True,
            "storage_path": path,
            "size": metadata["size"]
        };
    }
}

walker :pub list_files {
    has folder: str = "documents";
    has recursive: bool = False;

    can process with Root entry {
        files = [];
        for path in storage.list_files(self.folder, self.recursive) {
            metadata = storage.get_metadata(path);
            files.append({
                "path": path,
                "size": metadata["size"],
                "name": metadata["name"]
            });
        }
        report {"files": files};
    }
}

walker :pub download_file {
    has path: str;

    can process with Root entry {
        if not storage.exists(self.path) {
            report {"error": "File not found"};
            return;
        }
        content = storage.download(self.path);
        report {"content": content, "size": len(content)};
    }
}
```

### Configuration

Configure storage in `jac.toml`:

```toml
[storage]
storage_type = "local"       # Storage backend type
base_path = "./storage"      # Base directory for files
create_dirs = true           # Auto-create directories
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `storage_type` | string | `"local"` | Storage backend (`local`) |
| `base_path` | string | `"./storage"` | Base path for file storage |
| `create_dirs` | boolean | `true` | Automatically create directories |

**Environment Variables:**

| Variable | Description |
|----------|-------------|
| `JAC_STORAGE_TYPE` | Storage type (overrides jac.toml) |
| `JAC_STORAGE_PATH` | Base directory (overrides jac.toml) |
| `JAC_STORAGE_CREATE_DIRS` | Auto-create directories (`"true"`/`"false"`) |

Configuration priority: `jac.toml` > environment variables > defaults.

### StorageFactory (Advanced)

For advanced use cases, you can use `StorageFactory` directly instead of the `store()` builtin:

```jac
import from jac_scale.factories.storage_factory { StorageFactory }

# Create with explicit type and config
glob config = {"base_path": "./my-files", "create_dirs": True};
glob storage = StorageFactory.create("local", config);

# Create using jac.toml / env var / defaults
glob default_storage = StorageFactory.get_default();
```

---

## Graph Traversal API

### Traverse Endpoint

```bash
POST /traverse
```

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `source` | str | Starting node/edge ID | root |
| `depth` | int | Traversal depth | 1 |
| `detailed` | bool | Include archetype context | false |
| `node_types` | list | Filter by node types | all |
| `edge_types` | list | Filter by edge types | all |

### Example

```bash
curl -X POST http://localhost:8000/traverse \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "depth": 3,
    "node_types": ["User", "Post"],
    "detailed": true
  }'
```

---

## Async Walkers

```jac
walker async_processor {
    has items: list;

    async can process with Root entry {
        results = [];
        for item in self.items {
            result = await process_item(item);
            results.append(result);
        }
        report results;
    }
}
```

---

## Direct Database Access (kvstore)

jac-scale provides the `kvstore()` function for direct database operations without the graph layer abstraction. It supports both MongoDB (document database) and Redis (key-value store) with database-specific semantics.

### Getting Started

Import `kvstore` from the jac-scale library:

```jac
import from jac_scale.lib { kvstore }

with entry {
    # MongoDB instance
    mongo_db = kvstore(db_name='my_app', db_type='mongodb');

    # Redis instance
    redis_db = kvstore(db_name='cache', db_type='redis');
}
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `db_name` | `str` | `'jac_db'` | Database name |
| `db_type` | `str` | `'mongodb'` | Database type: `'mongodb'` or `'redis'` |
| `uri` | `str \| None` | `None` | Connection URI (falls back to env vars or jac.toml) |

### Configuration

Database URIs are resolved in this priority order:

1. **Explicit URI parameter** (highest priority)
2. **Environment variables**: `MONGODB_URI` or `REDIS_URL`
3. **jac.toml configuration** (lowest priority)

**Environment Variables:**

```bash
export MONGODB_URI="mongodb://admin:password@localhost:27017"
export REDIS_URL="redis://localhost:6379/0"
```

**jac.toml Configuration:**

```toml
[database]
mongodb_uri = "mongodb://admin:password@localhost:27017"
redis_url = "redis://localhost:6379/0"
```

**Explicit URI Example:**

```jac
mongo_db = kvstore(
    db_name='my_app',
    db_type='mongodb',
    uri='mongodb://admin:password@localhost:27017'
);
```

---

## MongoDB Operations

MongoDB provides document database operations with powerful querying capabilities.

### Common Methods

These methods work for simple key-value operations:

| Method | Signature | Description |
|--------|-----------|-------------|
| `get` | `get(key: str, col_name: str = 'default') -> dict \| None` | Get document by key |
| `set` | `set(key: str, value: dict, col_name: str = 'default') -> str` | Set document by key |
| `delete` | `delete(key: str, col_name: str = 'default') -> int` | Delete document by key |
| `exists` | `exists(key: str, col_name: str = 'default') -> bool` | Check if key exists |

### MongoDB-Only Methods

Advanced document operations with query filters:

| Method | Signature | Description |
|--------|-----------|-------------|
| `find_one` | `find_one(col_name: str, filter: dict) -> dict \| None` | Find single document matching filter |
| `find` | `find(col_name: str, filter: dict) -> Cursor` | Find all documents matching filter |
| `insert_one` | `insert_one(col_name: str, document: dict) -> InsertResult` | Insert single document |
| `insert_many` | `insert_many(col_name: str, documents: list) -> InsertManyResult` | Insert multiple documents |
| `update_one` | `update_one(col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False) -> UpdateResult` | Update single document |
| `update_many` | `update_many(col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False) -> UpdateResult` | Update multiple documents |
| `delete_one` | `delete_one(col_name: str, filter: dict) -> DeleteResult` | Delete single document |
| `delete_many` | `delete_many(col_name: str, filter: dict) -> DeleteResult` | Delete multiple documents |
| `find_by_id` | `find_by_id(col_name: str, id: str) -> dict \| None` | Find document by ID |
| `update_by_id` | `update_by_id(col_name: str, id: str, update_data: dict, upsert_mode: bool = False) -> UpdateResult` | Update document by ID |
| `delete_by_id` | `delete_by_id(col_name: str, id: str) -> DeleteResult` | Delete document by ID |

### MongoDB Example: User Management

```jac
import from jac_scale.lib { kvstore }

with entry {
    mongo_db = kvstore(db_name='my_app', db_type='mongodb');

    # Insert users
    mongo_db.insert_one('users', {
        'name': 'Alice',
        'email': 'alice@example.com',
        'role': 'admin',
        'age': 30
    });

    mongo_db.insert_one('users', {
        'name': 'Bob',
        'email': 'bob@example.com',
        'role': 'user',
        'age': 25
    });

    # Find single user
    alice = mongo_db.find_one('users', {'name': 'Alice'});

    # Find all admins
    admins = list(mongo_db.find('users', {'role': 'admin'}));

    # Find users older than 28
    older_users = list(mongo_db.find('users', {'age': {'$gt': 28}}));

    # Update user
    result = mongo_db.update_one(
        'users',
        {'name': 'Alice'},
        {'$set': {'age': 31, 'last_login': '2024-01-15'}}
    );

    # Insert multiple documents
    new_users = [
        {'name': 'Charlie', 'role': 'user', 'age': 28},
        {'name': 'Diana', 'role': 'moderator', 'age': 32}
    ];
    result = mongo_db.insert_many('users', new_users);

    # Count all users
    all_users = list(mongo_db.find('users', {}));

    # Delete a user
    result = mongo_db.delete_one('users', {'name': 'Bob'});
    
    # Using simple key-value API
    mongo_db.set('user:alice', {'name': 'Alice', 'status': 'active'}, 'sessions');
    session = mongo_db.get('user:alice', 'sessions');
}
```

### MongoDB Query Operators

MongoDB supports rich query operators:

| Operator | Description | Example |
|----------|-------------|---------|
| `$eq` | Equal to | `{'age': {'$eq': 30}}` |
| `$gt` | Greater than | `{'age': {'$gt': 25}}` |
| `$gte` | Greater than or equal | `{'age': {'$gte': 25}}` |
| `$lt` | Less than | `{'age': {'$lt': 30}}` |
| `$lte` | Less than or equal | `{'age': {'$lte': 30}}` |
| `$in` | In array | `{'role': {'$in': ['admin', 'moderator']}}` |
| `$ne` | Not equal | `{'status': {'$ne': 'deleted'}}` |
| `$and` | Logical AND | `{'$and': [{'age': {'$gt': 25}}, {'role': 'admin'}]}` |
| `$or` | Logical OR | `{'$or': [{'role': 'admin'}, {'role': 'moderator'}]}` |

---

## Redis Operations

Redis provides high-performance key-value storage with native features like TTL, atomic operations, and pattern matching.

### Common Methods

These methods work for simple key-value operations:

| Method | Signature | Description |
|--------|-----------|-------------|
| `get` | `get(key: str, col_name: str = 'default') -> dict \| None` | Get value by key |
| `set` | `set(key: str, value: dict, col_name: str = 'default') -> str` | Set value by key |
| `delete` | `delete(key: str, col_name: str = 'default') -> int` | Delete key |
| `exists` | `exists(key: str, col_name: str = 'default') -> bool` | Check if key exists |

### Redis-Only Methods

Redis-native features for caching and counters:

| Method | Signature | Description |
|--------|-----------|-------------|
| `set_with_ttl` | `set_with_ttl(key: str, value: dict, ttl: int, col_name: str = 'default') -> bool` | Set value with expiration (in seconds) |
| `expire` | `expire(key: str, seconds: int, col_name: str = 'default') -> bool` | Set expiration on existing key |
| `incr` | `incr(key: str, col_name: str = 'default') -> int` | Atomically increment numeric value |
| `scan_keys` | `scan_keys(pattern: str, col_name: str = 'default') -> list[str]` | Find keys matching pattern (uses SCAN, not KEYS) |

### Redis Example: Session & Cache Management

```jac
import from jac_scale.lib { kvstore }

with entry {
    redis_db = kvstore(db_name='cache', db_type='redis');

    # Store session data
    redis_db.set('session:user123', {
        'user_id': '123',
        'username': 'alice',
        'login_time': '2024-01-15T10:30:00Z'
    });

    # Retrieve session
    session = redis_db.get('session:user123');

    # Store temporary data with TTL (expires after 60 seconds)
    redis_db.set_with_ttl('temp:token:abc', {
        'token': 'xyz123',
        'user_id': '123'
    }, ttl=60);

    # Store cache with 1 hour TTL
    redis_db.set_with_ttl('cache:user:123:profile', {
        'name': 'Alice',
        'email': 'alice@example.com',
        'avatar_url': 'https://example.com/avatar.jpg'
    }, ttl=3600);  # 1 hour

    # Check if key exists
    has_session = redis_db.exists('session:user123');

    # Atomic counter operations
    redis_db.incr('stats:page_views');
    redis_db.incr('stats:page_views');
    redis_db.incr('stats:page_views');
    views = redis_db.get('stats:page_views');

    # Increment API call counter
    redis_db.incr('api:calls:user123');
    api_calls = redis_db.get('api:calls:user123');

    # Find all session keys
    all_sessions = redis_db.scan_keys('session:*');

    # Find all cache keys
    cache_keys = redis_db.scan_keys('cache:*');

    # Set expiration on existing key
    redis_db.expire('session:user123', 1800);  # Expire in 30 minutes

    # Delete a key
    deleted = redis_db.delete('temp:token:abc');
}
```



---

## Database Method Compatibility

### Methods Available for Both Databases

| Method | MongoDB | Redis | Notes |
|--------|---------|-------|-------|
| `get()` | ✅ | ✅ | Simple key-value retrieval |
| `set()` | ✅ | ✅ | Simple key-value storage |
| `delete()` | ✅ | ✅ | Remove by key |
| `exists()` | ✅ | ✅ | Check key existence |

### MongoDB-Only Methods

| Method | MongoDB | Redis | Error |
|--------|---------|-------|-------|
| `find_one()` | ✅ | ❌ | `NotImplementedError` |
| `find()` | ✅ | ❌ | `NotImplementedError` |
| `insert_one()` | ✅ | ❌ | `NotImplementedError` |
| `insert_many()` | ✅ | ❌ | `NotImplementedError` |
| `update_one()` | ✅ | ❌ | `NotImplementedError` |
| `update_many()` | ✅ | ❌ | `NotImplementedError` |
| `delete_one()` | ✅ | ❌ | `NotImplementedError` |
| `delete_many()` | ✅ | ❌ | `NotImplementedError` |
| `find_by_id()` | ✅ | ❌ | `NotImplementedError` |
| `update_by_id()` | ✅ | ❌ | `NotImplementedError` |
| `delete_by_id()` | ✅ | ❌ | `NotImplementedError` |

### Redis-Only Methods

| Method | MongoDB | Redis | Error |
|--------|---------|-------|-------|
| `set_with_ttl()` | ❌ | ✅ | `NotImplementedError` |
| `expire()` | ❌ | ✅ | `NotImplementedError` |
| `incr()` | ❌ | ✅ | `NotImplementedError` |
| `scan_keys()` | ❌ | ✅ | `NotImplementedError` |

**Important:** Calling database-specific methods on the wrong database type will raise `NotImplementedError` with a helpful message directing you to the appropriate method.

---

## Database Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MONGODB_URI` | MongoDB connection URI | None |
| `REDIS_URL` | Redis connection URL | None |
| `K8s_MONGODB` | Enable MongoDB deployment | `false` |
| `K8s_REDIS` | Enable Redis deployment | `false` |

### Memory Hierarchy

jac-scale uses a tiered memory system:

| Tier | Backend | Purpose |
|------|---------|---------|
| L1 | In-memory | Volatile runtime state |
| L2 | Redis | Cache layer |
| L3 | MongoDB | Persistent storage |

---

## Kubernetes Deployment

### Deploy

```bash
# Deploy to Kubernetes
jac start app.jac --scale

# Build Docker image and deploy
jac start app.jac --scale --build
```

### Remove Deployment

```bash
jac destroy app.jac
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_NAME` | Application name for K8s resources | `jaseci` |
| `K8s_NAMESPACE` | Kubernetes namespace | `default` |
| `K8s_NODE_PORT` | External NodePort | `30001` |
| `K8s_CPU_REQUEST` | CPU resource request | None |
| `K8s_CPU_LIMIT` | CPU resource limit | None |
| `K8s_MEMORY_REQUEST` | Memory resource request | None |
| `K8s_MEMORY_LIMIT` | Memory resource limit | None |
| `K8s_READINESS_INITIAL_DELAY` | Readiness probe initial delay (seconds) | `10` |
| `K8s_READINESS_PERIOD` | Readiness probe period (seconds) | `20` |
| `K8s_LIVENESS_INITIAL_DELAY` | Liveness probe initial delay (seconds) | `10` |
| `K8s_LIVENESS_PERIOD` | Liveness probe period (seconds) | `20` |
| `K8s_LIVENESS_FAILURE_THRESHOLD` | Failure threshold before restart | `80` |
| `DOCKER_USERNAME` | DockerHub username | None |
| `DOCKER_PASSWORD` | DockerHub password/token | None |

### Package Version Pinning

Configure specific package versions for Kubernetes deployments:

```toml
[plugins.scale.kubernetes.plugin_versions]
jaclang = "0.1.5"      # Specific version
jac_scale = "latest"   # Latest from PyPI (default)
jac_client = "0.1.0"   # Specific version
jac_byllm = "none"     # Skip installation
```

| Package | Description | Default |
|---------|-------------|---------|
| `jaclang` | Core Jac language package | latest |
| `jac_scale` | Scaling plugin | latest |
| `jac_client` | Client/frontend support | latest |
| `jac_byllm` | LLM integration (use "none" to skip) | latest |

---

## Health Checks

### Health Endpoint

Create a health walker:

```jac
walker health {
    can check with Root entry {
        report {"status": "healthy"};
    }
}
```

Access at: `POST /walker/health`

### Readiness Check

```jac
walker ready {
    can check with Root entry {
        db_ok = check_database();
        cache_ok = check_cache();

        if db_ok and cache_ok {
            report {"status": "ready"};
        } else {
            report {
                "status": "not_ready",
                "db": db_ok,
                "cache": cache_ok
            };
        }
    }
}
```

---

## Builtins

### Root Access

```jac
with entry {
    # Get all roots in memory/database
    roots = allroots();
}
```

### Memory Commit

```jac
with entry {
    # Commit memory to database
    commit();
}
```

---

## CLI Commands

| Command | Description |
|---------|-------------|
| `jac start app.jac` | Start local API server |
| `jac start app.jac --scale` | Deploy to Kubernetes |
| `jac start app.jac --scale --build` | Build image and deploy |
| `jac destroy app.jac` | Remove Kubernetes deployment |

---

## API Documentation

When server is running:

- **Swagger UI:** `http://localhost:8000/docs`
- **ReDoc:** `http://localhost:8000/redoc`
- **OpenAPI JSON:** `http://localhost:8000/openapi.json`

---

## Related Resources

- [Local API Server Tutorial](../../tutorials/production/local.md)
- [Kubernetes Deployment Tutorial](../../tutorials/production/kubernetes.md)
- [Backend Integration Tutorial](../../tutorials/fullstack/backend.md)
