import from jac_scale { meta }

@meta(path="/custom/walker", method="POST")
walker CustomWalker {
    can run with `root entry {
        report {"message": "Custom walker ran"};
    }
}

@meta(path="/custom/get", method="GET")
walker GetWalker {
    can run with `root entry {
        report {"message": "Get walker ran"};
    }
}

@meta(path="/custom/query", method="GET")
walker QueryWalker {
    has val: str;

    can run with `root entry {
        report {"message": "Query walker ran", "val": self.val};
    }
}
