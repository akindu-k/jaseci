"""Test for restspec decorator functionality."""

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


class TestRestSpec:
    """Test restspec decorator functionality."""

    # Class attributes with type annotations
    fixtures_dir: Path
    test_file: Path
    port: int
    base_url: str
    server_process: subprocess.Popen[str] | None = None

    @classmethod
    def setup_class(cls) -> None:
        """Set up test class - runs once for all tests."""
        cls.fixtures_dir = Path(__file__).parent / "fixtures"
        cls.test_file = cls.fixtures_dir / "test_restspec.jac"

        # Ensure fixture file exists
        if not cls.test_file.exists():
            raise FileNotFoundError(f"Test fixture not found: {cls.test_file}")

        # Use dynamically allocated free port
        cls.port = get_free_port()
        cls.base_url = f"http://localhost:{cls.port}"

        # Clean up any existing database files before starting
        cls._cleanup_db_files()

        # Start the server process
        cls.server_process = None
        cls._start_server()

    @classmethod
    def teardown_class(cls) -> None:
        """Tear down test class - runs once after all tests."""
        # Stop server process
        if cls.server_process:
            cls.server_process.terminate()
            try:
                cls.server_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
                cls.server_process.wait()

        # Give the server a moment to fully release file handles
        time.sleep(0.5)
        # Run garbage collection to clean up lingering socket objects
        gc.collect()

        # Clean up database files
        cls._cleanup_db_files()

    @classmethod
    def _start_server(cls) -> None:
        """Start the jac-scale server in a subprocess."""
        import sys

        # Get the jac executable from the same directory as the current Python interpreter
        jac_executable = Path(sys.executable).parent / "jac"

        # Build the command to start the server
        cmd = [
            str(jac_executable),
            "start",
            cls.test_file.name,
            "--port",
            str(cls.port),
        ]

        # Start the server process with cwd set to fixtures directory
        cls.server_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(cls.fixtures_dir),
        )

        # Wait for server to be ready
        max_attempts = 50
        server_ready = False

        for _ in range(max_attempts):
            # Check if process has died
            if cls.server_process.poll() is not None:
                # Process has terminated, get output
                stdout, stderr = cls.server_process.communicate()
                raise RuntimeError(
                    f"Server process terminated unexpectedly.\n"
                    f"STDOUT: {stdout}\nSTDERR: {stderr}"
                )

            try:
                # Try to connect to any endpoint to verify server is up
                response = requests.get(f"{cls.base_url}/docs", timeout=2)
                if response.status_code in (200, 404):  # Server is responding
                    print(f"Server started successfully on port {cls.port}")
                    server_ready = True
                    break
            except (requests.ConnectionError, requests.Timeout):
                time.sleep(2)

        # If we get here and server is not ready, it failed to start
        if not server_ready:
            # Try to terminate the process
            cls.server_process.terminate()
            try:
                stdout, stderr = cls.server_process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
                stdout, stderr = cls.server_process.communicate()

            raise RuntimeError(
                f"Server failed to start after {max_attempts} attempts.\n"
                f"STDOUT: {stdout}\nSTDERR: {stderr}"
            )

    @classmethod
    def _cleanup_db_files(cls) -> None:
        """Delete SQLite database files and legacy shelf files."""
        import shutil

        # Clean up SQLite database files (WAL mode creates -wal and -shm files)
        for pattern in [
            "*.db",
            "*.db-wal",
            "*.db-shm",
            # Legacy shelf files
            "anchor_store.db.dat",
            "anchor_store.db.bak",
            "anchor_store.db.dir",
        ]:
            for db_file in glob.glob(pattern):
                with contextlib.suppress(Exception):
                    Path(db_file).unlink()

        # Clean up database files in fixtures directory
        for pattern in ["*.db", "*.db-wal", "*.db-shm"]:
            for db_file in glob.glob(str(cls.fixtures_dir / pattern)):
                with contextlib.suppress(Exception):
                    Path(db_file).unlink()

        # Clean up .jac directory created during serve
        client_build_dir = cls.fixtures_dir / ".jac"
        if client_build_dir.exists():
            with contextlib.suppress(Exception):
                shutil.rmtree(client_build_dir)

    @staticmethod
    def _extract_transport_response_data(
        json_response: dict[str, Any] | list[Any],
    ) -> dict[str, Any] | list[Any]:
        """Extract data from TransportResponse envelope format."""
        # Handle jac-scale's tuple response format [status, body]
        if isinstance(json_response, list) and len(json_response) == 2:
            body: dict[str, Any] = json_response[1]
            json_response = body

        # Handle TransportResponse envelope format
        if (
            isinstance(json_response, dict)
            and "ok" in json_response
            and "data" in json_response
        ):
            if json_response.get("ok") and json_response.get("data") is not None:
                return json_response["data"]
            elif not json_response.get("ok") and json_response.get("error"):
                error_info = json_response["error"]
                result: dict[str, Any] = {
                    "error": error_info.get("message", "Unknown error")
                }
                if "code" in error_info:
                    result["error_code"] = error_info["code"]
                if "details" in error_info:
                    result["error_details"] = error_info["details"]
                return result

        return json_response

    # ========================================================================
    # RestSpec Decorator Tests
    # ========================================================================
    def test_get_walker(self) -> None:
        """Test GET walker."""
        response = requests.get(
            f"{self.base_url}/walker/GetWalker",
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_transport_response_data(response.json())
        assert "reports" in data
        assert data["reports"][0]["message"] == "GetWalker executed"
        assert data["reports"][0]["method"] == "GET"

    def test_post_walker(self) -> None:
        """Test POST walker."""
        response = requests.post(
            f"{self.base_url}/walker/PostWalker",
            json={"data": "test_data"},
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_transport_response_data(response.json())
        assert "reports" in data
        assert data["reports"][0]["message"] == "PostWalker executed"
        assert data["reports"][0]["data"] == "test_data"
        assert data["reports"][0]["method"] == "POST"

    def test_get_func(self) -> None:
        """Test GET function."""
        # Function requires auth, checking if we can get 401 unauth is a valid test
        # But let's just make it public in fixture if we want simple test,
        # or register a user here. Since fixtures are reset per class setup, new db.
        # Let's register a user first.
        register_response = requests.post(
            f"{self.base_url}/user/register",
            json={"username": "testuser", "password": "password"},
            timeout=5,
        )
        token = self._extract_transport_response_data(register_response.json())["token"]

        response = requests.get(
            f"{self.base_url}/function/get_func_test",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_transport_response_data(response.json())
        assert data["result"]["message"] == "get_func_test executed"
        assert data["result"]["method"] == "GET"

    def test_post_func(self) -> None:
        """Test POST function."""
        # Reuse user if possible, or register new one. State is preserved during class run.
        # Register new one to be safe/simple
        register_response = requests.post(
            f"{self.base_url}/user/register",
            json={"username": "testuser2", "password": "password"},
            timeout=5,
        )
        token = self._extract_transport_response_data(register_response.json())["token"]

        response = requests.post(
            f"{self.base_url}/function/post_func_test",
            json={"data": "func_data"},
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_transport_response_data(response.json())
        assert data["result"]["message"] == "post_func_test executed"
        assert data["result"]["data"] == "func_data"
        assert data["result"]["method"] == "POST"

    def test_restspec_openapi(self) -> None:
        """Verify OpenAPI spec reflects custom methods."""
        response = requests.get(f"{self.base_url}/openapi.json", timeout=5)
        spec = response.json()
        paths = spec["paths"]

        assert "get" in paths["/walker/GetWalker"]
        assert "post" not in paths["/walker/GetWalker"]

        assert "post" in paths["/walker/PostWalker"]
        
        assert "get" in paths["/function/get_func_test"]
        assert "post" not in paths["/function/get_func_test"]

        assert "post" in paths["/function/post_func_test"]

    def test_custom_path_walker(self) -> None:
        """Test walker with custom path."""
        response = requests.get(
            f"{self.base_url}/custom/my_walker",
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_transport_response_data(response.json())
        assert "reports" in data
        assert data["reports"][0]["message"] == "CustomPathWalker executed"
        assert data["reports"][0]["path"] == "/custom/my_walker"

    def test_custom_path_func(self) -> None:
        """Test function with custom path."""
        # Register user for auth
        register_response = requests.post(
            f"{self.base_url}/user/register",
            json={"username": "pathuser", "password": "password"},
            timeout=5,
        )
        token = self._extract_transport_response_data(register_response.json())["token"]

        response = requests.get(
            f"{self.base_url}/custom/my_func",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        assert response.status_code == 200
        data = self._extract_transport_response_data(response.json())
        assert data["result"]["message"] == "custom_path_func executed"
        assert data["result"]["path"] == "/custom/my_func"

    def test_custom_path_openapi(self) -> None:
        """Verify OpenAPI spec includes custom paths."""
        response = requests.get(f"{self.base_url}/openapi.json", timeout=5)
        spec = response.json()
        paths = spec["paths"]

        # Custom paths should exist
        assert "/custom/my_walker" in paths
        assert "/custom/my_func" in paths
        
        # Default keys based on name should NOT exist for these custom path items if we only register custom path
        # In our implementation logic:
        # For walker: if spec_path { ... } else { default paths } -> So default paths should NOT exist
        assert "/walker/CustomPathWalker" not in paths
        
        # For function: if spec_path { register at path } -> But wait, logic was:
        # final_path = spec_path if spec_path else f"/function/{func_name}"
        # So we only register ONE endpoint. Default path shouldn't exist.
        assert "/function/custom_path_func" not in paths
