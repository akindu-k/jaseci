"""Debug-only probe for #10553: run the natively lowered list[any] sorts."""

import ctypes;
import from tests.support { compile_native, get_func }

test "debug 10553: native sorted(list[any]) returns its smallest element first" {
    (eng, _) = compile_native("debug_10553_sorted_any.jac");
    first = get_func(eng, "any_list_sorted", ctypes.c_int64)();
    print(f"PROBE any_list_sorted first element = {first} (Python gives 1)");
    assert first == 1 , f"native sorted(list[any]) returned {first} first, Python gives 1";
}
