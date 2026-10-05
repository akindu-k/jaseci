"""The reverse direction: the caller writes its own copy while another context is pushed."""
import from jaclang { JacRuntime as Jac }

node Counter {
    has n: int = 0;
}

with entry {
    import jaclang;
    import from uuid { UUID }
    import from jaclang.runtime.archetype { Anchor }
    print("jaclang from:", jaclang.__file__, "| anchor binding present:", hasattr(Anchor, "bind_memory"));
    here: any = root ++> Counter();
    mine: any = Jac.get_context().mem;
    mine.commit();
    cid = jid(here);
    held: any = jobj(cid);

    bg: any = Jac.create_j_context(user_root=jid(root));
    tok = Jac.push_request_context(bg);
    try {
        theirs: any = jobj(cid);
        print("same object:", theirs is held);
        held.n = 5;
        d_bg = getattr(bg.mem, "_dirty", None);
        d_me = getattr(mine, "_dirty", None);
        print("write recorded in background session:", (UUID(cid) in d_bg) if d_bg is not None else "n/a",
              "| in caller session:", (UUID(cid) in d_me) if d_me is not None else "n/a");
        bg_err = "";
        try {
            bg.mem.commit();
        } except Exception as e {
            bg_err = f"{type(e).__name__}: {e}";
        }
        print("background commit:", bg_err or "ok");
    } finally {
        Jac.reset_request_context(tok);
        bg.close();
    }

    err = "";
    try {
        mine.commit();
    } except Exception as e {
        err = f"{type(e).__name__}: {e}";
    }
    print("caller commit:", err or "ok");

    fresh: any = Jac.create_j_context(user_root=jid(root));
    t2 = Jac.push_request_context(fresh);
    try {
        stored: any = jobj(cid);
        print("stored n:", stored.n, "(want 5)");
        ok = (not err) and (not bg_err) and stored.n == 5;
    } finally {
        Jac.reset_request_context(t2);
    }
    print("VERDICT caller_writes:", "PASS" if ok else "FAIL");
}
