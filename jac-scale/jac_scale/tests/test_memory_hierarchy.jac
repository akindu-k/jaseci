"""Integration tests for memory hierarchy with testcontainers and jac start."""

import contextlib;
import gc;
import os;
import socket;
import subprocess;
import sys;
import time;
import from pathlib { Path }
import from typing { Any, cast }
import redis;
import requests;
import from pymongo { MongoClient }
import from testcontainers.mongodb { MongoDbContainer }
import from testcontainers.redis { RedisContainer }

def get_free_port -> int {
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s {
        s.bind(("", 0));
        return s.getsockname()[1];
    }
}

glob FIXTURES_DIR = Path(__file__).parent / "fixtures",
     JAC_FILE = FIXTURES_DIR / "todo_app.jac";

"""Extract data from TransportResponse envelope format."""
def extract_transport_response_data(
    json_response: dict[str, Any] | list[Any]
) -> dict[str, Any] | list[Any] {
    if isinstance(json_response, list) {
        if len(json_response) == 2 {
            body: dict[str, Any] = json_response[1];
            json_response = body;
        }
    }

    if (
        isinstance(json_response, dict)
        and "ok" in json_response
        and "data" in json_response
    ) {
        if json_response.get("ok") and json_response.get("data") is not None {
            return json_response["data"];
        } elif not json_response.get("ok") and json_response.get("error") {
            error_info = json_response["error"];
            result: dict[str, Any] = {
                "error": error_info.get("message", "Unknown error")
            };
            if "code" in error_info {
                result["error_code"] = error_info["code"];
            }
            if "details" in error_info {
                result["error_details"] = error_info["details"];
            }
            return result;
        }
    }
    return json_response;
}

def register_user(base_url: str, username: str, password: str = "password123") -> str {
    res = requests.post(
        f"{base_url}/user/register",
        json={"username": username, "password": password},
        timeout=2
    );
    assert res.status_code == 201 , f"Registration failed: {res.status_code} - {res.text}";
    data = cast(dict[str, Any], extract_transport_response_data(res.json()));
    return data["token"];
}

def post_request(base_url: str, path: str, payload: dict, token: str) -> dict[str, Any] {
    res = requests.post(
        f"{base_url}{path}",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=2
    );
    assert res.status_code == 200;
    return cast(dict[str, Any], extract_transport_response_data(res.json()));
}

"""Start jac server and wait for it to become ready."""
def start_server(fixtures_dir: Path, jac_file: Path, port: int) -> subprocess.Popen {
    jac_executable = Path(sys.executable).parent / "jac";
    cmd = [str(jac_executable), "start", str(jac_file.name), "--port", str(port)];

    env = os.environ.copy();

    server = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(fixtures_dir),
        env=env
    );

    base_url = f"http://localhost:{port}";
    for _ in range(30) {
        try {
            r = requests.get(f"{base_url}/docs", timeout=1);
            if r.status_code in (200, 404) {
                return server;
            }
        } except Exception {
            time.sleep(1);
        }
    }

    (stdout, stderr) = server.communicate(timeout=2);
    raise RuntimeError(
        f"jac start failed to start\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}"
    );
}

