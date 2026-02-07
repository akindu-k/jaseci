"""Example: Using kvstore with MongoDB authentication and configuration.

Setup MongoDB with authentication:
    docker run -d -p 27017:27017 --name mongodb \
      -e MONGO_INITDB_ROOT_USERNAME=admin \
      -e MONGO_INITDB_ROOT_PASSWORD=secret123 \
      mongo:latest

Configuration Options:
    1. Explicit URI (shown below)
    2. Environment variable (export MONGODB_URI="mongodb://...")
    3. jac.toml configuration file

Usage:
    jac run kvstore_with_auth.jac
"""

import from jac_scale.lib { kvstore }

with entry {
    print("🔐 MongoDB Authentication Example\n");

    # Method 1: Direct URI with credentials
    print("Method 1: Using explicit URI with authentication");
    try {
        mongo_db = kvstore(
            db_name='secure_app',
            db_type='mongodb',
            uri='mongodb://admin:secret123@localhost:27017'
        );
        print("✅ Connected with authentication\n");

        # Create a sample document
        doc = {
            'service': 'payment_gateway',
            'status': 'active',
            'config': {
                'timeout': 30,
                'retry_count': 3
            }
        };
        result = mongo_db.insert_one('services', doc);
        print(f"📝 Inserted document: {result.inserted_id}\n");

    } except Exception as e {
        print(f"❌ Connection failed: {e}\n");
    }

    # Method 2: Using connection string with options
    print("Method 2: Connection string with additional options");
    try {
        mongo_db_with_options = kvstore(
            db_name='production_app',
            db_type='mongodb',
            uri='mongodb://admin:secret123@localhost:27017/?authSource=admin&retryWrites=true'
        );
        print("✅ Connected with custom options\n");

        # Demonstrate different collections in the same database
        collections = ['users', 'orders', 'inventory'];
        for collection in collections {
            doc = {'collection': collection, 'initialized': True};
            mongo_db_with_options.insert_one(collection, doc);
            print(f"   Initialized collection: {collection}");
        }
        print();

    } except Exception as e {
        print(f"❌ Connection failed: {e}\n");
    }

    # Method 3: Using environment variable (fallback)
    print("Method 3: Using environment variable (if MONGODB_URI is set)");
    print("Set MONGODB_URI environment variable:");
    print("  export MONGODB_URI='mongodb://admin:secret123@localhost:27017'\n");

    try {
        # If uri is not provided, it will use MONGODB_URI env var or jac.toml
        mongo_db_env = kvstore(
            db_name='my_app',
            db_type='mongodb'
            # No URI - will use environment variable or config file
        );
        print("✅ Connected using configuration fallback\n");

    } except Exception as e {
        print(f"ℹ️  Using fallback config: {e}\n");
    }

    print("\n💡 Best Practices:");
    print("   1. Use environment variables for production");
    print("   2. Never hardcode credentials in source code");
    print("   3. Use jac.toml for local development");
    print("   4. Enable authentication in production MongoDB");
}
