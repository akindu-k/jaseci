import socket
import subprocess
from pathlib import Path
from testcontainers.redis import RedisContainer
from testcontainers.mongodb import MongoDbContainer
import redis
from pymongo import MongoClient
import contextlib
import time
import gc
import requests
import os
import textwrap


def get_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("",0))
        return s.getsockname()[1] 
    
class TestMemoryHierarchy:

    fixtures_dir: Path
    jac_file: Path
    base_url: str
    port: int

    redis_container: RedisContainer
    mongo_container: MongoDbContainer
    server: subprocess.Popen[str] | None = None

    @classmethod
    def setup_class(cls) -> None:
        cls.fixtures_dir = Path(__file__).parent / "fixtures"
        cls.jac_file = cls.fixtures_dir / "todo_app.jac"

        cls.config_file = cls.fixtures_dir / "jac.toml"

        if not cls.jac_file.exists():
            raise FileNotFoundError(f"Missing Jac file: {cls.jac_file}")
        
        # start redis container
        cls.redis_container = RedisContainer("redis:latest",port=6379)
        cls.redis_container.start()

        redis_host = cls.redis_container.get_container_host_ip()
        redis_port = cls.redis_container.get_exposed_port(6379)

        redis_url = f"redis://{redis_host}:{redis_port}/0"

        cls.redis_client = redis.Redis(
            host=redis_host,
            port=int(redis_port),
            decode_responses=True
        )
        print(f"redis db size: {cls.redis_client.dbsize()}")
        assert cls.redis_client.dbsize() == 0


        cls.mongo_container = MongoDbContainer("mongo:latest")
        cls.mongo_container.start()

        mongo_uri = cls.mongo_container.get_connection_url()
        cls.mongo_client = MongoClient(mongo_uri)

        print(f"printing mongo uri{mongo_uri}")
        print(f"printing redis url {redis_url}")

        # toml_content = textwrap.dedent(f"""
        # [plugins.scale.database]
        # mongodb_uri = "${mongo_uri}"
        # redis_url = "${redis_url}"
        # """).strip()

        # with open(cls.config_file, "w") as f:
        #             f.write(toml_content)

        os.environ["mongodb_uri"] = mongo_uri
        os.environ["redis_url"] = redis_url

        system_dbs = {'admin', 'config', 'local'}
        current_dbs = set(cls.mongo_client.list_database_names())

        print(f"printing current dbs {current_dbs}")

        # Assert that current_dbs only contains system databases (or fewer)
        assert current_dbs.issubset(system_dbs), f"Found unexpected user databases: {current_dbs - system_dbs}"

        # setting up
        cls.port = get_free_port()
        cls.base_url = f"http://localhost:{cls.port}"


        cls._start_server()
    
    @classmethod
    def teardown_class(cls) -> None:
        if cls.server:
            cls.server.terminate()
            with contextlib.suppress(Exception):
                cls.server.wait(timeout=5)

        cls.mongo_container.stop()
        cls.redis_container.stop()

        # removing the config file
        # if (hasattr(cls, 'config_file') and cls.config_file.exists()):
        #     cls.config_file.unlink()

        time.sleep(0.5)
        gc.collect()
    
    @classmethod
    def _start_server(cls) -> None:
        cmd = [
            
            "jac",
            "serve",
            str(cls.jac_file.name),
            "--port",
            str(cls.port),
        ]

        
        env = os.environ.copy()

        cls.server = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(cls.fixtures_dir),
            env=env
        )
        

        for _ in range(30):
            try:
                r = requests.get(f"{cls.base_url}/docs", timeout=1)
                if r.status_code in (200, 404):
                    return
            except Exception:
                time.sleep(1)

        stdout, stderr = cls.server.communicate(timeout=2)
        raise RuntimeError(
            f"jac serve failed to start\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}"
        )
    
        

    def _register(self, email: str) -> str:
        res = requests.post(
            f"{self.base_url}/user/register",
            json={"email": email, "password": "password123"},
            timeout=5,
        )
        assert res.status_code == 201
        return res.json()["token"]

    def _post(self, path: str, payload: dict, token: str) -> dict:
        res = requests.post(
            f"{self.base_url}{path}",
            json=payload,
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        assert res.status_code == 200
        return res.json()


    # def test_read_all_tasks(self) -> None:
    #         token = self._register("crud_read@example.com")

    #         self._post("/walker/CreateTask", {"id": 1, "title": "A"}, token)
    #         self._post("/walker/CreateTask", {"id": 2, "title": "B"}, token)

    #         res = self._post("/walker/GetAllTasks", {}, token)
    #         tasks = res["reports"][0]

    #         # assert len(tasks) == 2

    #         '''
    #         NEED TO FIX TASKS NOT GOING TO PERSISTENT ISSUE
    #         '''
            
    #         # --- NEW CODE TO VERIFY DB ---
    #         print("\n-------------------------------------------")
    #         print("Checking MongoDB after creating tasks...")
    #         all_dbs = self.mongo_client.list_database_names()
    #         print(f"Current Databases: {all_dbs}")
            
    #         # Check if we have a non-system database now
    #         user_dbs = set(all_dbs) - {'admin', 'config', 'local'}
    #         if user_dbs:
    #             print(f"SUCCESS! Found user data in: {user_dbs}")
    #         else:
    #             print("WARNING: No new database found. Is the server using the Mongo URI?")
    #         print("-------------------------------------------\n")

    #         print("\n>>> PINGING DATABASES <<<")

    def _print_mongo_state(self, max_docs_per_collection: int = 5) -> None:
        print("\n================= MONGO STATE DUMP =================")

        system_dbs = {"admin", "config", "local"}
        all_dbs = self.mongo_client.list_database_names()
        user_dbs = [db for db in all_dbs if db not in system_dbs]

        if not user_dbs:
            print("⚠️  No user databases found.")
            print("===================================================\n")
            

        for db_name in system_dbs:
            print(f"\n📦 Database: {db_name}")
            db = self.mongo_client[db_name]

            collections = db.list_collection_names()
            if not collections:
                print("  └── (no collections)")
                continue

            for coll_name in collections:
                collection = db[coll_name]
                count = collection.count_documents({})

                print(f"  📂 Collection: {coll_name}")
                print(f"     ├── Document count: {count}")

                if count == 0:
                    print("     └── (empty)")
                    continue

                print("     └── Sample documents:")
                for i, doc in enumerate(collection.find().limit(max_docs_per_collection), start=1):
                    print(f"         [{i}] {doc}")

        print("\n================ END MONGO STATE ===================\n")


    def test_read_all_tasks(self) -> None:
        token = self._register("ak@example.com")

        self._post("/walker/CreateTask", {"id": 1, "title": "A"}, token)
        self._post("/walker/CreateTask", {"id": 2, "title": "B"}, token)

        res = self._post("/walker/GetAllTasks", {}, token)
        tasks = res["reports"][0]

        # Debug persistent state
        self._print_mongo_state()

        
