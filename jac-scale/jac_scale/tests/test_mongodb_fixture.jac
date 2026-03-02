"""MongoDB test fixtures using testcontainers.

This module provides reusable MongoDB test fixtures for integration testing.
Uses testcontainers to spin up a real MongoDB instance in Docker.
"""

import os;
import shutil;
import from pathlib { Path }
import from tempfile { mkdtemp }
import from testcontainers.mongodb { MongoDbContainer }
import unittest.mock;

import from jac_scale.config_loader { reset_scale_config }
import from jac_scale.user_manager { JacScaleUserManager }

"""Global MongoDB container for test session."""
glob _mongo_container: MongoDbContainer | None = None;
glob _mongo_uri: str | None = None;

"""Start MongoDB testcontainer and return connection URI."""
def start_mongo_container -> str {
    global _mongo_container, _mongo_uri;

    if _mongo_uri is not None {
        return _mongo_uri;
    }

    # Start MongoDB container
    _mongo_container = MongoDbContainer("mongo:7.0");
    _mongo_container.start();

    # Get connection URI
    _mongo_uri = _mongo_container.get_connection_url();

    return _mongo_uri;
}

"""Stop MongoDB testcontainer."""
def stop_mongo_container -> None {
    global _mongo_container, _mongo_uri;

    if _mongo_container is not None {
        _mongo_container.stop();
        _mongo_container = None;
        _mongo_uri = None;
    }
}

"""Get MongoDB URI (starts container if needed)."""
def get_test_mongo_uri -> str {
    return start_mongo_container();
}

"""Mock config that returns test MongoDB URI."""
class MockScaleConfigWithMongoDB {
    has _sso_config: dict,
        _mongodb_uri: str;

    def init(self, sso_config: dict, mongodb_uri: str) -> None {
        self._sso_config = sso_config;
        self._mongodb_uri = mongodb_uri;
    }

    def get_sso_config(self) -> dict {
        return self._sso_config;
    }

    def get_jwt_config(self) -> dict {
        return {"secret": "test_secret", "algorithm": "HS256", "exp_delta_days": 1};
    }

    def get_database_config(self) -> dict {
        return {
            'mongodb_uri': self._mongodb_uri,
            'redis_url': None,
            'shelf_db_path': '.jac/data/anchor_store.db'
        };
    }

    def get_kubernetes_config(self) -> dict {
        return {"namespace": "default"};
    }

    def get_monitoring_config(self) -> dict {
        return {"enabled": False};
    }

    def get_admin_config(self) -> dict {
        return {
            'enabled': True,
            'username': 'admin',
            'email': 'admin@localhost',
            'default_password': 'changeme',
            'session_expiry_hours': 24,
            'require_password_reset': True
        };
    }
}

"""Setup a JacScaleUserManager with test MongoDB container.

Returns:
    tuple: (test_dir, user_manager)
"""
def setup_mongo_user_manager(sso_config: dict) -> tuple[str, JacScaleUserManager] {
    test_dir = mkdtemp();
    reset_scale_config();

    # Get test MongoDB URI
    mongo_uri = get_test_mongo_uri();

    # Create mock config with test MongoDB
    mock_config = MockScaleConfigWithMongoDB(sso_config, mongo_uri);

    with unittest.mock.patch(
        "jac_scale.user_manager.get_scale_config", return_value=mock_config
    ) {
        with unittest.mock.patch(
            "jac_scale.impl.user_manager.get_scale_config", return_value=mock_config
        ) {
            user_manager = JacScaleUserManager(base_path=test_dir);
        }
    }

    # Clean test collections before use
    user_manager._users_col.delete_many({});
    user_manager._sso_col.delete_many({});

    return (test_dir, user_manager);
}

"""Teardown user manager and clean test data."""
def teardown_mongo_user_manager(
    test_dir: str, user_manager: JacScaleUserManager
) -> None {
    # Clean MongoDB collections
    try {
        user_manager._users_col.delete_many({});
        user_manager._sso_col.delete_many({});
    } except Exception {

    }

    # Clean temp directory
    if os.path.exists(test_dir) {
        shutil.rmtree(test_dir);
    }
}

"""Context manager for MongoDB test setup/teardown."""
class MongoTestContext {
    has test_dir: str | None = None,
        user_manager: JacScaleUserManager | None = None,
        sso_config: dict;

    def init(self, sso_config: dict) -> None {
        self.sso_config = sso_config;
    }

    def __enter__(self) -> JacScaleUserManager {
        (self.test_dir, self.user_manager) = setup_mongo_user_manager(self.sso_config);
        return self.user_manager;
    }

    def __exit__(self, exc_type, exc_val, exc_tb) -> None {
        if self.test_dir and self.user_manager {
            teardown_mongo_user_manager(self.test_dir, self.user_manager);
        }
    }
}
