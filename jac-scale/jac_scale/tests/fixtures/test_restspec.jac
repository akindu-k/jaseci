"""Test API fixture for restspec decorator tests."""

import from jaclang.runtimelib.builtin { restspec }
import from http { HTTPMethod }

# ============================================================================
# RestSpec Decorator Tests
# ============================================================================
"""Walker with GET method via restspec decorator."""
@restspec(method=HTTPMethod.GET)
walker:pub GetWalker {
    can get_data with Root entry {
        report {"message": "GetWalker executed", "method": "GET"};
    }
}

"""Walker with custom path."""
@restspec(method=HTTPMethod.GET, path="/custom/walker")
walker:pub CustomPathWalker {
    can get_data with Root entry {
        report {"message": "CustomPathWalker executed", "path": "/custom/walker"};
    }
}

"""Function with GET method via restspec decorator."""
@restspec(method=HTTPMethod.GET)
def get_func -> dict {
    return {"message": "get_func executed", "method": "GET"};
}

"""Function with custom path."""
@restspec(method=HTTPMethod.GET, path="/custom/func")
def custom_path_func -> dict {
    return {"message": "custom_path_func executed", "path": "/custom/func"};
}

"""Walker with POST method via restspec decorator."""
@restspec(method=HTTPMethod.POST)
walker:pub PostWalker {
    can post_data with Root entry {
        report {"message": "PostWalker executed", "method": "POST"};
    }
}

"""Walker with default method (POST)."""
walker:pub DefaultWalker {
    can post_data with Root entry {
        report {"message": "DefaultWalker executed", "method": "DEFAULT"};
    }
}

"""Function with POST method via restspec decorator."""
@restspec(method=HTTPMethod.POST)
def post_func -> dict {
    return {"message": "post_func executed", "method": "POST"};
}

"""Function with default method (POST)."""
def default_func -> dict {
    return {"message": "default_func executed", "method": "DEFAULT"};
}

"""Walker with GET method and parameters."""
@restspec(method=HTTPMethod.GET)
walker:pub GetWalkerWithParams {
    has name: str,
        age: int;

    can get_data with Root entry {
        report {
            "message": "GetWalkerWithParams executed",
            "name": self.name,
            "age": self.age
        };
    }
}

"""Function with GET method and parameters."""
@restspec(method=HTTPMethod.GET)
def get_func_with_params(name: str, age: int) -> dict {
    return {"message": "get_func_with_params executed", "name": name, "age": age};
}

# ============================================================================
# Path Parameter Tests (regression for @restspec path param bug)
# ============================================================================
"""Function with a single path parameter."""
@restspec(method=HTTPMethod.GET, path="/items/{item_id}")
def get_item(item_id: str) -> dict {
    return {"message": "get_item executed", "item_id": item_id};
}

"""Function with a path parameter plus additional query parameters."""
@restspec(method=HTTPMethod.GET, path="/users/{user_id}/orders")
def get_user_orders(user_id: str, status: str = "all") -> dict {
    return {
        "message": "get_user_orders executed",
        "user_id": user_id,
        "status": status
    };
}

"""Function with multiple path parameters."""
@restspec(method=HTTPMethod.GET, path="/orgs/{org_id}/repos/{repo_id}")
def get_org_repo(org_id: str, repo_id: str) -> dict {
    return {"message": "get_org_repo executed", "org_id": org_id, "repo_id": repo_id};
}

"""POST function with a path parameter and body parameters."""
@restspec(method=HTTPMethod.POST, path="/resources/{resource_id}/update")
def update_resource(resource_id: str, name: str, value: int) -> dict {
    return {
        "message": "update_resource executed",
        "resource_id": resource_id,
        "name": name,
        "value": value
    };
}

"""Walker with a path parameter in its restspec path."""
@restspec(method=HTTPMethod.GET, path="/nodes/{node_id}")
walker:pub GetNodeWalker {
    has node_id: str;

    can get_data with Root entry {
        report {"message": "GetNodeWalker executed", "node_id": self.node_id};
    }
}

"""Walker with multiple path parameters in its restspec path."""
@restspec(method=HTTPMethod.GET, path="/projects/{project_id}/tasks/{task_id}")
walker:pub GetProjectTaskWalker {
    has project_id: str,
        task_id: str;

    can get_data with Root entry {
        report {
            "message": "GetProjectTaskWalker executed",
            "project_id": self.project_id,
            "task_id": self.task_id
        };
    }
}

# ============================================================================
# Custom Object Tests (Pydantic model generation from Jac classes)
# ============================================================================
"""Custom Jac object for testing automatic Pydantic model generation."""
obj Person {
    has name: str,
        age: int,
        email: str = "no-email@example.com";
}

"""Nested custom object to test recursive model creation."""
obj Address {
    has street: str,
        city: str,
        zip_code: str = "00000";
}

"""Object with nested custom type."""
obj Contact {
    has person: Person,
        address: Address;
}

"""Walker that accepts a custom object as input via POST."""
@restspec(method=HTTPMethod.POST)
walker:pub CreatePersonWalker {
    has person: Person;

    can process with Root entry {
        report {
            "message": "Person created via walker",
            "person_name": self.person.name,
            "person_age": self.person.age,
            "person_email": self.person.email
        };
    }
}

"""Function that accepts a custom object as parameter."""
@restspec(method=HTTPMethod.POST)
def create_person(person: Person) -> dict {
    return {
        "message": "Person created via function",
        "name": person.name,
        "age": person.age,
        "email": person.email
    };
}

"""Function with nested custom objects."""
@restspec(method=HTTPMethod.POST)
def create_contact(contact: Contact) -> dict {
    return {
        "message": "Contact created",
        "person_name": contact.person.name,
        "address_city": contact.address.city
    };
}

"""Walker with mixed parameters: primitive and custom object."""
@restspec(method=HTTPMethod.POST)
walker:pub RegisterUserWalker {
    has username: str,
        person: Person,
        is_admin: bool = False;

    can process with Root entry {
        report {
            "message": "User registered",
            "username": self.username,
            "person_name": self.person.name,
            "is_admin": self.is_admin
        };
    }
}
