"""Test for jac-scale specs decorator."""

import contextlib
import gc
import glob
import socket
import subprocess
import time
from pathlib import Path

import requests


def get_free_port() -> int:
    """Get a free port by binding to port 0 and releasing it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        s.listen(1)
        port = s.getsockname()[1]
    return port


class TestJacScaleSpecs:
    """Test jac-scale specs functionality."""

    fixtures_dir: Path
    test_file: Path
    port: int
    base_url: str
    server_process: subprocess.Popen[str] | None = None

    @classmethod
    def setup_class(cls) -> None:
        """Set up test class - runs once for all tests."""
        cls.fixtures_dir = Path(__file__).parent / "fixtures"
        cls.test_file = cls.fixtures_dir / "test_meta.jac"

        if not cls.test_file.exists():
            raise FileNotFoundError(f"Test fixture not found: {cls.test_file}")

        cls.port = get_free_port()
        cls.base_url = f"http://localhost:{cls.port}"

        cls._cleanup_db_files()
        cls.server_process = None
        cls._start_server()

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

        # Assume 'jac' is available in the path or same venv
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

        max_attempts = 50
        server_ready = False

        for _ in range(max_attempts):
            if cls.server_process.poll() is not None:
                stdout, stderr = cls.server_process.communicate()
                raise RuntimeError(
                    f"Server process terminated unexpectedly.\n"
                    f"STDOUT: {stdout}\nSTDERR: {stderr}"
                )

            try:
                response = requests.get(f"{cls.base_url}/docs", timeout=2)
                if response.status_code in (200, 404):
                    print(f"Server started successfully on port {cls.port}")
                    server_ready = True
                    break
            except (requests.ConnectionError, requests.Timeout):
                time.sleep(2)

        if not server_ready:
            cls.server_process.terminate()
            stdout, stderr = cls.server_process.communicate()
            raise RuntimeError(
                f"Server failed to start after {max_attempts} attempts.\n"
                f"STDOUT: {stdout}\nSTDERR: {stderr}"
            )

    @classmethod
    def _cleanup_db_files(cls) -> None:
        import shutil

        for pattern in ["*.db", "*.db-wal", "*.db-shm", "anchor_store.db*"]:
            for db_file in glob.glob(pattern):
                with contextlib.suppress(Exception):
                    Path(db_file).unlink()

        for pattern in ["*.db", "*.db-wal", "*.db-shm"]:
            for db_file in glob.glob(str(cls.fixtures_dir / pattern)):
                with contextlib.suppress(Exception):
                    Path(db_file).unlink()

        client_build_dir = cls.fixtures_dir / ".jac"
        if client_build_dir.exists():
            with contextlib.suppress(Exception):
                shutil.rmtree(client_build_dir)

    def test_custom_walker_endpoint(self) -> None:
        """Test accessing walker via custom POST endpoint."""

        # Register user
        requests.post(
            f"{self.base_url}/user/register",
            json={"username": "metauser", "password": "pass"},
        )
        login_res = requests.post(
            f"{self.base_url}/user/login",
            json={"username": "metauser", "password": "pass"},
        ).json()
        token = login_res.get("data", {}).get("token") or login_res.get("token")

        headers = {"Authorization": f"Bearer {token}"}

        # POST /custom/walker
        response = requests.post(
            f"{self.base_url}/custom/walker", headers=headers, json={}
        )
        assert response.status_code == 200
        data = response.json().get("data", response.json())
        # Check reports
        assert "reports" in data
        reports = data["reports"]
        assert len(reports) > 0
        assert reports[0].get("message") == "Custom walker ran"

    def test_custom_get_endpoint(self) -> None:
        """Test accessing walker via custom GET endpoint."""
        # Register user
        requests.post(
            f"{self.base_url}/user/register",
            json={"username": "getuser", "password": "pass"},
        )
        login_res = requests.post(
            f"{self.base_url}/user/login",
            json={"username": "getuser", "password": "pass"},
        ).json()
        token = login_res.get("data", {}).get("token") or login_res.get("token")

        headers = {"Authorization": f"Bearer {token}"}

        # GET /custom/get
        response = requests.get(f"{self.base_url}/custom/get", headers=headers)
        assert response.status_code == 200
        data = response.json().get("data", response.json())
        assert "reports" in data
        reports = data["reports"]
        assert len(reports) > 0
        assert reports[0].get("message") == "Get walker ran"

    def test_custom_query_endpoint(self) -> None:
        """Test accessing walker via custom GET endpoint with query params."""
        # Register user
        requests.post(
            f"{self.base_url}/user/register",
            json={"username": "queryuser", "password": "pass"},
        )
        login_res = requests.post(
            f"{self.base_url}/user/login",
            json={"username": "queryuser", "password": "pass"},
        ).json()
        token = login_res.get("data", {}).get("token") or login_res.get("token")

        headers = {"Authorization": f"Bearer {token}"}

        # GET /custom/query (with body)
        response = requests.get(
            f"{self.base_url}/custom/query", 
            headers=headers,
            json={"val": "testval"}
        )
        assert response.status_code == 200
        data = response.json().get("data", response.json())
        assert "reports" in data
        reports = data["reports"]
        assert len(reports) > 0
        assert reports[0].get("message") == "Query walker ran"
        assert reports[0].get("val") == "testval"
