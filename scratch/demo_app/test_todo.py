import subprocess
import os
import sys

# Clean legacy state
if os.path.exists("todo_db.json"):
    os.remove("todo_db.json")

# 1. Check help / usage
res = subprocess.run(["python3", "scratch/demo_app/todo_cli.py", "--help"], capture_output=True, text=True)
if "todo" not in res.stdout.lower() and "usage" not in res.stdout.lower():
    print(f"Failed: --help output got: {res.stdout}")
    sys.exit(1)

# 2. Add task
res = subprocess.run(["python3", "scratch/demo_app/todo_cli.py", "--add", "Buy milk"], capture_output=True, text=True)
if "added" not in res.stdout.lower() and "buy milk" not in res.stdout.lower():
    print(f"Failed: --add output got: {res.stdout}")
    sys.exit(1)

# 3. List tasks
res = subprocess.run(["python3", "scratch/demo_app/todo_cli.py", "--list"], capture_output=True, text=True)
if "buy milk" not in res.stdout.lower():
    print(f"Failed: --list output got: {res.stdout}")
    sys.exit(1)

print("All tests passed!")
sys.exit(0)
