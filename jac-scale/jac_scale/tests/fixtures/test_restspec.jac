"""Test API fixture for restspec decorator tests."""

import from jaclang.runtimelib.builtin { restspec }
import from http { HTTPMethod }

# ============================================================================
# RestSpec Decorator Tests
# ============================================================================

"""Walker with GET method via restspec decorator."""
@restspec(method=HTTPMethod.GET)
walker : pub GetWalker {
    can get_data with `root entry {
        report {"message": "GetWalker executed", "method": "GET"};
    }
}

"""Walker with POST method via restspec decorator (Explicit)."""
@restspec(method=HTTPMethod.POST)
walker : pub PostWalker {
    has data: str = "";
    
    can post_data with `root entry {
        report {"message": "PostWalker executed", "data": self.data, "method": "POST"};
    }
}

"""Function with GET method via restspec decorator."""
@restspec(method=HTTPMethod.GET)
def get_func_test() -> dict {
    return {"message": "get_func_test executed", "method": "GET"};
}

"""Function with POST method via restspec decorator."""
@restspec(method=HTTPMethod.POST)
def post_func_test(data: str) -> dict {
    return {"message": "post_func_test executed", "data": data, "method": "POST"};
}

"""Walker with custom path."""
@restspec(method=HTTPMethod.GET, path="/custom/my_walker")
walker : pub CustomPathWalker {
    can get_data with `root entry {
        report {"message": "CustomPathWalker executed", "path": "/custom/my_walker"};
    }
}

"""Function with custom path."""
@restspec(method=HTTPMethod.GET, path="/custom/my_func")
def custom_path_func() -> dict {
    return {"message": "custom_path_func executed", "path": "/custom/my_func"};
}