test "read and write" {
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    # Clean up data files from previous runs
    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    # Start Redis container
    redis_container = RedisContainer("redis:latest", port=6379);
    redis_container.start();

    redis_host = redis_container.get_container_host_ip();
    redis_port = redis_container.get_exposed_port(6379);
    redis_url = f"redis://{redis_host}:{redis_port}/0";

    redis_client = redis.Redis(
        host=redis_host, port=int(redis_port), decode_responses=False
    );
    assert redis_client.dbsize() == 0;

    # Start Mongo container
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();

    mongo_uri = mongo_container.get_connection_url();
    mongo_client = MongoClient(mongo_uri);

    os.environ["MONGODB_URI"] = mongo_uri;
    os.environ["REDIS_URL"] = redis_url;

    assert "jac_db" not in mongo_client.list_database_names();

    port = get_free_port();
    base_url = f"http://localhost:{port}";

    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        db = mongo_client["jac_db"];
        collection = db["_anchors"];

        mongo_doc_initial_count = collection.count_documents({});
        assert mongo_doc_initial_count == 4 , (
            "Initial docs should be 4 (super root, guest_user, admin, __system__)"
        );

        # Register a user
        token = register_user(base_url, "reader", "pass123");

        mongo_doc_after_user_creation_count = collection.count_documents({});
        assert mongo_doc_after_user_creation_count == 5 , (
            "After user creation docs should be 5 (super root, guest_user, admin, __system__, created user)"
        );

        redis_size_before_task_creation = redis_client.dbsize();

        # Create tasks
        created_tasks = [
            {"id": 203, "title": "Task 203"},
            {"id": 204, "title": "Task 204"}
        ];

        redis_size_after_task_creation = redis_client.dbsize();

        for task_payload in created_tasks {
            post_request(base_url, "/walker/CreateTask", task_payload, token);
        }

        mongo_doc_count_after_task_creation = collection.count_documents({});
        assert mongo_doc_count_after_task_creation == 9 , (
            "After task creation docs should be 9 (prev 5 + 2 anchors per task)"
        );

        assert redis_size_after_task_creation == redis_size_before_task_creation;

        post_request(base_url, "/walker/GetAllTasks", {}, token);

        redis_size_after_task_read = redis_client.dbsize();
        assert redis_size_after_task_read == 9 , (
            "Redis should have 9 entries (super root, guest user, admin, __system__, user, 2 task nodes, 2 edges)"
        );
    } finally {
        # Teardown
        if server {
            server.terminate();
            with contextlib.suppress(Exception) {
                server.wait(timeout=2);
            }
        }

        system_dbs = {"admin","config","local"};
        for db_name in mongo_client.list_database_names() {
            if db_name not in system_dbs {
                mongo_client.drop_database(db_name);
            }
        }

        mongo_container.stop();
        redis_container.stop();

        time.sleep(0.5);
        gc.collect();

        # Clean up data files
        data_dir = FIXTURES_DIR / ".jac" / "data";
        if data_dir.exists() {
            import shutil;
            shutil.rmtree(data_dir);
        }
    }
}

test "data persists after server restart for mongo db" {
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    # Clean up data files
    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    # Start MongoDB container
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        # Create task
        res = requests.post(
            f"{base_url}/walker/CreateTask",
            json={"id": 100, "title": "Test persistence"},
            timeout=2
        );
        assert res.status_code == 200;

        # Verify task exists before restart
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        response_data = cast(
            dict[str, Any], extract_transport_response_data(res.json())
        );
        tasks_before = response_data["reports"][0];
        assert len(tasks_before) == 1 , "Should have 1 task before restart";
        assert tasks_before[0]["id"] == 100 , f"Task id should be 100, got {tasks_before[
            0
        ]['id']}";
        assert tasks_before[0]["title"] == "Test persistence" , f"Task title mismatch: {tasks_before[
            0
        ]['title']}";

        # Restart server
        server.terminate();
        server.wait(timeout=2);
        server = start_server(FIXTURES_DIR, JAC_FILE, port);

        # Verify task persists after restart
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=2);
        response_data = cast(
            dict[str, Any], extract_transport_response_data(res.json())
        );
        tasks_after = response_data["reports"][0];
        assert len(tasks_after) == 1 , "Task should persist after restart";
        assert tasks_after[0]["id"] == 100 , f"Task id should be 100 after restart, got {tasks_after[
            0
        ]['id']}";
        assert tasks_after[0]["title"] == "Test persistence" , f"Task title mismatch after restart: {tasks_after[
            0
        ]['title']}";
    } finally {
        if server {
            server.terminate();
            with contextlib.suppress(Exception) {
                server.wait(timeout=2);
            }
        }
        mongo_container.stop();
        time.sleep(0.5);
        gc.collect();

        if data_dir.exists() {
            import shutil;
            shutil.rmtree(data_dir);
        }
    }
}

test "data persists after server restart for sqlite" {
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    # Ensure no MongoDB or Redis environment variables are set (SQLite-only mode)
    env_backup = {};
    for key in ["MONGODB_URI", "REDIS_URL"] {
        if key in os.environ {
            env_backup[key] = os.environ[key];
            del os.environ[key];
        }
    }

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        # Create a task
        res = requests.post(
            f"{base_url}/walker/CreateTask",
            json={"id": 401, "title": "Persist me across restart"},
            timeout=2
        );
        assert res.status_code == 200 , f"Task creation failed: {res.status_code} - {res.text}";

        # Verify task exists before restart
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        response_data = cast(
            dict[str, Any], extract_transport_response_data(res.json())
        );
        tasks_before = response_data["reports"][0];
        assert len(tasks_before) == 1 , f"Should have 1 task before restart, got {len(
            tasks_before
        )}";
        assert tasks_before[0]["id"] == 401 , f"Task id should be 401, got {tasks_before[
            0
        ]['id']}";
        assert tasks_before[0]["title"] == "Persist me across restart" , f"Task title mismatch: {tasks_before[
            0
        ]['title']}";

        # Restart server
        server.terminate();
        server.wait(timeout=2);
        server = start_server(FIXTURES_DIR, JAC_FILE, port);

        # Verify task persists after restart
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        assert res.status_code == 200 , f"Post-restart request failed: {res.status_code}";
        response_data = cast(
            dict[str, Any], extract_transport_response_data(res.json())
        );
        tasks_after = response_data["reports"][0];
        assert len(tasks_after) == 1 , f"Task should persist after SQLite restart, got {len(
            tasks_after
        )}";
        assert tasks_after[0]["id"] == 401 , f"Task id should be 401 after restart, got {tasks_after[
            0
        ]['id']}";
        assert tasks_after[0]["title"] == "Persist me across restart" , f"Task title mismatch after restart: {tasks_after[
            0
        ]['title']}";
    } finally {
        if server {
            server.terminate();
            with contextlib.suppress(Exception) {
                server.wait(timeout=2);
            }
        }

        # Restore environment variables
        for (key, value) in env_backup.items() {
            os.environ[key] = value;
        }

        time.sleep(0.5);
        gc.collect();

        if data_dir.exists() {
            import shutil;
            shutil.rmtree(data_dir);
        }
    }
}

