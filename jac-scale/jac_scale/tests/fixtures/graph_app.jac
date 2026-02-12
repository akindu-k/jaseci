"""Simple graph fixture used by test_direct_db.py to test kvstore round-trips.

Graph shape built by the `build` walker:
    root --ChildEdge--> Task(id=1, title="Task A") --NextEdge--> Task(id=2, title="Task B", done=True)
    root --ChildEdge--> Task(id=3, title="Task C")
"""

node Task {
    has id: int,
        title: str,
        done: bool = False;
}

edge ChildEdge {}
edge NextEdge {}

walker build {
    """Spawn on root, create the three-node graph."""
    can run with Root entry {
        task_a = Task(id=1, title="Task A");
        task_b = Task(id=2, title="Task B", done=True);
        task_c = Task(id=3, title="Task C");

        here +>: ChildEdge() :+> task_a;
        here +>: ChildEdge() :+> task_c;
        task_a +>: NextEdge() :+> task_b;
    }
}
