#!/usr/bin/env bash
# Non-destructive five-repetition local-Qwen benchmark. Writes only OUT_DIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BASE_REF="${BASE_REF:-HEAD}"
TARGET_FILE="${TARGET_FILE:-}"; INSTRUCTIONS="${INSTRUCTIONS:-}"; TEST_COMMAND="${TEST_COMMAND:-}"
MODEL="${MODEL:-qwen3-coder:30b}"; NUM_CTX="${NUM_CTX:-32768}"; KEEP_ALIVE="${KEEP_ALIVE:-30m}"
CURL_TIMEOUT="${CURL_TIMEOUT:-600}"; TEST_TIMEOUT="${TEST_TIMEOUT:-300}"; REPS="${REPS:-5}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OUT_DIR="${OUT_DIR:-$HERE/local-results-$(date +%Y%m%d-%H%M%S)}"
[[ -n "$TARGET_FILE" && -n "$INSTRUCTIONS" && -n "$TEST_COMMAND" ]] || { echo "Set TARGET_FILE, INSTRUCTIONS, TEST_COMMAND" >&2; exit 2; }
for name in NUM_CTX CURL_TIMEOUT TEST_TIMEOUT REPS; do
  value="${!name}"; [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "$name must be positive" >&2; exit 2; }
done
[[ "$REPS" -ge 5 ]] || { echo "REPS must be at least 5" >&2; exit 2; }
BASE_COMMIT="$(git -C "$REPO_DIR" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null)" || { echo "BASE_REF does not resolve to a commit: $BASE_REF" >&2; exit 2; }
command -v curl >/dev/null && command -v python3 >/dev/null && command -v ollama >/dev/null || { echo "curl, python3, and ollama are required" >&2; exit 2; }
if command -v timeout >/dev/null; then RUNNER=(timeout "$TEST_TIMEOUT"); elif command -v gtimeout >/dev/null; then RUNNER=(gtimeout "$TEST_TIMEOUT"); elif command -v perl >/dev/null; then RUNNER=(perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT"); else echo "bounded timeout command is required" >&2; exit 2; fi
SYSTEM_PROMPT="You are a precise coding compiler. Read the file provided, apply the requested changes, and return only a valid JSON object with one string field named updated_file containing the ENTIRE updated file. Do not return markdown, code fences, commentary, diffs, or additional fields. Preserve all existing content not required to change."
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$OUT_DIR"; OUT_FILE="$OUT_DIR/$RUN_ID.jsonl"; [[ ! -e "$OUT_FILE" ]] || exit 2
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-coder-local-benchmark.XXXXXX")"; trap 'rm -rf "$WORK_DIR"' EXIT
now_ns() { python3 -c 'import time; print(time.time_ns())'; }
is_loopback() { python3 - "$OLLAMA_HOST" <<'PY'
from urllib.parse import urlparse
import sys
raise SystemExit(0 if urlparse(sys.argv[1]).hostname in {"127.0.0.1","localhost","::1"} else 1)
PY
}
request() { local input="$1" output="$2"; local args=(-fsS --max-time "$CURL_TIMEOUT" -X POST "$OLLAMA_HOST/api/generate" -H 'Content-Type: application/json' --data-binary "@$input"); is_loopback && args+=(--noproxy '*'); curl "${args[@]}" > "$output"; }
prepare_gpu() { local lines model; lines="$(ollama ps 2>/dev/null)" || return 1; while IFS= read -r model; do [[ -n "$model" && "$model" != MODEL && "$model" != "$MODEL" ]] || continue; ollama stop "$model" >/dev/null 2>&1 || return 1; done < <(printf '%s\n' "$lines" | awk 'NR > 1 {print $1}'); }
sandbox() { local dir="$1"; mkdir -p "$dir"; git -C "$REPO_DIR" archive "$BASE_COMMIT" | tar -x -C "$dir"; git -C "$dir" init -q; git -C "$dir" config user.email benchmark@example.invalid; git -C "$dir" config user.name benchmark; git -C "$dir" add .; git -C "$dir" commit -qm base; }
build_request() {
  local dir="$1" out="$2"; INSTRUCTIONS="$INSTRUCTIONS" SYSTEM_PROMPT="$SYSTEM_PROMPT" python3 - "$out" "$dir/$TARGET_FILE" "$TARGET_FILE" "$MODEL" "$NUM_CTX" "$KEEP_ALIVE" <<'PY'
import json, os, pathlib, sys
out, target, target_label, model, limit, keep_alive = sys.argv[1:]
source = pathlib.Path(target).read_bytes()
user = f"Target file: {target_label}\n\nRequested change:\n{os.environ['INSTRUCTIONS']}\n\nCurrent full file contents:\n{source.decode('utf-8')}\n"
expected = max(256, (len(source)+2)//3)
if (len((os.environ['SYSTEM_PROMPT']+user).encode())+2)//3 + expected + 256 > int(limit): raise SystemExit("prompt plus expected output exceeds context")
payload = {"model":model,"system":os.environ["SYSTEM_PROMPT"],"prompt":user,"stream":False,"format":{"type":"object","properties":{"updated_file":{"type":"string"}},"required":["updated_file"],"additionalProperties":False},"options":{"num_ctx":int(limit),"temperature":0,"num_predict":expected+256},"keep_alive":keep_alive}
pathlib.Path(out).write_text(json.dumps(payload, ensure_ascii=False))
PY
}
emit() { python3 - "$OUT_FILE" "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, pathlib, sys
out, condition, rep, success, retries, wall, metrics = sys.argv[1:]
value = {key: None for key in ("total_duration", "load_duration", "prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration")}
if pathlib.Path(metrics).exists():
    value.update(json.loads(pathlib.Path(metrics).read_text()))
value.update(condition=condition, rep=int(rep), success=success=="1", retries=int(retries), wall_seconds=float(wall))
with pathlib.Path(out).open("a") as stream: stream.write(json.dumps(value)+"\n")
PY
}
warmup() { local input="$WORK_DIR/warmup-in" output="$WORK_DIR/warmup-out"; MODEL="$MODEL" SYSTEM_PROMPT="$SYSTEM_PROMPT" NUM_CTX="$NUM_CTX" KEEP_ALIVE="$KEEP_ALIVE" python3 - "$input" <<'PY'
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"model":os.environ["MODEL"],"system":os.environ["SYSTEM_PROMPT"],"prompt":"warm","stream":False,"format":{"type":"object","properties":{"updated_file":{"type":"string"}},"required":["updated_file"],"additionalProperties":False},"options":{"num_ctx":int(os.environ["NUM_CTX"]),"temperature":0,"num_predict":256},"keep_alive":os.environ["KEEP_ALIVE"]}))
PY
request "$input" "$output" >/dev/null; }
direct() {
  local rep="$1" dir="$WORK_DIR/direct-$rep" input="$WORK_DIR/direct-$rep-in" output="$WORK_DIR/direct-$rep-out" metrics="$WORK_DIR/direct-$rep-metrics" start end success=0
  sandbox "$dir"; build_request "$dir" "$input"; start="$(now_ns)"
  if request "$input" "$output"; then
    python3 - "$output" "$dir/$TARGET_FILE" "$metrics" <<'PY'
import json, pathlib, sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
if r.get("done_reason")=="length": raise SystemExit("truncated")
v=json.loads(r.get("response",""))
if set(v)!={"updated_file"} or not isinstance(v["updated_file"],str) or not v["updated_file"]: raise SystemExit("invalid structured output")
pathlib.Path(sys.argv[2]).write_bytes((v["updated_file"].rstrip("\r\n")+"\n").encode())
pathlib.Path(sys.argv[3]).write_text(json.dumps({k:r.get(k) for k in ("total_duration","load_duration","prompt_eval_count","prompt_eval_duration","eval_count","eval_duration")}))
PY
    (cd "$dir" && "${RUNNER[@]}" bash -c "$TEST_COMMAND") >/dev/null 2>&1 && success=1
  fi
  end="$(now_ns)"; emit direct "$rep" "$success" 0 "$(python3 -c "print(($end-$start)/1e9)")" "$metrics"
}
contract() {
  local rep="$1" dir="$WORK_DIR/contract-$rep" report="$WORK_DIR/contract-$rep-report" metrics="$WORK_DIR/contract-$rep-metrics" start end success=0 retries=0
  sandbox "$dir"; local json_contract="$(target_file="$TARGET_FILE" instructions="$INSTRUCTIONS" test_command="$TEST_COMMAND" python3 -c 'import json,os; print(json.dumps({k:os.environ[k] for k in ("target_file","instructions","test_command")}))')"; start="$(now_ns)"
  (cd "$dir" && DELEGATE_MODEL="$MODEL" DELEGATE_NUM_CTX="$NUM_CTX" DELEGATE_KEEP_ALIVE="$KEEP_ALIVE" DELEGATE_CURL_TIMEOUT="$CURL_TIMEOUT" DELEGATE_TEST_TIMEOUT="$TEST_TIMEOUT" bash "$HERE/../plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh" contract "$json_contract") > "$report" 2>&1
  [[ "$(sed -n 's/^- Status: //p' "$report" | head -n1)" =~ ^(PASS|NOOP)$ ]] && success=1; retries="$(sed -n 's/^- Retries: //p' "$report" | head -n1)"; [[ "$retries" =~ ^[0-9]+$ ]] || retries=0
  python3 - "$report" "$metrics" <<'PY'
import json, pathlib, re, sys
text=pathlib.Path(sys.argv[1]).read_text(); value={}
for key in ("total_duration","load_duration","prompt_eval_count","prompt_eval_duration","eval_count","eval_duration"):
 m=re.search(rf"^- Ollama {key}: (.+)$",text,re.M); value[key]=int(m.group(1)) if m and m.group(1).isdigit() else None
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
  end="$(now_ns)"; emit contract "$rep" "$success" "$retries" "$(python3 -c "print(($end-$start)/1e9)")" "$metrics"
}
wrapper() {
  local rep="$1" dir="$WORK_DIR/wrapper-$rep" report="$WORK_DIR/wrapper-$rep-report" metrics="$WORK_DIR/wrapper-$rep-metrics" start end success=0 wrapper_exit=1 test_success=1
  sandbox "$dir"
  local json_contract="$(target_file="$TARGET_FILE" instructions="$INSTRUCTIONS" test_command="$TEST_COMMAND" python3 -c 'import json,os; print(json.dumps({k:os.environ[k] for k in ("target_file","instructions","test_command")}))')"
  start="$(now_ns)"
  (cd "$dir" && MODEL="$MODEL" DELEGATE_MODEL="$MODEL" NUM_CTX="$NUM_CTX" DELEGATE_NUM_CTX="$NUM_CTX" KEEP_ALIVE="$KEEP_ALIVE" DELEGATE_KEEP_ALIVE="$KEEP_ALIVE" CURL_TIMEOUT="$CURL_TIMEOUT" DELEGATE_CURL_TIMEOUT="$CURL_TIMEOUT" TEST_TIMEOUT="$TEST_TIMEOUT" DELEGATE_TEST_TIMEOUT="$TEST_TIMEOUT" CONTRACT_JSON="$json_contract" bash -c "$HEAVY_WRAPPER_COMMAND") > "$report" 2>&1 && wrapper_exit=0
  (cd "$dir" && "${RUNNER[@]}" bash -c "$TEST_COMMAND") >/dev/null 2>&1 || test_success=0
  [[ "$wrapper_exit" -eq 0 && "$test_success" -eq 1 ]] && success=1
  python3 - "$report" "$metrics" <<'PY'
import json, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text() if pathlib.Path(sys.argv[1]).exists() else ""
value = {}
for key in ("total_duration", "load_duration", "prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration"):
    match = re.search(rf"^- Ollama {key}: (.+)$", text, re.MULTILINE)
    value[key] = int(match.group(1)) if match and match.group(1).isdigit() else None
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
  end="$(now_ns)"; emit wrapper "$rep" "$success" 0 "$(python3 -c "print(($end-$start)/1e9)")" "$metrics"
}
prepare_gpu || { echo "could not prepare Ollama GPU" >&2; exit 1; }
for condition in direct contract; do
  MODEL="$MODEL" SYSTEM_PROMPT="$SYSTEM_PROMPT" NUM_CTX="$NUM_CTX" KEEP_ALIVE="$KEEP_ALIVE" warmup || exit 1
  for rep in $(seq 1 "$REPS"); do [[ "$condition" == direct ]] && direct "$rep" || contract "$rep"; done
done
if [[ -n "${HEAVY_WRAPPER_COMMAND:-}" ]]; then
  for rep in $(seq 1 "$REPS"); do wrapper "$rep"; done
fi
echo "Wrote additive local benchmark: $OUT_FILE"
echo "Report: python3 $HERE/local_contract_report.py $OUT_FILE"
