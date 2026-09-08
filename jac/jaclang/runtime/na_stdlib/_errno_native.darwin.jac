import from c { def __error -> int;  }
import from c { def memcpy(dst: bytes, src: int, n: u64) -> int;  }
import from c { def strerror(errnum: i32) -> str;  }


def:pub last_errno -> int {
    p = __error();
    b4 = b"\x00" * 4;
    memcpy(b4, p, 4);
    return int.from_bytes(b4, "little");
}


def:pub errno_message -> str {
    return strerror(i32(last_errno()));
}
