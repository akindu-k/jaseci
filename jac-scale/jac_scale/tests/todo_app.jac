node Task {
    has id: int,
        title: str,
        completed: bool = False;
}

node TaskList {
    has name: str = "Test Task";
}

walker CreateTask {
    has id: int,
        title: str;

    can create with `root entry {
        new_task = here ++> Task(id=self.id, title=self.title);
        report new_task ;
    }
}

walker GetAllTasks {
    can read with `root entry {
        tasks = [-->];
        report tasks ;
    }
}

walker GetTask {
    has id: int;

    can get with `root entry {
        for task in [-->] {
            if (self.id == task.id) {
                report task ;
            }
        }
    }
}

walker CompleteTask {
    has id: int;

    can complete with `root entry {
        for task in [-->] {
            if (self.id == task.id) {
                visit task;
            }
        }
    }

    can mark_complete with Task entry {
        here.completed = True;
        report here ;  # here is the visited task
    }
}

walker DeleteTask {
    has id: int;

    can delete with `root entry {
        for task in [-->] {
            if (self.id == task.id) {
                del task ;
                report {"deleted": True, "id": self.id} ;
            }
        }
    }
}
