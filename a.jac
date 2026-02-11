walker:pub mywalker {
    has user: User;
    can do with entry {
        report self.user;
    }
}


obj User {
    has name: str;
    has age: int;
}
