
    impl _find_user_by_token(token: str) -> (User | None) {
        for anc in self.memory.query(
            filter=lambda a: isinstance(a, NodeAnchor)
                             and isinstance(a.obj, User)
                             and a.obj.token == token
        ) {
            return anc.obj;
        }
        return None;
    }


        impl create_user(username: str, password: str) -> dict[str, str] {
        import hashlib, secrets;
        import from jaclang.pycore.constructs { Root };

        if self._find_user_by_username(username) {
            return {"error": "User already exists"};
        }

        root = Root();
        root_anchor = root.__jac__;
        Jac.save(root_anchor);
        Jac.commit(root_anchor);

        user = User(
            username=username,
            password_hash=hashlib.sha256(password.encode()).hexdigest(),
            token=secrets.token_urlsafe(32),
            root_id=root_anchor.id
        );

        user_anchor = user.__jac__;
        Jac.save(user_anchor);
        Jac.commit(user_anchor);

        return {
            "username": username,
            "token": user.token,
            "root_id": root_anchor.id.hex
        };
    }



        impl authenticate(username: str, password: str)
        -> (dict[str, str] | None) {

        import hashlib;

        user = self._find_user_by_username(username);
        if not user {
            return None;
        }

        if user.password_hash != hashlib.sha256(password.encode()).hexdigest() {
            return None;
        }

        return {
            "username": user.username,
            "token": user.token,
            "root_id": user.root_id.hex
        };
    }



        impl validate_token(token: str) -> (str | None) {
        user = self._find_user_by_token(token);
        return user.username if user else None;
    }


    impl get_root_id(username: str) -> (str | None) {
        user = self._find_user_by_username(username);
        return user.root_id.hex if user else None;
    }


    impl get_user(username: str) -> (dict[str, str] | None) {
        user = self._find_user_by_username(username);
        if not user {
            return None;
        }

        return {
            "email": user.username,
            "token": user.token,
            "root_id": user.root_id.hex
        };
    }










