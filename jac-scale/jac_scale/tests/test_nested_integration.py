"""Test for nested object argument support."""

import contextlib
import gc
import glob
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

import requests


def get_free_port() -> int:
    """Get a free port by binding to port 0 and releasing it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        s.listen(1)
        port = s.getsockname()[1]
    return port


class TestNestedIntegration:
    """Test nested object support in walker arguments."""

    fixtures_dir: Path
    test_file: Path
    port: int
    base_url: str
    server_process: subprocess.Popen[str] | None = None

    @classmethod
    def setup_class(cls) -> None:
        """Set up test class - runs once for all tests."""
        cls.fixtures_dir = Path(__file__).parent / "fixtures"
        cls.test_file = cls.fixtures_dir / "test_nested.jac"

        if not cls.test_file.exists():
            raise FileNotFoundError(f"Test fixture not found: {cls.test_file}")

        cls.port = get_free_port()
        cls.base_url = f"http://localhost:{cls.port}"

        cls._cleanup_db_files()
        cls._start_server()
        cls._register_user()

    @classmethod
    def teardown_class(cls) -> None:
        """Tear down test class - runs once after all tests."""
        if cls.server_process:
            cls.server_process.terminate()
            try:
                cls.server_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
                cls.server_process.wait()

        time.sleep(0.5)
        gc.collect()
        cls._cleanup_db_files()

    @classmethod
    def _start_server(cls) -> None:
        """Start the jac-scale server in a subprocess."""
        import sys

        jac_executable = Path(sys.executable).parent / "jac"
        cmd = [
            str(jac_executable),
            "start",
            cls.test_file.name,
            "--port",
            str(cls.port),
        ]

        cls.server_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(cls.fixtures_dir),
        )

        # Wait for server
        max_attempts = 50
        for _ in range(max_attempts):
            if cls.server_process.poll() is not None:
                stdout, stderr = cls.server_process.communicate()
                raise RuntimeError(f"Server died: {stdout}\n{stderr}")
            try:
                requests.get(f"{cls.base_url}/docs", timeout=1)
                return
            except requests.RequestException:
                time.sleep(0.5)

        cls.server_process.kill()
        raise RuntimeError("Server failed to start")

    @classmethod
    def _cleanup_db_files(cls) -> None:
        """Cleanup database files."""
        import shutil

        for pattern in ["*.db", "*.db-wal", "*.db-shm", "anchor_store*"]:
            for f in glob.glob(pattern):
                with contextlib.suppress(Exception):
                    Path(f).unlink()
        for pattern in ["*.db", "*.db-wal", "*.db-shm"]:
            for f in glob.glob(str(cls.fixtures_dir / pattern)):
                with contextlib.suppress(Exception):
                    Path(f).unlink()
        client_dir = cls.fixtures_dir / ".jac"
        if client_dir.exists():
            with contextlib.suppress(Exception):
                shutil.rmtree(client_dir)

    @classmethod
    def _register_user(cls) -> None:
        """Register a test user and store the token."""
        response = requests.post(
            f"{cls.base_url}/user/register",
            json={"username": "testuser", "password": "password123"},
            timeout=5,
        )
        if response.status_code != 201:
            raise RuntimeError(f"Failed to register user: {response.text}")

        data = response.json()
        if isinstance(data, list):
            data = data[1]
        cls.token = data["data"]["token"]
        cls.headers = {"Authorization": f"Bearer {cls.token}"}

    def _extract_data(self, response: dict[str, Any] | list[Any]) -> Any:
        if isinstance(response, list) and len(response) == 2:
            response = response[1]

        if isinstance(response, dict) and "data" in response:
            return response["data"]
        return response

    def test_nested_object_instantiation(self) -> None:
        """Test instantiation of nested custom objects."""
        # Define nested structure matching `User` and `Address`
        payload = {
            "user": {
                "name": "Alice",
                "address": {"street": "123 Main St", "zip": 90210},
                "tags": ["vip", "early-adopter"],
                "metadata": {"source": "test"},
            }
        }

        response = requests.post(
            f"{self.base_url}/walker/NestedWalker",
            json=payload,
            headers=self.headers,
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_data(response.json())

        # Verify the report contains correctly extracted values
        report = data["reports"][0]
        assert report["name"] == "Alice"
        assert report["street"] == "123 Main St"
        assert report["zip"] == 90210
        assert report["tags"] == ["vip", "early-adopter"]
        assert report["metadata"] == {"source": "test"}

    def test_list_of_nested_objects(self) -> None:
        """Test instantiation of a list of custom objects."""
        payload = {
            "users": [
                {"name": "Bob", "address": {"street": "456 Elm St", "zip": 10001}},
                {"name": "Charlie", "address": {"street": "789 Oak St", "zip": 20002}},
            ]
        }

        response = requests.post(
            f"{self.base_url}/walker/NestedListWalker",
            json=payload,
            headers=self.headers,
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_data(response.json())

        # Verify report contains list of names form instantiated objects
        report = data["reports"][0]
        assert report == ["Bob", "Charlie"]

    def test_nested_object_openapi_schema(self) -> None:
        """Test that nested object schema is correctly generated in OpenAPI."""
        response = requests.get(f"{self.base_url}/openapi.json", timeout=5)
        assert response.status_code == 200
        spec = response.json()

        # Check components/schemas for User and Address
        schemas = spec.get("components", {}).get("schemas", {})

        # Verify Address schema
        assert "Address" in schemas
        address_props = schemas["Address"]["properties"]
        assert "street" in address_props
        assert "zip" in address_props

        # Verify User schema and its nested relationship
        assert "User" in schemas
        user_props = schemas["User"]["properties"]
        assert "name" in user_props
        assert "address" in user_props
        # Check that address references the Address schema
        assert "$ref" in user_props["address"] or "allOf" in user_props["address"]

        # Verify Walker schema uses User
        # The walker payload schema is usually dynamically generated or referenced
        # We look for the path definition
        paths = spec.get("paths", {})
        walker_path = paths.get("/walker/NestedWalker", {})
        assert walker_path, "Walker path not found in OpenAPI"

        post_op = walker_path.get("post", {})
        request_body = post_op.get("requestBody", {})
        content = request_body.get("content", {}).get("application/json", {})
        schema = content.get("schema", {})

        # The schema for the walker body should have a 'user' property
        # It might be an inline schema or a ref
        if "$ref" in schema:
            ref_name = schema["$ref"].split("/")[-1]
            walker_schema = schemas.get(ref_name, {})
            props = walker_schema.get("properties", {})
        else:
            props = schema.get("properties", {})

        assert "user" in props
        # Verify user field in walker references User schema
        user_ref = props["user"]
        # It handles ref directly or via allOf/anyOf
        assert (
            "$ref" in user_ref
            or ("allOf" in user_ref and "$ref" in user_ref["allOf"][0])
            or ("type" in user_ref and user_ref["type"] == "object")
        )
