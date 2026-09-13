#!/usr/bin/env bash
# Shared task definitions for the model matrix. Sourced, not executed.
# Each task sets LABEL, TARGET_FILE, INSTRUCTIONS, TEST_COMMAND.

task_T1_simple() {
  LABEL="T1-simple-edit"
  TARGET_FILE="benchmark/fixtures/demo_app/todo_cli.py"
  INSTRUCTIONS='Add a function update_task(index, new_text) that updates the task at 1-based position `index` with `new_text` and calls save_tasks(). Add a --update INDEX NEW_TEXT CLI option in main() that calls update_task and prints "Updated task {index}: {new_text}" on success, or "Invalid task index." if index is out of range (do not raise an exception). Keep all existing functionality (add/list/delete) unchanged.'
  TEST_COMMAND='cd benchmark/fixtures/demo_app && python3 -c "
import sys; sys.path.insert(0, \".\")
import todo_cli
todo_cli.save_tasks([\"buy milk\", \"walk dog\"])
todo_cli.update_task(2, \"walk dog twice\")
assert todo_cli.load_tasks() == [\"buy milk\", \"walk dog twice\"], todo_cli.load_tasks()
todo_cli.update_task(99, \"nope\")
print(\"OK\")
"'
}

task_T2_algorithmic() {
  LABEL="T2-algorithmic"
  TARGET_FILE="benchmark/fixtures/schedule.py"
  INSTRUCTIONS='Add a function add_months(value, months) that returns the datetime.date falling exactly `months` calendar months after `value`. When the target month has fewer days than value.day, clamp to the last valid day of the target month (2026-01-31 plus 1 month is 2026-02-28; in a leap year 2024-01-31 plus 1 month is 2024-02-29). Support negative `months` and year rollover in both directions. Use only the standard library (no dateutil). Keep every existing function in the file exactly as it is.'
  TEST_COMMAND='python3 benchmark/fixtures/check_schedule.py'
}

task_T3_refactor() {
  LABEL="T3-refactor"
  TARGET_FILE="benchmark/fixtures/demo_app/todo_cli.py"
  INSTRUCTIONS='Refactor task storage from a list of plain strings to a list of objects shaped {"text": <str>, "done": <bool>}. Requirements: (1) load_tasks() must transparently upgrade a legacy todo_db.json that still holds a list of plain strings, treating each as done=False; (2) list_tasks() must print "{i}. [x] {text}" for done tasks and "{i}. [ ] {text}" for pending ones, and still print "No tasks found." when empty; (3) add a function mark_done(index) that marks the 1-based task done, saves, and prints "Marked done: {text}", or prints "Invalid task index." when out of range without raising; (4) add a --done INDEX CLI option wired to mark_done; (5) add_task must still print exactly "Added task: {task}" and delete_task must still print exactly "Deleted task: {text}" using the task text, never a dict repr, and still print "Invalid task index." when out of range.'
  TEST_COMMAND='python3 benchmark/fixtures/check_todo_refactor.py'
}
