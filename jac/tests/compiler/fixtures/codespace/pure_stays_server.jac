"""Native placement is never inferred.

Pure computation is native-COMPATIBLE, but compatibility never implies
placement: unmarked code defaults to server. Going native is an explicit
build choice (`na {}`, `.na.jac`, or nacompile auto-promotion of a target
module).
"""

def add(a: int, b: int) -> int {
    return a + b;
}

def mul_add(a: int, b: int, c: int) -> int {
    return add(a * b, c);
}
