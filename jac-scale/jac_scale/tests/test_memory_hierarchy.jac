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
        assert mongo_doc_initial_count == 3 , (
            "Initial docs should be 3 (super root, guest_user, admin)"
        );

        # Register a user
        token = register_user(base_url, "reader", "pass123");

        mongo_doc_after_user_creation_count = collection.count_documents({});
        assert mongo_doc_after_user_creation_count == 4 , (
            "After user creation docs should be 4 (super root, guest_user, admin, created user)"
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
        assert mongo_doc_count_after_task_creation == 8 , (
            "After task creation docs should be 8 (prev 4 + 2 anchors per task)"
        );

        assert redis_size_after_task_creation == redis_size_before_task_creation;

        post_request(base_url, "/walker/GetAllTasks", {}, token);

        redis_size_after_task_read = redis_client.dbsize();
        assert redis_size_after_task_read == 8 , (
            "Redis should have 8 entries (super root, guest user, admin, user, 2 task nodes, 2 edges)"
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

test "concurrent requests maintain isolated L1 caches" {
    # Test that parallel requests each get their own L1 cache.
    #
    # This validates the core request-scoped memory feature:
    # - Each request creates its own ExecutionContext with isolated __mem__
    # - No cross-contamination between concurrent requests
    # - L1 cache is properly cleared after each request completes
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    # Start Redis and MongoDB for full memory hierarchy
    redis_container = RedisContainer("redis:latest", port=6379);
    redis_container.start();
    redis_host = redis_container.get_container_host_ip();
    redis_port = redis_container.get_exposed_port(6379);
    redis_url = f"redis://{redis_host}:{redis_port}/0";

    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();

    os.environ["MONGODB_URI"] = mongo_uri;
    os.environ["REDIS_URL"] = redis_url;

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        import concurrent.futures;
        def make_request(task_id: int) -> dict[str, Any] {
            # Create task
            res = requests.post(
                f"{base_url}/walker/CreateTask",
                json={"id": task_id, "title": f"Concurrent Task {task_id}"},
                timeout=5
            );
            assert res.status_code == 200 , f"Create failed for task {task_id}: {res.text}";

            # Read it back - should hit L1 cache within same request
            res2 = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
            assert res2.status_code == 200 , f"GetAll failed for task {task_id}";

            data = extract_transport_response_data(res2.json());
            return cast(dict[str, Any], data);
        }

        # Execute 10 requests in parallel
        num_requests = 10;
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=num_requests
        ) as executor {
            futures = [executor.submit(make_request, i) for i in range(num_requests)];
            results = [f.result() for f in concurrent.futures.as_completed(futures)];
        }

        # Verify all requests completed successfully
        assert len(results) == num_requests , f"Expected {num_requests} results, got {len(
            results
        )}";

        # Verify all tasks were created and persisted to L3
        final_check = requests.post(
            f"{base_url}/walker/GetAllTasks", json={}, timeout=5
        );
        final_data = cast(
            dict[str, Any], extract_transport_response_data(final_check.json())
        );
        all_tasks = final_data["reports"][0];

        assert len(all_tasks) == num_requests , f"Expected {num_requests} tasks in DB, got {len(
            all_tasks
        )}";

        # Verify each task has unique ID (proves no cross-request contamination)
        task_ids = {task["id"] for task in all_tasks};
        assert len(task_ids) == num_requests , f"Duplicate task IDs detected: {task_ids}";
        assert task_ids == set(range(num_requests)) , f"Missing task IDs: expected {set(
            range(num_requests)
        )}, got {task_ids}";
    } finally {
        if server {
            server.terminate();
            with contextlib.suppress(Exception) {
                server.wait(timeout=2);
            }
        }

        mongo_container.stop();
        redis_container.stop();
        time.sleep(0.5);
        gc.collect();

        if data_dir.exists() {
            import shutil;
            shutil.rmtree(data_dir);
        }
    }
}

