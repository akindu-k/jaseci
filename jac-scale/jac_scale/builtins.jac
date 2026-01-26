"""
Builtin features for Jac Scale.
"""
import from typing { Any }

"""
Decorator to configure HTTP endpoint specifications for a walker.

:param path: Custom URL path for the walker endpoint.
:param method: HTTP method (POST, GET, PUT, DELETE, etc.). Default is "POST".
"""
def meta(path: str, method: str = "POST") -> Any {
    def decorator(cls: Any) -> Any {
        cls._meta__ = {'path': path, 'method': method};
        return cls;
    }
    return decorator;
}
