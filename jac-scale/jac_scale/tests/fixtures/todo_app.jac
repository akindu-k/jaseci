node Task {
    has id: int,
        title: str,
        completed: bool = False;
}

walker:pub CreateTask {
    has id: int,
        title: str;

    can create with Root entry {
        new_task = here ++> Task(id=self.id, title=self.title);
        report new_task;
    }
}

walker:pub GetAllTasks {
    can read with Root entry {
        tasks = [-->];
        report tasks;
    }
}

walker GetTask {
    has id: int;

    can get with Root entry {
        for task in [-->] {
            if (self.id == task.id) {
                report task;
            }
        }
    }
}

walker CompleteTask {
    has id: int;

    can complete with Root entry {
        for task in [-->Task] {
            if (self.id == task.id) {
                visit task;
            }
        }
    }

    can mark_complete with Task entry {
        here.completed = True;
        report here;  # here is the visited task
    }
}

walker DeleteTask {
    has id: int;

    can visit_node with Root entry {
        for task in [-->] {
            if (self.id == task.id) {
                visit task;
            }
        }
    }

    can delete with Root entry {
        del here;
        report {"deleted": True, "id": self.id};
    }
}

walker:pub UpdateTaskTitle {
    has id: int,
        title: str;

    can update with Root entry {
        import from jaclang.jac0core.runtime { JacPersistence }
        import from jaclang.jac0core.constructs { Archetype }
        import from typing { cast }

        for task in [-->Task] {
            if (self.id == task.id) {
                JacPersistence.partial_update(
                    cast(Archetype, task), {"title": self.title}
                );
                report {"updated": True, "id": self.id, "title": self.title};
                disengage;
            }
        }
        report {"error": "Task not found"};
    }
}

walker:pub UpdateTaskCompleted {
    has id: int,
        completed: bool;

    can update with Root entry {
        import from jaclang.jac0core.runtime { JacPersistence }
        import from jaclang.jac0core.constructs { Archetype }
        import from typing { cast }

        for task in [-->Task] {
            if (self.id == task.id) {
                JacPersistence.partial_update(
                    cast(Archetype, task), {"completed": self.completed}
                );
                report {"updated": True, "id": self.id, "completed": self.completed};
                disengage;
            }
        }
        report {"error": "Task not found"};
    }
}