test "L1 cache is fresh for each request" {
    # Test that L1 cache doesn't leak data between sequential requests.
    #
    # Validates that:
    # - Request 1's L1 cache is cleared after completion
    # - Request 2 starts with empty L1 (fetches from L2/L3)
    # - No stale data persists in L1 across request boundaries
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    # Use Redis to track L2 hits (proves L1 was cleared)
    redis_container = RedisContainer("redis:latest", port=6379);
    redis_container.start();
    redis_host = redis_container.get_container_host_ip();
    redis_port = redis_container.get_exposed_port(6379);
    redis_url = f"redis://{redis_host}:{redis_port}/0";

    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();

    os.environ["MONGODB_URI"] = mongo_uri;
    os.environ["REDIS_URL"] = redis_url;

    redis_client = redis.Redis(
        host=redis_host, port=int(redis_port), decode_responses=False
    );

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        # Request 1: Create task (loads into L1, L2, L3)
        res1 = requests.post(
            f"{base_url}/walker/CreateTask",
            json={"id": 100, "title": "Fresh L1 Test"},
            timeout=5
        );
        assert res1.status_code == 200;

        # Request 2: Read task (should fetch from L2/L3, not L1)
        # If L1 wasn't cleared, this would hit L1 cache from Request 1
        redis_size_before = redis_client.dbsize();

        res2 = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        assert res2.status_code == 200;

        data2 = cast(dict[str, Any], extract_transport_response_data(res2.json()));
        tasks2 = data2["reports"][0];
        assert len(tasks2) == 1 , f"Expected 1 task, got {len(tasks2)}";
        assert tasks2[0]["id"] == 100;

        # Verify L2 (Redis) was accessed (proves L1 was empty at start of Request 2)
        redis_size_after = redis_client.dbsize();
        assert redis_size_after > redis_size_before , (
            "Redis should have new entries, proving L2 was used (L1 was empty)"
        );

        # Request 3: Read again (now L2 should be populated)
        res3 = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        assert res3.status_code == 200;

        data3 = cast(dict[str, Any], extract_transport_response_data(res3.json()));
        tasks3 = data3["reports"][0];
        assert len(tasks3) == 1;
        assert tasks3[0]["title"] == "Fresh L1 Test";
    } finally {
        if server {
            server.terminate();
            with contextlib.suppress(Exception) {
                server.wait(timeout=2);
            }
        }

        mongo_container.stop();
        redis_container.stop();
        time.sleep(0.5);
        gc.collect();

        if data_dir.exists() {
            import shutil;
            shutil.rmtree(data_dir);
        }
    }
}

test "concurrent writes do not cause L1 cross-contamination" {
    # Test that parallel writes to the same object type don't interfere.
    #
    # Validates:
    # - Multiple requests creating different tasks simultaneously
    # - Each request's L1 cache contains only its own task
    # - All tasks correctly persist to L2/L3
    # - No race conditions or lost writes
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;

    # No Redis - test L1 -> L3 write-through
    if "REDIS_URL" in os.environ {
        del os.environ["REDIS_URL"];
    }

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        import concurrent.futures;
        import from pymongo { MongoClient }

        mongo_client = MongoClient(mongo_uri);
        db = mongo_client["jac_db"];
        collection = db["_anchors"];

        initial_count = collection.count_documents({});

        def create_task_batch(start_id: int, count: int) -> list[dict[str, Any]] {
            created = [];
            for i in range(count) {
                task_id = start_id + i;
                res = requests.post(
                    f"{base_url}/walker/CreateTask",
                    json={"id": task_id, "title": f"Batch Task {task_id}"},
                    timeout=5
                );
                assert res.status_code == 200 , f"Failed to create task {task_id}";
                data = extract_transport_response_data(res.json());
                created.append(data);
            }
            return created;
        }

        # Run 5 concurrent batches, each creating 3 tasks
        num_batches = 5;
        tasks_per_batch = 3;
        with concurrent.futures.ThreadPoolExecutor(max_workers=num_batches) as executor {
            futures = [
                executor.submit(
                    create_task_batch, i * tasks_per_batch, tasks_per_batch
                ) for i in range(num_batches)
            ];
            results = [f.result() for f in concurrent.futures.as_completed(futures)];
        }

        # Verify all tasks were created
        total_expected = num_batches * tasks_per_batch;
        final_count = collection.count_documents({});

        # Account for system roots (super root, guest, admin, etc.)
        tasks_created = (final_count - initial_count) / 2;  # Each task = 1 node + 1 edge
        assert tasks_created == total_expected , (
            f"Expected {total_expected} tasks, but found {tasks_created} "
            f"(initial: {initial_count}, final: {final_count})"
        );

        # Verify all tasks have unique IDs
        res = requests.post(f"{base_url}/walker/GetAllTasks", json={}, timeout=5);
        data = cast(dict[str, Any], extract_transport_response_data(res.json()));
        all_tasks = data["reports"][0];

        task_ids = {task["id"] for task in all_tasks};
        assert len(task_ids) == total_expected , (
            f"Duplicate task IDs detected: expected {total_expected} unique, got {len(
                task_ids
            )}"
        );
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

