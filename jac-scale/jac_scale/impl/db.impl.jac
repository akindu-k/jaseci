impl Db.find_one(col_name: str, filter: dict) -> dict | None {
    db = self.client[self.db_name];
    col = db[col_name];
    return col.find_one(filter);
}

impl Db.find(col_name: str, filter: dict) -> Any {
    db = self.client[self.db_name];
    col = db[col_name];
    return col.find(filter);
}

impl Db.insert_one(col_name: str, document: dict) -> Any {
    db = self.client[self.db_name];
    col = db[col_name];
    return col.insert_one(document);
}

impl Db.update_one(
    col_name: str, filter: dict, update_data: dict, upsert_mode: bool = False
) -> Any {
    db = self.client[self.db_name];
    col = db[col_name];
    return col.update_one(filter, update_data, upsert=upsert_mode);
}

impl Db.delete_one(col_name: str, filter: dict) -> Any {
    db = self.client[self.db_name];
    col = db[col_name];
    return col.delete_one(filter);
}

impl Db.commit -> None {
# No-op for MongoDB
}

def get_db -> Db {
    return Db();
}
