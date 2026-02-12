"""Test fixture for nested object arguments."""

obj Address {
    has street: str,
        zip: int;
}

obj User {
    has name: str,
        address: Address,
        tags: list[str] = [],
        metadata: dict[str, str] = {};
}

walker NestedWalker {
    has user: User;

    can start_node with entry {
        report {
            "name": self.user.name,
            "street": self.user.address.street,
            "zip": self.user.address.zip,
            "tags": self.user.tags,
            "metadata": self.user.metadata
        };
    }
}

walker NestedListWalker {
    has users: list[User];

    can start_node with entry {
        report [u.name for u in self.users];
    }
}
