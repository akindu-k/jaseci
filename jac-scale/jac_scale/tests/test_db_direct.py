import os

import pytest
from testcontainers.mongodb import MongoDbContainer


def close_mongo_client():
    try:
        import jac_scale.db as db_mod

        if hasattr(db_mod, "_client") and db_mod._client:
            db_mod._client.close()
            db_mod._client = None
    except ImportError:
        pass


class TestDirectDb:
    mongo_container: MongoDbContainer
    mongo_uri: str

    @classmethod
    def setup_class(cls):
        cls.mongo_container = MongoDbContainer("mongo:latest")
        cls.mongo_container.start()
        cls.mongo_uri = cls.mongo_container.get_connection_url()
        os.environ["MONGODB_URI"] = cls.mongo_uri

    @classmethod
    def teardown_class(cls):
        cls.mongo_container.stop()
        if "MONGODB_URI" in os.environ:
            del os.environ["MONGODB_URI"]

        close_mongo_client()

    def test_direct_db_access(self):
        try:
            from jac_scale.db import Db, get_db
        except ImportError:
            pytest.fail(
                "Could not import jac_scale.db. Make sure the jac file is compiled."
            )

        db = get_db()
        assert isinstance(db, Db)

        # Verify interactions
        col_name = "direct_access_test"
        doc = {"key": "value", "num": 42}

        # Insert
        insert_res = db.insert_one(col_name, doc)
        assert insert_res.inserted_id is not None

        # Find One
        found = db.find_one(col_name, {"key": "value"})
        assert found is not None
        assert found["num"] == 42

        # Find (Cursor)
        cursor = db.find(col_name, {"num": 42})
        results = list(cursor)
        assert len(results) == 1
        assert results[0]["key"] == "value"

        # Update
        update_res = db.update_one(col_name, {"key": "value"}, {"$set": {"num": 100}})
        assert update_res.modified_count == 1

        updated = db.find_one(col_name, {"key": "value"})
        assert updated["num"] == 100

        # Delete
        delete_res = db.delete_one(col_name, {"key": "value"})
        assert delete_res.deleted_count == 1

        deleted = db.find_one(col_name, {"key": "value"})
        assert deleted is None

    def test_commit_noop(self):
        from jac_scale.db import get_db

        db = get_db()
        db.commit()