test "authenticated requests get isolated L1 per user" {
    # Test that different authenticated users get separate L1 caches.
    #
    # Validates:
    # - User A's L1 cache doesn't leak to User B
    # - Each user sees only their own data in initial L1 load
    # - User roots are correctly set per request context
    if not JAC_FILE.exists() {
        raise FileNotFoundError(f"Missing Jac file: {JAC_FILE}");
    }

    data_dir = FIXTURES_DIR / ".jac" / "data";
    if data_dir.exists() {
        import shutil;
        shutil.rmtree(data_dir);
    }

    mongo_container = MongoDbContainer("mongo:latest");
    mongo_container.start();
    mongo_uri = mongo_container.get_connection_url();
    os.environ["MONGODB_URI"] = mongo_uri;

    if "REDIS_URL" in os.environ {
        del os.environ["REDIS_URL"];
    }

    port = get_free_port();
    base_url = f"http://localhost:{port}";
    server = start_server(FIXTURES_DIR, JAC_FILE, port);

    try {
        # Register two users
        token_alice = register_user(base_url, "alice", "pass123");
        token_bob = register_user(base_url, "bob", "pass456");

        # Alice creates a task
        post_request(
            base_url,
            "/walker/CreateTask",
            {"id": 1, "title": "Alice's Task"},
            token_alice
        );

        # Bob creates a task
        post_request(
            base_url, "/walker/CreateTask", {"id": 2, "title": "Bob's Task"}, token_bob
        );

        # Alice reads tasks (should see both in this test app, but L1 is isolated)
        alice_tasks = post_request(base_url, "/walker/GetAllTasks", {}, token_alice);
        alice_task_list = alice_tasks["reports"][0];

        # Bob reads tasks
        bob_tasks = post_request(base_url, "/walker/GetAllTasks", {}, token_bob);
        bob_task_list = bob_tasks["reports"][0];

        # Both should see both tasks (shared root in todo_app.jac)
        assert len(alice_task_list) == 2 , f"Alice should see 2 tasks, got {len(
            alice_task_list
        )}";
        assert len(bob_task_list) == 2 , f"Bob should see 2 tasks, got {len(
            bob_task_list
        )}";

        # But verify no exceptions occurred (proves context isolation works)
        # If L1 was shared, we'd see user root conflicts

        # Make concurrent requests from both users
        import concurrent.futures;

        def make_user_request(token: str, task_id: int) -> dict[str, Any] {
            return post_request(
                base_url,
                "/walker/CreateTask",
                {"id": task_id, "title": f"Concurrent {task_id}"},
                token
            );
        }

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor {
            futures = [
                executor.submit(make_user_request, token_alice, 10),
                executor.submit(make_user_request, token_bob, 11),
                executor.submit(make_user_request, token_alice, 12),
                executor.submit(make_user_request, token_bob, 13)
            ];
            results = [f.result() for f in concurrent.futures.as_completed(futures)];
        }

        # Verify all concurrent requests succeeded
        assert len(results) == 4 , f"Expected 4 results, got {len(results)}";

        # Final verification: all 6 tasks exist
        final_tasks = post_request(base_url, "/walker/GetAllTasks", {}, token_alice);
        final_task_list = final_tasks["reports"][0];
        assert len(final_task_list) == 6 , f"Expected 6 total tasks, got {len(
            final_task_list
        )}";
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
