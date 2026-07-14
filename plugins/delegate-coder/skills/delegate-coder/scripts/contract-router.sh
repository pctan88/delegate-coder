#!/usr/bin/env bash
# contract-router.sh — execute a single-file Task Contract through local Ollama.
set -uo pipefail

MODEL="${DELEGATE_MODEL:-qwen3-coder:30b}"
SYSTEM_PROMPT="You are a precise coding compiler. Read the file provided, apply the requested changes, and output the ENTIRE updated file inside a single code block. Do not provide commentary, markdown explanations, or partial diffs."
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OLLAMA_HOST="${OLLAMA_HOST%/}"
NUM_CTX="${DELEGATE_NUM_CTX:-32768}"
KEEP_ALIVE="${DELEGATE_KEEP_ALIVE:-30m}"
CURL_TIMEOUT="${DELEGATE_CURL_TIMEOUT:-600}"
TEST_TIMEOUT="${DELEGATE_TEST_TIMEOUT:-300}"

for numeric_setting in "$NUM_CTX" "$CURL_TIMEOUT" "$TEST_TIMEOUT"; do
  case "$numeric_setting" in
    ''|*[!0-9]*) echo "contract-router: numeric timeout/context settings are invalid" >&2; exit 1 ;;
  esac
done

fail() {
  echo "contract-router: $*" >&2
  exit 1
}

if ! ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  ROOT_DIR="$PWD"
fi
ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-coder-contract.XXXXXX")" || fail "could not create temporary directory"
ATOMIC_FILE=""
cleanup() {
  [[ -z "$ATOMIC_FILE" ]] || rm -f "$ATOMIC_FILE"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CONTRACT_FILE="$WORK_DIR/contract"
if [[ $# -ge 1 ]]; then
  printf '%s' "$1" > "$CONTRACT_FILE"
else
  cat > "$CONTRACT_FILE" || fail "could not read contract from stdin"
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# A top-level JSON array is a sequential batch. Each child remains a normal
# single-contract run, so path checks, retries, and test gates are unchanged.
BATCH_DIR="$WORK_DIR/batch"
mkdir "$BATCH_DIR" || fail "could not create batch workspace"
if [[ "$(tr -d '[:space:]' < "$CONTRACT_FILE" | cut -c1)" == "[" ]] && ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required for contract batches"
fi
if command -v python3 >/dev/null 2>&1 && python3 - "$CONTRACT_FILE" "$BATCH_DIR" <<'PY' 2>/dev/null
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(value, list):
    raise SystemExit(1)
if not value:
    raise ValueError("contract batch must not be empty")
for index, contract in enumerate(value, 1):
    if not isinstance(contract, dict):
        raise ValueError("every batch item must be a contract object")
    pathlib.Path(sys.argv[2], f"{index}.json").write_text(json.dumps(contract))
PY
then
  BATCH_REPORT="$WORK_DIR/batch-report"
  BATCH_STATUS=0
  BATCH_RETRIES=0
  : > "$BATCH_REPORT"
  for batch_contract in "$BATCH_DIR"/*.json; do
    batch_index="$(basename "$batch_contract" .json)"
    batch_child_report="$WORK_DIR/report-$batch_index"
    printf '## Contract %s\n\n' "$batch_index" >> "$BATCH_REPORT"
    if bash "$SCRIPT_PATH" "$(cat "$batch_contract")" > "$batch_child_report"; then
      :
    else
      BATCH_STATUS=1
    fi
    batch_retries="$(sed -n 's/^- Retries: //p' "$batch_child_report" | head -n1)"
    [[ "$batch_retries" =~ ^[0-9]+$ ]] && BATCH_RETRIES=$((BATCH_RETRIES + batch_retries))
    cat "$batch_child_report" >> "$BATCH_REPORT"
    printf '\n' >> "$BATCH_REPORT"
  done
  BATCH_FINAL_REPORT="$WORK_DIR/batch-final-report"
  {
    printf '# Contract Batch Result\n\n'
    if [[ "$BATCH_STATUS" -eq 0 ]]; then
      printf -- '- Status: PASS\n\n'
    else
      printf -- '- Status: FAIL\n\n'
    fi
    printf -- '- Retries: %s\n\n' "$BATCH_RETRIES"
    cat "$BATCH_REPORT"
  } > "$BATCH_FINAL_REPORT"
  cat "$BATCH_FINAL_REPORT"
  exit "$BATCH_STATUS"
fi

PARSED_DIR="$WORK_DIR/parsed"
mkdir "$PARSED_DIR" || fail "could not create parser workspace"

parse_contract_json() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$CONTRACT_FILE" "$PARSED_DIR" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
try:
    value = json.loads(source.read_text())
    if not isinstance(value, dict):
        raise ValueError("contract must be a JSON object")
    for key in ("target_file", "instructions", "test_command"):
        field = value.get(key)
        if not isinstance(field, str):
            raise ValueError(f"{key} must be a string")
        (destination / key).write_text(field)
except Exception as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
}

parse_contract_regex() {
  # This deliberately small fallback handles JSON-shaped text from an
  # orchestrator that wrapped or otherwise damaged the JSON document.
  local key value
  for key in target_file instructions test_command; do
    value="$(sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$CONTRACT_FILE" | head -n 1)"
    [[ -n "$value" ]] || return 1
    printf '%s' "$value" > "$PARSED_DIR/$key"
  done
}

if ! parse_contract_json 2>/dev/null; then
  rm -f "$PARSED_DIR"/*
  parse_contract_regex || fail "invalid contract: expected target_file, instructions, and test_command strings"
fi

TARGET_FILE="$(cat "$PARSED_DIR/target_file")"
INSTRUCTIONS_FILE="$PARSED_DIR/instructions"
TEST_COMMAND="$(cat "$PARSED_DIR/test_command")"

[[ -n "$TARGET_FILE" ]] || fail "target_file must not be empty"
[[ -n "$TEST_COMMAND" ]] || fail "test_command must not be empty"

case "$TARGET_FILE" in
  /*|~/*|.|..|../*|*/../*|*/..)
    fail "target_file must be a relative path without traversal: $TARGET_FILE"
    ;;
esac

TARGET_DIR="$(dirname "$TARGET_FILE")"
TARGET_NAME="$(basename "$TARGET_FILE")"
TARGET_PATH="$ROOT_DIR/$TARGET_FILE"
TARGET_DIR_REAL="$(cd "$ROOT_DIR/$TARGET_DIR" 2>/dev/null && pwd -P)" || fail "target directory does not exist: $TARGET_DIR"
case "$TARGET_DIR_REAL/$TARGET_NAME" in
  "$ROOT_DIR"/*) ;;
  *) fail "target_file resolves outside the repository: $TARGET_FILE" ;;
esac
[[ -L "$TARGET_PATH" ]] && fail "target_file must not be a symlink: $TARGET_FILE"
if [[ -e "$TARGET_PATH" && ! -f "$TARGET_PATH" ]]; then
  fail "target_file must be a regular file: $TARGET_FILE"
fi

ORIGINAL_FILE="$WORK_DIR/original"
if [[ -f "$TARGET_PATH" ]]; then
  cp "$TARGET_PATH" "$ORIGINAL_FILE" || fail "could not snapshot target file"
else
  : > "$ORIGINAL_FILE"
fi

export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

if command -v ollama >/dev/null 2>&1; then
  while IFS= read -r resident_model; do
    [[ -n "$resident_model" && "$resident_model" != "$MODEL" ]] || continue
    echo "contract-router: stopping resident Ollama model $resident_model" >&2
    ollama stop "$resident_model" >/dev/null 2>&1 || \
      echo "contract-router: warning: could not stop $resident_model" >&2
  done < <(ollama ps 2>/dev/null | awk 'NR > 1 && NF { print $1 }')
fi

REQUEST_FILE="$WORK_DIR/request.json"
RESPONSE_FILE="$WORK_DIR/response.json"
GENERATED_FILE="$WORK_DIR/generated"
TEST_LOG="$WORK_DIR/test.log"
DIFF_FILE="$WORK_DIR/diff"
RETRY_COUNT=0

build_request() {
  local failure_file="${1:-}"
  local source_file="$ORIGINAL_FILE"
  [[ -z "$failure_file" ]] || source_file="$TARGET_PATH"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to build the Ollama request"
  python3 - "$REQUEST_FILE" "$TARGET_FILE" "$INSTRUCTIONS_FILE" "$source_file" "$failure_file" "$MODEL" "$SYSTEM_PROMPT" "$NUM_CTX" "$KEEP_ALIVE" <<'PY'
import json
import pathlib
import sys

request_path, target, instructions_path, source_path, failure_path, model, system_prompt, num_ctx, keep_alive = sys.argv[1:]
instructions = pathlib.Path(instructions_path).read_text()
source = pathlib.Path(source_path).read_text()
context_limit = int(num_ctx)
source_bytes = len(source.encode())
prompt_bytes = (
    len(system_prompt.encode())
    + len(target.encode())
    + len(instructions.encode())
    + source_bytes
    + 1024
)
estimated_prompt_tokens = (prompt_bytes + 2) // 3
if estimated_prompt_tokens > context_limit:
    raise SystemExit(
        "estimated prompt exceeds num_ctx: "
        f"{estimated_prompt_tokens} tokens > {context_limit}"
    )
user = (
    f"Target file: {target}\n\n"
    f"Requested change:\n{instructions}\n\n"
    f"Current full file contents:\n{source}\n"
)
if failure_path:
    failure = pathlib.Path(failure_path).read_text()
    user += f"\nThe verification command failed. Apply a correction and output the entire updated file again. Exact terminal error output:\n{failure}\n"
payload = {
    "model": model,
    "system": system_prompt,
    "prompt": user,
    "stream": False,
    "options": {"num_ctx": int(num_ctx)},
    "keep_alive": keep_alive,
}
pathlib.Path(request_path).write_text(json.dumps(payload))
PY
}

generate_file() {
  local failure_file="${1:-}"
  build_request "$failure_file" || return 1
  echo "contract-router: generating $TARGET_FILE with $MODEL" >&2
  if ! curl -fsS --max-time "$CURL_TIMEOUT" -X POST "$OLLAMA_HOST/api/generate" \
    -H 'Content-Type: application/json' \
    --data-binary "@$REQUEST_FILE" > "$RESPONSE_FILE"; then
    echo "contract-router: Ollama request failed at $OLLAMA_HOST/api/generate" >&2
    return 1
  fi

  command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse the Ollama response"
  if ! python3 - "$RESPONSE_FILE" "$GENERATED_FILE" <<'PY'
import json
import pathlib
import re
import sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text())
if response.get("done_reason") == "length":
    raise SystemExit("Ollama truncated the response at the context limit (done_reason=length)")
content = response.get("response")
if not isinstance(content, str) or not content.strip():
    raise SystemExit("Ollama response did not contain a non-empty response string")
fenced = re.search(r"```[^\r\n]*\r?\n(.*?)```", content, re.DOTALL)
if fenced:
    content = fenced.group(1)
content = content.rstrip("\r\n") + "\n"
pathlib.Path(sys.argv[2]).write_text(content)
PY
  then
    return 1
  fi

  local mode
  mode="$(stat -f '%Lp' "$TARGET_PATH" 2>/dev/null || stat -c '%a' "$TARGET_PATH" 2>/dev/null || true)"
  [[ -n "$mode" ]] || mode=644
  [[ -n "$mode" ]] && chmod "$mode" "$GENERATED_FILE" 2>/dev/null || true
  ATOMIC_FILE="$(mktemp "$TARGET_DIR_REAL/.delegate-coder.XXXXXX")" || return 1
  cp "$GENERATED_FILE" "$ATOMIC_FILE" || return 1
  mv "$ATOMIC_FILE" "$TARGET_PATH" || return 1
  ATOMIC_FILE=""
}

run_tests() {
  echo "contract-router: running verification" >&2
  if command -v timeout >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && timeout "$TEST_TIMEOUT" bash -c "$TEST_COMMAND") > "$TEST_LOG" 2>&1
  elif command -v perl >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT" bash -c "$TEST_COMMAND") > "$TEST_LOG" 2>&1
  else
    (cd "$ROOT_DIR" && bash -c "$TEST_COMMAND") > "$TEST_LOG" 2>&1
  fi
  TEST_EXIT=$?
  return "$TEST_EXIT"
}

build_diff() {
  if git ls-files --error-unmatch -- "$TARGET_FILE" >/dev/null 2>&1; then
    git diff --no-ext-diff -- "$TARGET_FILE" > "$DIFF_FILE" 2>/dev/null || true
  else
    git diff --no-index -- /dev/null "$TARGET_PATH" > "$DIFF_FILE" 2>/dev/null || [[ "$?" -eq 1 ]]
  fi
}

if ! generate_file; then
  fail "initial Ollama generation failed; target was not changed"
fi

if run_tests; then
  FINAL_STATUS="PASS"
else
  echo "contract-router: verification failed; attempting one correction" >&2
  cp "$TEST_LOG" "$WORK_DIR/failure.log"
  RETRY_COUNT=1
  if ! generate_file "$WORK_DIR/failure.log"; then
    FINAL_STATUS="FAIL"
  elif run_tests; then
    FINAL_STATUS="PASS"
  else
    FINAL_STATUS="FAIL"
  fi
fi

if [[ "$FINAL_STATUS" == "PASS" ]] && cmp -s "$ORIGINAL_FILE" "$TARGET_PATH"; then
  FINAL_STATUS="NOOP"
fi
build_diff

printf '# Contract Result\n\n'
printf -- '- Status: %s\n' "$FINAL_STATUS"
printf -- '- Retries: %s\n' "$RETRY_COUNT"
printf -- '- Target: `%s`\n\n' "$TARGET_FILE"
printf '## Git diff\n\n```diff\n'
cat "$DIFF_FILE"
printf '```\n\n## Final test log\n\n```text\n'
cat "$TEST_LOG"
printf '```\n'

[[ "$FINAL_STATUS" == "PASS" || "$FINAL_STATUS" == "NOOP" ]]
