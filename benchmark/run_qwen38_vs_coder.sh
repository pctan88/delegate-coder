#!/usr/bin/env bash
# Compare qwen3-coder:30b (current delegate-coder worker) vs qwen3.8:27b (new
# release) on the same bounded-implementation task, using the repo's own
# local-contract benchmark harness. Run from anywhere; cd's to repo root.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== 1/4: pulling qwen3.8:27b (~18GB — skips if already present) ==="
ollama pull qwen3.8:27b

export LABEL="plain-bounded-impl"
export TARGET_FILE="benchmark/fixtures/demo_app/todo_cli.py"
export INSTRUCTIONS='Add a function update_task(index, new_text) that updates the task at 1-based position `index` with `new_text` and calls save_tasks(). Add a --update INDEX NEW_TEXT CLI option in main() that calls update_task and prints "Updated task {index}: {new_text}" on success, or "Invalid task index." if index is out of range (do not raise an exception). Keep all existing functionality (add/list/delete) unchanged.'
export TEST_COMMAND='cd benchmark/fixtures/demo_app && python3 -c "
import sys; sys.path.insert(0, \".\")
import todo_cli
todo_cli.save_tasks([\"buy milk\", \"walk dog\"])
todo_cli.update_task(2, \"walk dog twice\")
assert todo_cli.load_tasks() == [\"buy milk\", \"walk dog twice\"], todo_cli.load_tasks()
try:
    todo_cli.update_task(99, \"nope\")
except Exception as e:
    print(\"update_task raised on bad index:\", e); raise SystemExit(1)
print(\"OK\")
"'
export REPS=5

echo "=== 2/4: baseline — qwen3-coder:30b (5x direct + 5x contract) ==="
MODEL=qwen3-coder:30b OUT_DIR=benchmark/local-results-coder30b bash benchmark/run_local_contract.sh

echo "=== 3/4: candidate — qwen3.8:27b (5x direct + 5x contract) ==="
MODEL=qwen3.8:27b OUT_DIR=benchmark/local-results-qwen38-27b bash benchmark/run_local_contract.sh

echo "=== 4/4: reports ==="
python3 benchmark/local_contract_report.py benchmark/local-results-coder30b/*.jsonl | tee benchmark/local-results-coder30b/REPORT.txt
echo
python3 benchmark/local_contract_report.py benchmark/local-results-qwen38-27b/*.jsonl | tee benchmark/local-results-qwen38-27b/REPORT.txt

echo "=== DONE ==="
