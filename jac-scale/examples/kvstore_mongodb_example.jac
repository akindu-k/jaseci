"""Example: Using kvstore with local MongoDB Docker container.

Prerequisites:
    1. Start MongoDB container:
       docker run -d -p 27017:27017 --name mongodb mongo:latest

    2. Or with authentication:
       docker run -d -p 27017:27017 --name mongodb \
         -e MONGO_INITDB_ROOT_USERNAME=admin \
         -e MONGO_INITDB_ROOT_PASSWORD=password \
         mongo:latest

Usage:
    jac run kvstore_mongodb_example.jac
"""

import from jac_scale.lib { kvstore }

with entry {
    # Connect to local MongoDB Docker container
    # Default MongoDB port is 27017
    mongo_db = kvstore(
        db_name='my_application',
        db_type='mongodb',
        uri='mongodb://localhost:27017'
    );

    print("✅ Connected to MongoDB container at localhost:27017");

    # Example 1: Insert a user document
    print("\n📝 Example 1: Inserting a user...");
    user_doc = {
        'name': 'Alice Johnson',
        'email': 'alice@example.com',
        'age': 28,
        'role': 'engineer',
        'skills': ['Python', 'Jac', 'MongoDB']
    };
    insert_result = mongo_db.insert_one('users', user_doc);
    user_id = str(insert_result.inserted_id);
    print(f"   Inserted user with ID: {user_id}");

    # Example 2: Find the user by ID
    print("\n🔍 Example 2: Finding user by ID...");
    found_user = mongo_db.find_by_id('users', user_id);
    if found_user {
        print(f"   Found: {found_user['name']} ({found_user['email']})");
        print(f"   Skills: {', '.join(found_user['skills'])}");
    }

    # Example 3: Update the user
    print("\n✏️  Example 3: Updating user...");
    update_result = mongo_db.update_by_id(
        'users',
        user_id,
        {'$set': {'age': 29, 'role': 'senior engineer'}}
    );
    print(f"   Modified {update_result.modified_count} document(s)");

    # Example 4: Insert multiple products
    print("\n📦 Example 4: Inserting multiple products...");
    products = [
        {'name': 'Laptop', 'price': 999.99, 'stock': 50},
        {'name': 'Mouse', 'price': 29.99, 'stock': 200},
        {'name': 'Keyboard', 'price': 79.99, 'stock': 150}
    ];
    bulk_result = mongo_db.insert_many('products', products);
    print(f"   Inserted {len(bulk_result.inserted_ids)} products");

    # Example 5: Update multiple products (price increase)
    print("\n💰 Example 5: Updating product prices...");
    update_many_result = mongo_db.update_many(
        'products',
        {'stock': {'$gt': 100}},  # Products with stock > 100
        {'$inc': {'price': 5.00}}  # Increase price by $5
    );
    print(f"   Updated {update_many_result.modified_count} products");

    # Example 6: Query with filter
    print("\n🔍 Example 6: Finding users by role...");
    engineers = mongo_db.find_one('users', {'role': 'senior engineer'});
    if engineers {
        print(f"   Found: {engineers['name']} - {engineers['role']}");
    }

    # Example 7: Delete a document
    print("\n🗑️  Example 7: Deleting user...");
    delete_result = mongo_db.delete_by_id('users', user_id);
    print(f"   Deleted {delete_result.deleted_count} document(s)");

    # Verify deletion
    deleted_user = mongo_db.find_by_id('users', user_id);
    print(f"   User exists after deletion: {deleted_user is not None}");

    # Example 8: Upsert operation
    print("\n🔄 Example 8: Upsert (insert if not exists)...");
    upsert_result = mongo_db.update_by_id(
        'settings',
        'app_config',
        {'$set': {'theme': 'dark', 'notifications': True}},
        upsert_mode=True
    );
    if upsert_result.upserted_id {
        print(f"   Created new document with ID: {upsert_result.upserted_id}");
    } else {
        print(f"   Updated existing document");
    }

    print("\n✨ Example completed successfully!");
}
