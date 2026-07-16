#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/delegate-coder-local-runner-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO="$TEST_ROOT/repo"
BIN="$TEST_ROOT/bin"
OUT="$TEST_ROOT/out"
mkdir -p "$REPO" "$BIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
printf 'original\n' > "$REPO/target.txt"
git -C "$REPO" add target.txt
git -C "$REPO" commit -qm initial

cat > "$BIN/ollama" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == ps ]]; then
  printf 'NAME ID SIZE PROCESSOR UNTIL\n'
fi
SH

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
request_file=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == --data-binary ]]; then request_file="${arg#@}"; fi
  previous="$arg"
done
python3 - "$request_file" "${CURL_RECORD:?}" <<'PY'
import json
import pathlib
import sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
with pathlib.Path(sys.argv[2]).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(request, ensure_ascii=False) + "\n")
response = {
    "response": json.dumps({"updated_file": "good\n"}),
    "done_reason": "stop",
    "total_duration": 100,
    "load_duration": 10,
    "prompt_eval_count": 20,
    "prompt_eval_duration": 30,
    "eval_count": 8,
    "eval_duration": 40,
}
print(json.dumps(response))
PY
SH
chmod +x "$BIN/ollama" "$BIN/curl"

run_benchmark() {
  local out_dir="$1" test_command="$2" wrapper_command="$3"
  mkdir -p "$out_dir"
  (
    cd "$REPO"
    PATH="$BIN:$PATH" \
      CURL_RECORD="$TEST_ROOT/requests.jsonl" \
      REPO_DIR="$REPO" BASE_REF=HEAD \
      TARGET_FILE=target.txt \
      INSTRUCTIONS='replace the complete file with the requested fixture' \
      TEST_COMMAND="$test_command" \
      MODEL=test-qwen NUM_CTX=32768 KEEP_ALIVE=30m \
      CURL_TIMEOUT=10 TEST_TIMEOUT=10 REPS=5 \
      HEAVY_WRAPPER_COMMAND="$wrapper_command" \
      OUT_DIR="$out_dir" \
      bash "$ROOT/benchmark/run_local_contract.sh" >/dev/null
  )
}

INVALID_OUT="$TEST_ROOT/invalid-base"
if (
  cd "$REPO"
  PATH="$BIN:$PATH" \
    CURL_RECORD="$TEST_ROOT/invalid-requests.jsonl" \
    REPO_DIR="$REPO" BASE_REF=does-not-resolve \
    TARGET_FILE=target.txt INSTRUCTIONS=invalid TEST_COMMAND=true \
    OUT_DIR="$INVALID_OUT" REPS=5 \
    bash "$ROOT/benchmark/run_local_contract.sh" >/dev/null 2>&1
); then
  echo "invalid BASE_REF should fail before model preparation" >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/invalid-requests.jsonl" ]]

WRAPPER_COMMAND="bash \"$ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh\" contract \"\$CONTRACT_JSON\""
run_benchmark "$OUT" "grep -q '^good$' target.txt" "$WRAPPER_COMMAND"
RESULT="$(find "$OUT" -type f -name '*.jsonl' -print -quit)"
[[ -n "$RESULT" ]]

python3 - "$RESULT" "$TEST_ROOT/requests.jsonl" <<'PY'
import json
import pathlib
import sys
from collections import Counter

result_lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
records = [json.loads(line) for line in result_lines]
assert len(records) == 15, len(records)
assert Counter(record["condition"] for record in records) == Counter(direct=5, contract=5, wrapper=5), Counter(record["condition"] for record in records)
for record in records:
    assert isinstance(record["total_duration"], int), record
    assert isinstance(record["wall_seconds"], float)

requests = [json.loads(line) for line in pathlib.Path(sys.argv[2]).read_text().splitlines()]
assert len(requests) == 17, len(requests)  # two warmups plus fifteen measured requests
measured = [request for request in requests if request.get("prompt", "").startswith("Target file:")]
assert len(measured) == 15, [(r.get("model"), r.get("prompt", "")[:30]) for r in requests]
first_direct = measured[0]
first_contract = measured[5]
for idx, request in enumerate(measured):
    assert request["model"] == "test-qwen"
    assert request["system"] == first_direct["system"]
    if idx < 5:
        assert request["options"] == first_direct["options"], (request["options"], first_direct["options"])
    else:
        assert request["options"] == first_contract["options"], (request["options"], first_contract["options"])
    assert request["prompt"] == first_direct["prompt"], (request["prompt"], first_direct["prompt"])
    assert request["prompt"].startswith("Target file: target.txt\n")
    assert "/target.txt" not in request["prompt"]
PY

FAIL_OUT="$TEST_ROOT/fail-out"
run_benchmark "$FAIL_OUT" false true
FAIL_RESULT="$(find "$FAIL_OUT" -type f -name '*.jsonl' -print -quit)"
python3 - "$FAIL_RESULT" <<'PY'
import json
import pathlib
import sys
records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
wrappers = [record for record in records if record["condition"] == "wrapper"]
assert len(wrappers) == 5
assert all(record["success"] is False for record in wrappers)
PY

echo "local benchmark runner tests passed"
