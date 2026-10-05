"""#9381 from the user's side: a request and a background job, acting as the same user,
both update the same Counter. Uses only nodes, a walker, jid/jobj, commit() and the
runtime's "run as a user" context helpers that background workers use."""
import from jaclang { JacRuntime as Jac }

node Counter {
    has tag: str,
        n: int = 0;
}

walker SetCount {
    has tag: str,
        to: int;

    can start with Root entry {
        visit [-->];
    }

    can set with Counter entry {
        if here.tag == self.tag {
            here.n = self.to;
        }
    }
}

"""Run work as a user in its own context, the way a background worker does."""
def as_user(user_id: str, work: any) -> None {
    ctx = Jac.create_j_context(user_root=user_id);
    token = Jac.push_request_context(ctx);
    try {
        work();
        commit();
    } finally {
        Jac.reset_request_context(token);
        ctx.close();
    }
}

"""Read the stored value through a fresh context."""
def stored_n(user_id: str, counter_id: str) -> int {
    out = [0];
    def read -> None {
        c: any = jobj(counter_id);
        out[0] = c.n;
    }
    as_user(user_id, read);
    return out[0];
}

"""Save now and report a conflict instead of crashing."""
def try_commit -> str {
    try {
        commit();
    } except Exception as e {
        return f"{type(e).__name__}: {e}";
    }
    return "ok";
}

with entry {
    me = jid(root);

    # Case 1, as reported in #9381: the background job updates its own copy.
    c1 = root ++> Counter(tag="c1");
    commit();
    c1_id = jid(c1);
    def job1 -> None {
        root spawn SetCount(tag="c1", to=1);
    }
    as_user(me, job1);
    r1 = try_commit();
    n1 = stored_n(me, c1_id);
    print(f"case 1 (background job updates its copy): request commit = {r1}, stored n = {n1} (want 1)");

    # Case 2, the reverse: the request hands its own Counter to the background job,
    # which runs the walker on it while the job is running.
    c2 = root ++> Counter(tag="c2");
    commit();
    c2_id = jid(c2);
    def job2 -> None {
        theirs: any = jobj(c2_id);
        print(f"  background job sees n = {theirs.n}");
        c2 spawn SetCount(tag="c2", to=5);
    }
    as_user(me, job2);
    r2 = try_commit();
    n2 = stored_n(me, c2_id);
    print(f"case 2 (request's own copy updated during the job): request commit = {r2}, stored n = {n2} (want 5)");

    print("VERDICT user_repro:", "PASS" if r1 == "ok" and n1 == 1 and r2 == "ok" and n2 == 5 else "FAIL");
}