test "concurrent requests get isolated L1 caches" {
    # Validates: 10 parallel requests create unique tasks with no L1 cross-contamination
    import concurrent.futures;

    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    os.environ["MONGODB_URI"] = mongo_container.get_connection_url();

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        def create_task(task_id: int) -> int {
            res = requests.post(
                f"{base_url}/walker/CreateTask",
                json={"id": task_id, "title": f"Task {task_id}"},
                timeout=5
            );
            assert res.status_code == 200 , f"Failed to create task {task_id}: {res.text}";
            return task_id;
        }

        # 10 parallel requests
        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor {
            created_ids = list(executor.map(create_task, range(10)));
        }

        assert len(created_ids) == 10 , f"Only created {len(created_ids)} tasks";

        # Verify all 10 unique tasks persisted
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        response_data = extract_transport_response_data(res.json());
        all_tasks = cast(dict[str, Any], response_data)["reports"][0];
        task_ids = {t["id"] for t in all_tasks};
        assert task_ids == set(range(10)) , f"Expected IDs 0-9, got {len(
            all_tasks
        )} tasks: {sorted(task_ids)}";
    } finally {
        server.terminate();
        with contextlib.suppress(Exception) {
            server.wait(timeout=2);
        }
        mongo_container.stop();
        gc.collect();

        if data_dir.exists() {
            import shutil;
            shutil.rmtree(data_dir);
        }
    }
}

test "sequential requests work correctly" {
    # Validates: Multiple sequential requests don't cause crashes or data corruption
    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    os.environ["MONGODB_URI"] = mongo_container.get_connection_url();

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        # Make 5 sequential requests - all should succeed
        for i in range(5) {
            res = requests.post(
                f"{base_url}/walker/CreateTask",
                json={"id": i, "title": f"Sequential {i}"},
                timeout=5
            );
            assert res.status_code == 200 , f"Request {i} failed";
        }

        # Verify all 5 tasks were created
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        all_tasks = cast(dict[str, Any], extract_transport_response_data(res.json()))[
            "reports"
        ][0];
        assert len(all_tasks) == 5 , f"Expected 5 tasks, got {len(all_tasks)}";
    } finally {
        server.terminate();
        with contextlib.suppress(Exception) {
            server.wait(timeout=2);
        }
        mongo_container.stop();
        gc.collect();
    }
}

test "concurrent writes persist all data" {
    # Validates: 15 parallel writes (5 batches × 3 tasks) all persist to MongoDB
    import concurrent.futures;

    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    os.environ["MONGODB_URI"] = mongo_container.get_connection_url();
    if "REDIS_URL" in os.environ {
        del os.environ["REDIS_URL"];
    }

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        def create_batch(start: int) -> None {
            for i in range(3) {
                requests.post(
                    f"{base_url}/walker/CreateTask",
                    json={"id": start + i, "title": f"Task {start + i}"},
                    timeout=5
                );
            }
        }

        # 5 parallel batches of 3 tasks each
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor {
            list(executor.map(create_batch, [0, 3, 6, 9, 12]));
        }

        # Verify all 15 unique tasks persisted
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        all_tasks = cast(dict[str, Any], extract_transport_response_data(res.json()))[
            "reports"
        ][0];
        task_ids = {t["id"] for t in all_tasks};
        assert len(task_ids) == 15 , f"Expected 15 unique tasks, got {len(task_ids)}: {sorted(
            task_ids
        )}";
    } finally {
        server.terminate();
        with contextlib.suppress(Exception) {
            server.wait(timeout=2);
        }
        mongo_container.stop();
        gc.collect();
    }
}
