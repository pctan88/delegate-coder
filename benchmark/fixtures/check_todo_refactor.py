"""Verify the todo storage refactor: dict records, legacy upgrade, done flag.

Runs in a scratch cwd so todo_db.json never touches the repo.
"""
import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile


def output_of(function, *args):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        function(*args)
    return buffer.getvalue().strip()


def main():
    # Resolved before the chdir below; TEST_COMMAND runs at the sandbox root.
    demo = pathlib.Path("benchmark/fixtures/demo_app").resolve()
    sys.path.insert(0, str(demo))
    import todo_cli

    failures = []
    missing = [n for n in ("load_tasks", "save_tasks", "add_task", "list_tasks", "delete_task", "mark_done")
               if not callable(getattr(todo_cli, n, None))]
    if missing:
        print(f"FAIL (missing required function(s): {', '.join(missing)})")
        return 1

    with tempfile.TemporaryDirectory() as work:
        os.chdir(work)

        # Legacy file of plain strings must upgrade transparently.
        pathlib.Path("todo_db.json").write_text(json.dumps(["buy milk", "walk dog"]))
        tasks = todo_cli.load_tasks()
        if not (isinstance(tasks, list) and len(tasks) == 2 and all(isinstance(t, dict) for t in tasks)):
            failures.append(f"legacy upgrade: load_tasks returned {tasks!r}")
        elif [t.get("text") for t in tasks] != ["buy milk", "walk dog"]:
            failures.append(f"legacy upgrade lost text: {tasks!r}")
        elif any(t.get("done") for t in tasks):
            failures.append(f"legacy tasks must default done=False: {tasks!r}")

        # Listing shows checkbox state.
        todo_cli.save_tasks([{"text": "buy milk", "done": False}, {"text": "walk dog", "done": True}])
        listed = output_of(todo_cli.list_tasks)
        if listed != "1. [ ] buy milk\n2. [x] walk dog":
            failures.append(f"list_tasks output was {listed!r}")

        # add keeps its original message and stores a record.
        todo_cli.save_tasks([])
        added = output_of(todo_cli.add_task, "write tests")
        if added != "Added task: write tests":
            failures.append(f"add_task printed {added!r}")
        stored = todo_cli.load_tasks()
        if not (len(stored) == 1 and stored[0].get("text") == "write tests" and stored[0].get("done") is False):
            failures.append(f"add_task stored {stored!r}")

        # mark_done flips the flag and reports it.
        marked = output_of(todo_cli.mark_done, 1)
        if marked != "Marked done: write tests":
            failures.append(f"mark_done printed {marked!r}")
        if not todo_cli.load_tasks()[0].get("done"):
            failures.append("mark_done did not persist done=True")
        bad = output_of(todo_cli.mark_done, 99)
        if bad != "Invalid task index.":
            failures.append(f"mark_done out of range printed {bad!r}")

        # delete still reports the task text, not a dict repr.
        todo_cli.save_tasks([{"text": "buy milk", "done": False}])
        deleted = output_of(todo_cli.delete_task, 1)
        if deleted != "Deleted task: buy milk":
            failures.append(f"delete_task printed {deleted!r}")
        empty = output_of(todo_cli.list_tasks)
        if empty != "No tasks found.":
            failures.append(f"empty list printed {empty!r}")

    if failures:
        print(f"FAIL ({len(failures)} problem(s))")
        for line in failures:
            print("  " + line)
        return 1
    print("OK (legacy upgrade, checkbox listing, mark_done, messages preserved)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
