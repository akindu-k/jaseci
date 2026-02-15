"""Small social graph fixture for kvstore serialization tests.

Graph shape:  Root --> User --> Post
              (each User can have multiple Posts)
"""
import from jac_scale.lib { kvstore }

node User {
    has name: str,
        role: str,
        age: int;
}

node Post {
    has title: str,
        content: str;
}

walker BuildGraph {
    """Build a small social graph and persist each node via kvstore MongoDB."""
    has mongo_uri: str;

    can build with Root entry {
        db = kvstore(db_name='social', db_type='mongodb', uri=self.mongo_uri);

        alice = here ++> User(name='Alice', role='admin', age=30);
        bob = here ++> User(name='Bob', role='user', age=25);

        p1 = alice ++> Post(title='Hello World', content='My first post');
        p2 = alice ++> Post(title='Jac is cool', content='Graph programming rocks');
        p3 = bob ++> Post(title='Getting started', content='Learning Jac today');

        # Persist each node's fields in MongoDB via kvstore
        for user in [-->User] {
            db.set(
                user.name,
                {'name': user.name, 'role': user.role, 'age': user.age},
                'users'
            );
        }
        for post in [-->User-->Post] {
            db.set(post.title, {'title': post.title, 'content': post.content}, 'posts');
        }

        report {'users': 2, 'posts': 3};
    }
}

walker QueryGraph {
    """Retrieve persisted nodes from kvstore and report them."""
    has mongo_uri: str;

    can query with Root entry {
        db = kvstore(db_name='social', db_type='mongodb', uri=self.mongo_uri);

        alice = db.get('Alice', 'users');
        admins = list(db.find('users', {'role': 'admin'}));
        young = list(db.find('users', {'age': {'$lt': 28}}));
        posts = list(db.find('posts', {}));

        report {'alice': alice, 'admins': admins, 'young': young, 'posts': posts};
    }
}
