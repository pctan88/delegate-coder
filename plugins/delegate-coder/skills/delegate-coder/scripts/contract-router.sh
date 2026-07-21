#!/usr/bin/env bash
# contract-router.sh — transactional single-file Task Contract execution through Ollama.
set -uo pipefail
ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL="${DELEGATE_MODEL:-qwen3-coder:30b}"
SYSTEM_PROMPT="You are a precise coding compiler. Read the file provided, apply the requested changes, and return only a valid JSON object with one string field named updated_file containing the ENTIRE updated file. Do not return markdown, code fences, commentary, diffs, or additional fields. Preserve all existing content not required to change."
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OLLAMA_HOST="${OLLAMA_HOST%/}"
NUM_CTX="${DELEGATE_NUM_CTX:-32768}"
KEEP_ALIVE="${DELEGATE_KEEP_ALIVE:-30m}"
CURL_TIMEOUT="${DELEGATE_CURL_TIMEOUT:-600}"
TEST_TIMEOUT="${DELEGATE_TEST_TIMEOUT:-300}"
MIN_OUTPUT_BUDGET="${DELEGATE_MIN_OUTPUT_BUDGET:-4096}"

for setting_name in NUM_CTX CURL_TIMEOUT TEST_TIMEOUT MIN_OUTPUT_BUDGET; do
  setting_value="${!setting_name}"
  case "$setting_value" in
    ''|*[!0-9]*|0) echo "contract-router: $setting_name must be a strictly positive integer" >&2; exit 1 ;;
  esac
done
[[ "$MIN_OUTPUT_BUDGET" -ge 4096 ]] || { echo "contract-router: MIN_OUTPUT_BUDGET must be >= 4096" >&2; exit 1; }

fail() {
  ERROR_MESSAGE="$*"
  FINAL_STATUS="FAIL"
  exit 1
}

ROOT_DIR=""
if ! ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]]; then
  echo "contract-router: execution requires a Git worktree" >&2
  exit 1
fi
ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delegate-coder-contract.XXXXXX")" || exit 1
STAGED=0
ACCEPTED=0
RESTORED=0
REPORT_EMITTED=0
FINAL_STATUS="FAIL"
RETRY_COUNT=0
NOOP_CANDIDATE_PATH=""
PREFLIGHT_FAIL_COUNT=0
LAST_FAILURE_TYPE=""
HINT_MESSAGE=""
ERROR_MESSAGE=""
OUTSIDE_CHANGES=""
BASE_WORKTREE_STATUS=""
BRANCH_NAME="${DELEGATE_CONTRACT_BRANCH:-}"
TARGET_FILE=""
TARGET_PATH=""
ORIGINAL_EXISTS=0
ORIGINAL_MODE="644"
ORIGINAL_FILE="$WORK_DIR/original"
CANDIDATE_FILE="$WORK_DIR/candidate"
TEST_LOG="$WORK_DIR/test.log"
DIFF_FILE="$WORK_DIR/diff"
METRICS_FILE="$WORK_DIR/metrics.json"
SNAPSHOT_ROOT="$WORK_DIR/worktree-snapshot"
SNAPSHOT_READY=0
INDEX_PATH=""
INDEX_SNAPSHOT="$WORK_DIR/index.snapshot"
INDEX_EXISTS=0
INDEX_READY=0

cleanup() {
  local rc=$?
  if [[ "$SNAPSHOT_READY" -eq 1 && "$ACCEPTED" -eq 0 && "$RESTORED" -eq 0 ]] && worktree_needs_restore; then
    restore_worktree || true
  fi
  if [[ "$REPORT_EMITTED" -eq 0 ]]; then
    emit_report || true
  fi
  rm -rf "$WORK_DIR"
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

on_signal() {
  local signal="$1"
  ERROR_MESSAGE="contract router interrupted by SIG$signal"
  FINAL_STATUS="FAIL"
  exit $((128 + signal))
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT
trap 'on_signal 1' HUP

status_without_target() {
  local target="$1"
  local status_file="$WORK_DIR/status"
  git -C "$ROOT_DIR" status --porcelain --untracked-files=all > "$status_file"
  python3 - "$target" "$status_file" <<'PY'
import codecs
import pathlib
import sys

target = pathlib.PurePosixPath(sys.argv[1])
for raw in pathlib.Path(sys.argv[2]).read_text().splitlines():
    line = raw
    path = line[3:] if len(line) >= 3 else ""
    if " -> " in path:
        path = path.split(" -> ", 1)[1]
    if path.startswith('"') and path.endswith('"'):
        try:
            path = codecs.escape_decode(path[1:-1].encode("utf-8"))[0].decode("utf-8")
        except Exception:
            pass
    if pathlib.PurePosixPath(path) != target:
        print(line)
PY
}

prepare_worktree() {
  if [[ "${DELEGATE_CONTRACT_PREPARED:-0}" != 1 ]]; then
    local current_branch dirty
    current_branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null)"
    [[ -n "$current_branch" ]] || fail "contract mode requires a named feature/delegate branch; detached HEAD is not allowed"
    dirty="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
    [[ -z "$dirty" ]] || fail "contract mode requires a clean worktree before the first write"
    if [[ "$current_branch" == main || "$current_branch" == master || "$current_branch" == develop || "$current_branch" == trunk ]]; then
      BRANCH_NAME="${DELEGATE_CONTRACT_BRANCH:-delegate/contract-$(date +%Y%m%d-%H%M%S)-$$}"
      git -C "$ROOT_DIR" switch -c "$BRANCH_NAME" >/dev/null 2>&1 || fail "could not create isolated contract branch: $BRANCH_NAME"
    else
      BRANCH_NAME="$current_branch"
    fi
  else
    BRANCH_NAME="${BRANCH_NAME:-$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null)}"
  fi
  [[ -n "$BRANCH_NAME" ]] || fail "contract mode requires a named feature/delegate branch"
}

prepare_gpu() {
  [[ "${DELEGATE_BATCH_ACTIVE:-0}" == 1 ]] && return 0
  command -v ollama >/dev/null 2>&1 || fail "ollama is required for contract mode"
  local resident model
  resident="$(ollama ps 2>/dev/null)" || fail "could not inspect resident Ollama models"
  while IFS= read -r model; do
    [[ -n "$model" && "$model" != MODEL && "$model" != "$MODEL" ]] || continue
    ollama stop "$model" >/dev/null 2>&1 || fail "could not stop resident Ollama model: $model"
  done < <(printf '%s\n' "$resident" | awk 'NR > 1 {print $1}')
}

require_bounded_runner() {
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1; then
    return 0
  fi
  fail "no bounded verification mechanism available; install timeout, gtimeout, or perl"
}

is_loopback_host() {
  python3 - "$OLLAMA_HOST" <<'PY'
from urllib.parse import urlparse
import sys
host = urlparse(sys.argv[1]).hostname
raise SystemExit(0 if host and host.lower() in {"127.0.0.1", "localhost", "::1"} else 1)
PY
}

read_contract() {
  CONTRACT_FILE="$WORK_DIR/contract"
  if [[ $# -ge 1 ]]; then
    printf '%s' "$1" > "$CONTRACT_FILE"
  else
    cat > "$CONTRACT_FILE" || fail "could not read contract from stdin"
  fi
}

validate_contract_input() {
  local first_nonspace
  first_nonspace="$(sed -n '/[^[:space:]]/s/^[[:space:]]*\(.\).*/\1/p' "$CONTRACT_FILE" | head -n1)"
  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$CONTRACT_FILE" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
items = value if isinstance(value, list) else [value]
if not items:
    raise ValueError("contract batch must be a non-empty JSON array")
for index, item in enumerate(items, 1):
    if not isinstance(item, dict):
        raise ValueError(f"contract {index} must be an object")
    for key in ("target_file", "instructions", "test_command"):
        if not isinstance(item.get(key), str):
            raise ValueError(f"contract {index}: {key} must be a string")
    # Phase 2: validate optional context_files
    if "context_files" in item and item["context_files"] is not None:
        if not isinstance(item["context_files"], list) or not all(isinstance(f, str) for f in item["context_files"]):
            raise ValueError(f"contract {index}: context_files must be a JSON array of strings")
PY
    then
      return 0
    fi
  elif [[ "$first_nonspace" == "[" ]]; then
    fail "python3 is required for contract batches"
  fi

  [[ "$first_nonspace" != "[" ]] || fail "invalid contract batch"
  local key value
  for key in target_file instructions test_command; do
    value="$(sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$CONTRACT_FILE" | head -n1)"
    [[ -n "$value" ]] || fail "invalid contract: expected target_file, instructions, and test_command strings"
  done
}

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

run_batch_if_present() {
  local first_nonspace
  first_nonspace="$(tr -d '[:space:]' < "$CONTRACT_FILE" | cut -c1)"
  [[ "$first_nonspace" == "[" ]] || return 1
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for contract batches"
  BATCH_DIR="$WORK_DIR/batch"
  BATCH_MANIFEST="$WORK_DIR/batch-manifest"
  mkdir "$BATCH_DIR" || fail "could not create batch workspace"
  python3 - "$CONTRACT_FILE" "$BATCH_DIR" "$BATCH_MANIFEST" <<'PY' || fail "invalid contract batch"
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(value, list) or not value:
    raise ValueError("contract batch must be a non-empty JSON array")
manifest = pathlib.Path(sys.argv[3])
paths = []
for index, contract in enumerate(value, 1):
    if not isinstance(contract, dict):
        raise ValueError(f"batch item {index} must be an object")
    destination = pathlib.Path(sys.argv[2], f"{index:06d}.json")
    destination.write_text(json.dumps(contract, ensure_ascii=False))
    paths.append(str(destination))
manifest.write_text("".join(path + "\n" for path in paths))
PY

  # Validate every child target while the worktree is still on its original
  # branch. Child execution repeats this check against its own baseline.
  local saved_contract_file="$CONTRACT_FILE"
  REQUEST_FILE="$WORK_DIR/batch-preflight-request.json"
  RESPONSE_FILE="$WORK_DIR/batch-preflight-response.json"
  while IFS= read -r batch_contract; do
    CONTRACT_FILE="$batch_contract"
    rm -rf "$WORK_DIR/parsed"
    mkdir -p "$WORK_DIR/parsed"
    parse_contract_json || fail "invalid contract batch item"
    snapshot_target
    build_request || fail "batch contract prompt exceeds the configured context budget"
  done < "$BATCH_MANIFEST"
  CONTRACT_FILE="$saved_contract_file"

  prepare_worktree
  prepare_gpu
  BATCH_TOTAL="$(wc -l < "$BATCH_MANIFEST" | tr -d ' ')"
  BATCH_COMPLETED=0
  BATCH_FAILED=0
  BATCH_SKIPPED=0
  BATCH_RETRIES=0
  BATCH_RESTORED=false
  BATCH_REPORT="$WORK_DIR/batch-report"
  : > "$BATCH_REPORT"

  while IFS= read -r batch_contract; do
    batch_index="$(basename "$batch_contract" .json | sed 's/^0*//')"
    [[ -n "$batch_index" ]] || batch_index=0
    child_report="$WORK_DIR/report-$batch_index"
    printf '## Contract %s\n\n' "$batch_index" >> "$BATCH_REPORT"
    if DELEGATE_BATCH_ACTIVE=1 DELEGATE_CONTRACT_PREPARED=1 DELEGATE_CONTRACT_BRANCH="$BRANCH_NAME" bash "$SCRIPT_PATH" "$(cat "$batch_contract")" > "$child_report"; then
      BATCH_COMPLETED=$((BATCH_COMPLETED + 1))
    else
      BATCH_FAILED=$((BATCH_FAILED + 1))
      BATCH_SKIPPED=$((BATCH_TOTAL - BATCH_COMPLETED - BATCH_FAILED))
      batch_restored="$(sed -n 's/^- Restored: //p' "$child_report" | head -n1)"
      [[ "$batch_restored" == true ]] && BATCH_RESTORED=true
      batch_retries="$(sed -n 's/^- Retries: //p' "$child_report" | head -n1)"
      [[ "$batch_retries" =~ ^[0-9]+$ ]] && BATCH_RETRIES=$((BATCH_RETRIES + batch_retries))
      cat "$child_report" >> "$BATCH_REPORT"
      break
    fi
    batch_retries="$(sed -n 's/^- Retries: //p' "$child_report" | head -n1)"
    [[ "$batch_retries" =~ ^[0-9]+$ ]] && BATCH_RETRIES=$((BATCH_RETRIES + batch_retries))
    cat "$child_report" >> "$BATCH_REPORT"
    printf '\n' >> "$BATCH_REPORT"
  done < "$BATCH_MANIFEST"

  [[ "$BATCH_FAILED" -eq 0 ]] && BATCH_SKIPPED=0
  {
    printf '# Contract Batch Result\n\n'
    [[ "$BATCH_FAILED" -eq 0 ]] && printf -- '- Status: PASS\n' || printf -- '- Status: FAIL\n'
    printf -- '- Branch: %s\n' "$BRANCH_NAME"
    printf -- '- Completed: %s\n' "$BATCH_COMPLETED"
    printf -- '- Failed: %s\n' "$BATCH_FAILED"
    printf -- '- Skipped: %s\n' "$BATCH_SKIPPED"
    printf -- '- Retries: %s\n' "$BATCH_RETRIES"
    printf -- '- Restored: %s\n\n' "$BATCH_RESTORED"
    cat "$BATCH_REPORT"
  } > "$WORK_DIR/batch-final-report"
  cat "$WORK_DIR/batch-final-report"
  REPORT_EMITTED=1
  if [[ "$BATCH_FAILED" -eq 0 ]]; then
    return 0
  fi
  return 2
}

parse_contract_json() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$CONTRACT_FILE" "$WORK_DIR/parsed" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
destination.mkdir(exist_ok=True)
value = json.loads(source.read_text())
if not isinstance(value, dict):
    raise ValueError("contract must be a JSON object")
for key in ("target_file", "instructions", "test_command"):
    field = value.get(key)
    if not isinstance(field, str):
        raise ValueError(f"{key} must be a string")
    (destination / key).write_text(field)

# Phase 2: parse context_files using python/jq robust methods
context_files = value.get("context_files")
if context_files is None:
    context_files = []
elif not isinstance(context_files, list):
    raise ValueError("context_files must be a JSON array")
for f in context_files:
    if not isinstance(f, str):
        raise ValueError("context_files items must be strings")
(destination / "context_files.json").write_text(json.dumps(context_files, ensure_ascii=False))
PY
}

parse_contract_regex() {
  local key value
  for key in target_file instructions test_command; do
    value="$(sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$CONTRACT_FILE" | head -n 1)"
    [[ -n "$value" ]] || return 1
    printf '%s' "$value" > "$WORK_DIR/parsed/$key"
  done
  # Phase 2: ensure context_files.json has an empty array fallback
  echo "[]" > "$WORK_DIR/parsed/context_files.json"
}

snapshot_target() {
  TARGET_FILE="$(cat "$WORK_DIR/parsed/target_file")"
  INSTRUCTIONS_FILE="$WORK_DIR/parsed/instructions"
  TEST_COMMAND="$(cat "$WORK_DIR/parsed/test_command")"
  [[ -n "$TARGET_FILE" ]] || fail "target_file must not be empty"
  [[ -n "$TEST_COMMAND" ]] || fail "test_command must not be empty"
  case "$TARGET_FILE" in
    /*|~/*|.|..|../*|*/../*) fail "target_file must be a relative path without traversal: $TARGET_FILE" ;;
  esac
  TARGET_DIR="$(dirname "$TARGET_FILE")"
  TARGET_NAME="$(basename "$TARGET_FILE")"
  TARGET_PATH="$ROOT_DIR/$TARGET_FILE"
  if [[ ! -d "$ROOT_DIR/$TARGET_DIR" ]]; then
    python3 - "$ROOT_DIR" "$TARGET_DIR" <<'PY' || fail "target_file resolves outside the repository: $TARGET_FILE"
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
try:
    target_dir = (root / sys.argv[2]).resolve(strict=False)
except Exception:
    sys.exit(1)
if target_dir != root and root not in target_dir.parents:
    sys.exit(1)
PY
    mkdir -p "$ROOT_DIR/$TARGET_DIR" 2>/dev/null || fail "could not create target directory: $TARGET_DIR"
  fi
  TARGET_DIR_REAL="$(cd "$ROOT_DIR/$TARGET_DIR" 2>/dev/null && pwd -P)" || fail "target directory does not exist: $TARGET_DIR"
  case "$TARGET_DIR_REAL/$TARGET_NAME" in
    "$ROOT_DIR"/*) ;;
    *) fail "target_file resolves outside the repository: $TARGET_FILE" ;;
  esac
  [[ -L "$TARGET_PATH" ]] && fail "target_file must not be a symlink: $TARGET_FILE"
  if [[ -e "$TARGET_PATH" && ! -f "$TARGET_PATH" ]]; then
    fail "target_file must be a regular file: $TARGET_FILE"
  fi
  target_status="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all -- "$TARGET_FILE")"
  if [[ -n "$target_status" ]]; then
    fail "target_file is dirty; commit or stash it before contract execution: $TARGET_FILE
Why: A previous contract branch (e.g. delegate/contract-*) may be checked out with uncommitted changes.
What to do: Checkout your base branch (e.g. main/master) or merge/stash/commit the delegate branch changes first.
Offending git status:
$target_status"
  fi
  if [[ -f "$TARGET_PATH" ]]; then
    ORIGINAL_EXISTS=1
    cp "$TARGET_PATH" "$ORIGINAL_FILE" || fail "could not snapshot target file"
    ORIGINAL_MODE="$(stat -f '%Lp' "$TARGET_PATH" 2>/dev/null || stat -c '%a' "$TARGET_PATH" 2>/dev/null || echo 644)"
  else
    ORIGINAL_EXISTS=0
    : > "$ORIGINAL_FILE"
  fi
}

snapshot_worktree() {
  mkdir -p "$SNAPSHOT_ROOT/payload" || fail "could not create worktree snapshot"
  python3 - "$ROOT_DIR" "$SNAPSHOT_ROOT" <<'PY' || fail "could not snapshot the worktree"
import json
import os
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
snapshot = pathlib.Path(sys.argv[2])
payload = snapshot / "payload"
raw = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"]
)
manifest = []
for index, encoded in enumerate(raw.split(b"\0")):
    if not encoded:
        continue
    relative = os.fsdecode(encoded)
    source = root / relative
    if source.is_symlink():
        manifest.append({"path": relative, "kind": "symlink", "mode": source.lstat().st_mode & 0o7777, "target": os.readlink(source)})
    elif source.is_file():
        stored = payload / str(index)
        shutil.copyfile(source, stored)
        manifest.append({"path": relative, "kind": "file", "mode": source.stat().st_mode & 0o7777, "stored": stored.name})
(snapshot / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
trace = os.environ.get("DELEGATE_SNAPSHOT_TRACE")
if trace:
    with pathlib.Path(trace).open("a", encoding="utf-8") as stream:
        for item in manifest:
            stream.write(item["path"] + "\n")
PY
  INDEX_PATH="$(git -C "$ROOT_DIR" rev-parse --git-path index)"
  [[ "$INDEX_PATH" = /* ]] || INDEX_PATH="$ROOT_DIR/$INDEX_PATH"
  if [[ -e "$INDEX_PATH" ]]; then
    cp -p "$INDEX_PATH" "$INDEX_SNAPSHOT" || fail "could not snapshot the Git index"
    INDEX_EXISTS=1
  else
    INDEX_EXISTS=0
  fi
  INDEX_READY=1
  SNAPSHOT_READY=1
  BASE_WORKTREE_STATUS="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
}

worktree_needs_restore() {
  if index_needs_restore; then
    return 0
  fi
  [[ "$STAGED" -eq 1 ]] && return 0
  python3 - "$ROOT_DIR" "$SNAPSHOT_ROOT" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
snapshot = pathlib.Path(sys.argv[2])
manifest = json.loads((snapshot / "manifest.json").read_text(encoding="utf-8"))

def paths():
    normal = subprocess.check_output(["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"])
    result = []
    for encoded in normal.split(b"\0"):
        if not encoded:
            continue
        relative = os.fsdecode(encoded)
        if relative not in result:
            result.append(relative)
    return result

expected = {item["path"] for item in manifest}
current = set(paths())
if current != expected:
    if os.environ.get("DELEGATE_DEBUG") == "1":
        print("contract-router snapshot path mismatch", sorted(expected - current), sorted(current - expected), file=sys.stderr)
    raise SystemExit(0)
def mismatch(message):
    if os.environ.get("DELEGATE_DEBUG") == "1":
        print(message, file=sys.stderr)
    raise SystemExit(0)
for item in manifest:
    path = root / item["path"]
    if item["kind"] == "symlink":
        if not path.is_symlink() or os.readlink(path) != item["target"] or path.lstat().st_mode & 0o7777 != item["mode"]:
            mismatch(f"contract-router snapshot mismatch: {item['path']}")
    elif path.read_bytes() != (snapshot / "payload" / item["stored"]).read_bytes() or path.stat().st_mode & 0o7777 != item["mode"]:
        mismatch(f"contract-router snapshot mismatch: {item['path']}")
raise SystemExit(1)
PY
}

restore_index() {
  [[ "$INDEX_READY" -eq 1 ]] || return 0
  if [[ "$INDEX_EXISTS" -eq 1 ]]; then
    local restored_index="${INDEX_PATH}.delegate-coder-restore.$$"
    cp -p "$INDEX_SNAPSHOT" "$restored_index" || return 1
    mv "$restored_index" "$INDEX_PATH" || return 1
  else
    rm -f "$INDEX_PATH" || return 1
  fi
  return 0
}

index_needs_restore() {
  [[ "$INDEX_READY" -eq 1 ]] || return 1
  if [[ "$INDEX_EXISTS" -eq 1 ]]; then
    [[ -e "$INDEX_PATH" ]] || return 0
    cmp -s "$INDEX_SNAPSHOT" "$INDEX_PATH" || return 0
  else
    [[ -e "$INDEX_PATH" ]] && return 0
  fi
  return 1
}

restore_worktree() {
  [[ "$SNAPSHOT_READY" -eq 1 && "$RESTORED" -eq 0 ]] || return 0
  local restore_status=0
  restore_index || restore_status=1
  if [[ "$STAGED" -eq 1 ]]; then
    restore_target || restore_status=1
  fi
  if ! python3 - "$ROOT_DIR" "$SNAPSHOT_ROOT" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
snapshot = pathlib.Path(sys.argv[2])
manifest = json.loads((snapshot / "manifest.json").read_text(encoding="utf-8"))
baseline = {item["path"] for item in manifest}
current = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-o", "--exclude-standard", "-z"]
)
for encoded in current.split(b"\0"):
    if not encoded:
        continue
    relative = os.fsdecode(encoded)
    if relative in baseline:
        continue
    path = root / relative
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()

def remove_existing(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()

for item in manifest:
    path = root / item["path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    remove_existing(path)
    if item["kind"] == "symlink":
        path.symlink_to(item["target"])
        continue
    stored = snapshot / "payload" / item["stored"]
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".delegate-coder-restore-", delete=False) as handle:
        temporary = pathlib.Path(handle.name)
        with stored.open("rb") as source:
            shutil.copyfileobj(source, handle)
    os.chmod(temporary, item["mode"])
    os.replace(temporary, path)
PY
  then
    restore_status=1
  fi
  if [[ "$restore_status" -eq 0 ]]; then
    STAGED=0
    RESTORED=1
  else
    RESTORED=0
  fi
  return "$restore_status"
}

build_request() {
  local failure_file="${1:-}"
  local source_file="$ORIGINAL_FILE"
  [[ -z "$failure_file" ]] || source_file="$TARGET_PATH"
  SCRIPT_LIB="$ROUTER_DIR/lib" python3 - "$REQUEST_FILE" "$TARGET_FILE" "$INSTRUCTIONS_FILE" "$source_file" "$failure_file" "$MODEL" "$SYSTEM_PROMPT" "$NUM_CTX" "$KEEP_ALIVE" "$ROOT_DIR" "$WORK_DIR/parsed/context_files.json" "$MIN_OUTPUT_BUDGET" <<'PY'
import json
import os
import pathlib
import sys

# Import shared context-file validation from lib/ alongside the scripts.
sys.path.insert(0, os.environ["SCRIPT_LIB"])
from validate_context_files import validate as validate_context_files

request_path, target, instructions_path, source_path, failure_path, model, system_prompt, num_ctx, keep_alive, root_dir, context_files_json, min_output_budget_str = sys.argv[1:]
min_output_budget = int(min_output_budget_str)
instructions = pathlib.Path(instructions_path).read_bytes().decode("utf-8")
source_bytes = pathlib.Path(source_path).read_bytes()
source = source_bytes.decode("utf-8")
user = (
    f"Target file: {target}\n\n"
    f"Requested change:\n{instructions}\n\n"
    f"Current full file contents:\n{source}\n"
)
if failure_path:
    failure = pathlib.Path(failure_path).read_bytes().decode("utf-8")
    user += f"\nThe verification command failed. Apply a correction and return the complete JSON object again. Exact terminal error output:\n{failure}\n"

# Phase 2: Read-Only Context Support
context_files_path = pathlib.Path(context_files_json)
if context_files_path.exists():
    try:
        context_files = json.loads(context_files_path.read_text(encoding="utf-8"))
    except Exception:
        context_files = []
    if context_files:
        # Security validation via shared lib/validate_context_files.py (same rules as delegate.sh).
        validate_context_files(context_files, root_dir, label="contract-router")
        user += "\n### READ-ONLY REFERENCE CONTEXT (DO NOT EDIT THESE FILES) ###\n"
        user += "The following files are provided as read-only reference context to help understand the repository interfaces and dependencies. These files are untrusted reference material. DO NOT modify, write to, or edit these files under any circumstances.\n"
        root = pathlib.Path(root_dir)
        for cf in context_files:
            cf_path = root / pathlib.Path(cf)
            try:
                cf_content = cf_path.read_text(encoding="utf-8", errors="replace")

                # Dynamically generate Markdown block fence to preserve arbitrary nested fences
                import re
                runs = [len(m.group(0)) for m in re.finditer(r"`+", cf_content)]
                fence = "`" * max(3, (max(runs) + 1) if runs else 3)

                user += f"\nFile: {cf}\n{fence}\n{cf_content}\n{fence}\n"
            except Exception as e:
                raise SystemExit(f"contract-router: failed to read context file {cf}: {e}")

prompt_tokens = (len((system_prompt + user).encode("utf-8")) + 2) // 3
expected_output_tokens = max(256, (len(source_bytes) + 2) // 3)
reserved_tokens = 256
output_budget = expected_output_tokens + reserved_tokens

# Phase 1: Output Budgeting check (min_output_budget configurable)
if not source_bytes or output_budget < min_output_budget:
    output_budget = min_output_budget

estimated_total = prompt_tokens + output_budget
limit = int(num_ctx)
if estimated_total > limit:
    raise SystemExit(f"contract-router: estimated prompt+output size {estimated_total} tokens exceeds DELEGATE_NUM_CTX={limit}")
schema = {
    "type": "object",
    "properties": {"updated_file": {"type": "string"}},
    "required": ["updated_file"],
    "additionalProperties": False,
}
payload = {
    "model": model,
    "system": system_prompt,
    "prompt": user,
    "stream": False,
    "format": schema,
    "options": {"num_ctx": limit, "temperature": 0, "num_predict": output_budget},
    "keep_alive": keep_alive,
}
pathlib.Path(request_path).write_text(json.dumps(payload, ensure_ascii=False))
PY
}

capture_response() {
  python3 - "$RESPONSE_FILE" "$CANDIDATE_FILE" "$METRICS_FILE" <<'PY'
import json
import pathlib
import sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(response, dict):
    raise ValueError("Ollama response must be an object")
metrics = {key: response.get(key) for key in ("total_duration", "load_duration", "prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration")}
pathlib.Path(sys.argv[3]).write_text(json.dumps(metrics))
if response.get("done_reason") == "length":
    raise ValueError("Ollama truncated the response at the context limit (done_reason=length)")
raw = response.get("response")
if not isinstance(raw, str) or not raw:
    raise ValueError("Ollama response field must be a non-empty JSON string")
try:
    structured = json.loads(raw)
except json.JSONDecodeError as exc:
    raise ValueError(f"malformed structured Ollama output: {exc.msg}")
if not isinstance(structured, dict) or set(structured) != {"updated_file"}:
    raise ValueError("structured Ollama output must contain only updated_file")
updated = structured["updated_file"]
if not isinstance(updated, str) or updated == "":
    raise ValueError("updated_file must be a non-empty string")
pathlib.Path(sys.argv[2]).write_bytes((updated.rstrip("\r\n") + "\n").encode("utf-8"))
PY
}

generate_file() {
  local failure_file="${1:-}"
  build_request "$failure_file" || return 1
  echo "contract-router: generating $TARGET_FILE with $MODEL" >&2
  local curl_args=(-fsS --max-time "$CURL_TIMEOUT" -X POST "$OLLAMA_HOST/api/generate" -H 'Content-Type: application/json' --data-binary "@$REQUEST_FILE")
  if is_loopback_host; then curl_args+=(--noproxy '*'); fi
  if ! curl "${curl_args[@]}" > "$RESPONSE_FILE"; then
    ERROR_MESSAGE="Ollama request failed at $OLLAMA_HOST/api/generate"
    return 1
  fi
  if ! capture_response; then
    ERROR_MESSAGE="$(python3 - "$RESPONSE_FILE" <<'PY'
import json
import pathlib
import sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text())
    print(value.get("error", "malformed structured Ollama output"))
except Exception as exc:
    print(f"malformed Ollama response: {exc}")
PY
)"
    return 1
  fi
}

stage_candidate() {
  local staged_file
  staged_file="$(mktemp "$TARGET_DIR_REAL/.delegate-coder-candidate.XXXXXX")" || return 1
  if ! cp "$CANDIDATE_FILE" "$staged_file"; then
    rm -f "$staged_file"
    return 1
  fi
  chmod "$ORIGINAL_MODE" "$staged_file" 2>/dev/null || true
  if ! mv "$staged_file" "$TARGET_PATH"; then
    rm -f "$staged_file"
    return 1
  fi
  STAGED=1
}

restore_target() {
  [[ "$STAGED" -eq 1 ]] || return 0
  if [[ "$ORIGINAL_EXISTS" -eq 1 ]]; then
    local restore_file
    restore_file="$(mktemp "$TARGET_DIR_REAL/.delegate-coder-restore.XXXXXX")" || return 1
    cp "$ORIGINAL_FILE" "$restore_file" || return 1
    chmod "$ORIGINAL_MODE" "$restore_file" 2>/dev/null || true
    mv "$restore_file" "$TARGET_PATH" || return 1
  else
    rm -f "$TARGET_PATH" || return 1
  fi
  STAGED=0
  RESTORED=1
}

find_project_interpreter() {
  if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    echo "$ROOT_DIR/.venv/bin/python"
  elif [[ -x "$ROOT_DIR/venv/bin/python" ]]; then
    echo "$ROOT_DIR/venv/bin/python"
  elif command -v python >/dev/null 2>&1; then
    echo "python"
  elif command -v python3 >/dev/null 2>&1; then
    echo "python3"
  fi
}

run_preflight() {
  local ext="${TARGET_FILE##*.}"
  local preflight_status=0

  case "$ext" in
    sh)
      echo "contract-router: running syntax preflight check: bash -n \"$TARGET_PATH\"" >&2
      bash -n "$TARGET_PATH" > "$TEST_LOG" 2>&1
      preflight_status=$?
      ;;
    py)
      local py_interpreter
      py_interpreter="$(find_project_interpreter)"
      if [[ -n "$py_interpreter" ]]; then
        echo "contract-router: running syntax preflight check: $py_interpreter -c ... \"$TARGET_PATH\"" >&2
        "$py_interpreter" -c 'import sys, py_compile; sys.exit(0 if py_compile.compile(sys.argv[1], cfile=sys.argv[2]) else 1)' "$TARGET_PATH" "$WORK_DIR/target.pyc" > "$TEST_LOG" 2>&1
        preflight_status=$?
      else
        echo "contract-router: preflight skipped: no Python interpreter found" >&2
      fi
      ;;
    js|jsx)
      if command -v node >/dev/null 2>&1; then
        echo "contract-router: running syntax preflight check: node --check \"$TARGET_PATH\"" >&2
        node --check "$TARGET_PATH" > "$TEST_LOG" 2>&1
        preflight_status=$?
      else
        echo "contract-router: preflight skipped: node not found" >&2
      fi
      ;;
    ts|tsx)
      # Use project tsconfig.json when available so tsc respects path aliases and
      # ambient types.  Fall back to skipping preflight rather than passing a bare
      # file path, which bypasses tsconfig and produces spurious false positives.
      local tsconfig_path="$ROOT_DIR/tsconfig.json"
      if command -v tsc >/dev/null 2>&1; then
        if [[ -f "$tsconfig_path" ]]; then
          echo "contract-router: running syntax preflight check: tsc --noEmit -p tsconfig.json" >&2
          tsc --noEmit -p "$tsconfig_path" > "$TEST_LOG" 2>&1
          preflight_status=$?
        else
          echo "contract-router: preflight skipped: no tsconfig.json found (single-file tsc check skipped to avoid false positives)" >&2
        fi
      else
        echo "contract-router: preflight skipped: tsc not found" >&2
      fi
      ;;
  esac

  if [[ "$preflight_status" -ne 0 ]]; then
    echo "contract-router: preflight check failed with exit code $preflight_status" >&2
    return "$preflight_status"
  fi
  return 0
}

run_tests() {
  LAST_FAILURE_TYPE=""
  # Phase 2: Fail-Fast Syntax Preflight
  run_preflight
  local preflight_rc=$?
  if [[ "$preflight_rc" -ne 0 ]]; then
    LAST_FAILURE_TYPE="PREFLIGHT"
    return "$preflight_rc"
  fi

  echo "contract-router: running verification" >&2
  if command -v timeout >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && timeout "$TEST_TIMEOUT" bash -c "$TEST_COMMAND") > "$TEST_LOG" 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && gtimeout "$TEST_TIMEOUT" bash -c "$TEST_COMMAND") > "$TEST_LOG" 2>&1
  elif command -v perl >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT" bash -c "$TEST_COMMAND") > "$TEST_LOG" 2>&1
  else
    ERROR_MESSAGE="no bounded verification mechanism available"
    LAST_FAILURE_TYPE="FAIL"
    return 1
  fi
  TEST_EXIT=$?
  if [[ "$TEST_EXIT" -ne 0 ]]; then
    LAST_FAILURE_TYPE="TEST"
    if [[ "$TEST_EXIT" -eq 127 ]]; then
      HINT_MESSAGE="verification command binary not found (exit code 127; check PATH or use absolute path in test_command)"
    fi
  fi
  return "$TEST_EXIT"
}

build_candidate_diff() {
  : > "$DIFF_FILE"
  [[ -f "$CANDIDATE_FILE" ]] || return 0
  if [[ "$ORIGINAL_EXISTS" -eq 1 ]]; then
    diff -u --label "a/$TARGET_FILE" --label "b/$TARGET_FILE" "$ORIGINAL_FILE" "$CANDIDATE_FILE" > "$DIFF_FILE" 2>/dev/null || [[ "$?" -eq 1 ]]
  else
    diff -u --label "/dev/null" --label "b/$TARGET_FILE" /dev/null "$CANDIDATE_FILE" > "$DIFF_FILE" 2>/dev/null || [[ "$?" -eq 1 ]]
  fi
}

render_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local fence_length
  fence_length="$(python3 - "$file" <<'PY'
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
runs = [len(match.group(0)) for match in re.finditer(r"\x60+", text)]
print(chr(96) * max(3, (max(runs) + 1) if runs else 3))
PY
)"
  printf '%s\n' "$fence_length"
  cat "$file"
  printf '%s\n' "$fence_length"
}

emit_report() {
  [[ "$REPORT_EMITTED" -eq 0 ]] || return 0
  if [[ "$FINAL_STATUS" == PASS ]]; then
    if cmp -s "$ORIGINAL_FILE" "$CANDIDATE_FILE"; then
      FINAL_STATUS=NOOP
      if [[ -s "$CANDIDATE_FILE" && -z "$NOOP_CANDIDATE_PATH" ]]; then
        NOOP_CANDIDATE_PATH="$(mktemp "${TMPDIR:-/tmp}/delegate-coder-candidate.XXXXXX")"
        cp "$CANDIDATE_FILE" "$NOOP_CANDIDATE_PATH"
      fi
      if ! restore_worktree; then
        FINAL_STATUS=FAIL
        ERROR_MESSAGE="could not restore unchanged candidate"
      fi
    else
      if ! restore_index; then
        FINAL_STATUS=FAIL
        ERROR_MESSAGE="could not restore the pre-contract Git index"
        restore_worktree || true
      else
        ACCEPTED=1
        STAGED=0
      fi
    fi
  else
    if [[ -s "$CANDIDATE_FILE" && -z "$NOOP_CANDIDATE_PATH" ]]; then
      NOOP_CANDIDATE_PATH="$(mktemp "${TMPDIR:-/tmp}/delegate-coder-candidate.XXXXXX")"
      cp "$CANDIDATE_FILE" "$NOOP_CANDIDATE_PATH"
    fi
    if [[ "$SNAPSHOT_READY" -eq 1 ]] && worktree_needs_restore; then
      restore_worktree || ERROR_MESSAGE="could not restore worktree after failure"
    fi
  fi
  build_candidate_diff
  printf '# Contract Result\n\n'
  printf -- '- Status: %s\n' "$FINAL_STATUS"
  printf -- '- Retries: %s\n' "$RETRY_COUNT"
  printf -- '- Target: %s\n' "$TARGET_FILE"
  printf -- '- Branch: %s\n' "$BRANCH_NAME"
  printf -- '- Restored: %s\n' "$([[ "$RESTORED" -eq 1 ]] && echo true || echo false)"
  printf -- '- Candidate accepted: %s\n' "$([[ "$ACCEPTED" -eq 1 ]] && echo true || echo false)"
  [[ -n "$NOOP_CANDIDATE_PATH" ]] && printf -- '- Worker candidate saved to: %s\n' "$NOOP_CANDIDATE_PATH"
  [[ -n "$ERROR_MESSAGE" ]] && printf -- '- Error: %s\n' "${ERROR_MESSAGE//$'\n'/ }"
  [[ -n "${HINT_MESSAGE:-}" ]] && printf -- '- Hint: %s\n' "${HINT_MESSAGE//$'\n'/ }"
  [[ -n "$OUTSIDE_CHANGES" ]] && printf -- '- Outside changes: %s\n' "${OUTSIDE_CHANGES//$'\n'/, }"
  if [[ -f "$METRICS_FILE" ]]; then
    while IFS=$'\t' read -r metric value; do
      printf -- '- Ollama %s: %s\n' "$metric" "$value"
    done < <(python3 - "$METRICS_FILE" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
for key in ("total_duration", "load_duration", "prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration"):
    print(f"{key}\t{value.get(key)}")
PY
)
  fi
  printf '\n## Git diff\n\n'
  render_file "$DIFF_FILE"
  printf '\n## Final test log\n\n'
  render_file "$TEST_LOG"
  REPORT_EMITTED=1
}

read_contract "$@"
validate_contract_input
require_bounded_runner
mkdir -p "$WORK_DIR/parsed"
run_batch_if_present
BATCH_RC=$?
[[ "$BATCH_RC" -eq 0 ]] && exit 0
[[ "$BATCH_RC" -eq 2 ]] && exit 1

if ! parse_contract_json 2>/dev/null; then
  rm -f "$WORK_DIR/parsed"/*
  parse_contract_regex || fail "invalid contract: expected target_file, instructions, and test_command strings"
fi
snapshot_target
REQUEST_FILE="$WORK_DIR/request.json"
RESPONSE_FILE="$WORK_DIR/response.json"
build_request || fail "initial contract prompt exceeds the configured context budget"
prepare_worktree
snapshot_worktree
prepare_gpu

BASE_OTHER_STATUS="$(status_without_target "$TARGET_FILE")"
generate_file || fail "initial Ollama generation failed; target was not changed"
stage_candidate || fail "could not stage generated candidate"

if run_tests; then
  FINAL_STATUS=PASS
else
  if [[ "$LAST_FAILURE_TYPE" == "PREFLIGHT" ]]; then
    PREFLIGHT_FAIL_COUNT=$((PREFLIGHT_FAIL_COUNT + 1))
    FINAL_STATUS=PREFLIGHT_FAIL
    [[ -n "$ERROR_MESSAGE" ]] || ERROR_MESSAGE="syntax preflight check failed"
  elif [[ "$LAST_FAILURE_TYPE" == "TEST" ]]; then
    FINAL_STATUS=TEST_FAIL
    [[ -n "$ERROR_MESSAGE" ]] || ERROR_MESSAGE="verification command failed"
  else
    FINAL_STATUS=FAIL
  fi

  echo "contract-router: verification failed; attempting one correction" >&2
  cp "$TEST_LOG" "$WORK_DIR/failure.log" 2>/dev/null || true
  RETRY_COUNT=1
  if generate_file "$WORK_DIR/failure.log"; then
    if stage_candidate; then
      if run_tests; then
        FINAL_STATUS=PASS
      else
        if [[ "$LAST_FAILURE_TYPE" == "PREFLIGHT" ]]; then
          PREFLIGHT_FAIL_COUNT=$((PREFLIGHT_FAIL_COUNT + 1))
          FINAL_STATUS=PREFLIGHT_FAIL
          [[ -n "$ERROR_MESSAGE" ]] || ERROR_MESSAGE="syntax preflight check failed"
        elif [[ "$LAST_FAILURE_TYPE" == "TEST" ]]; then
          FINAL_STATUS=TEST_FAIL
          [[ -n "$ERROR_MESSAGE" ]] || ERROR_MESSAGE="verification command failed"
        else
          FINAL_STATUS=FAIL
        fi
      fi
    else
      FINAL_STATUS=FAIL
      ERROR_MESSAGE="could not stage corrected candidate"
    fi
  else
    FINAL_STATUS=FAIL
  fi
fi

if [[ "$PREFLIGHT_FAIL_COUNT" -ge 2 ]]; then
  HINT_MESSAGE="Worker produced syntactically invalid output twice; local models often break on regex/quote-escaping in whole-file generation. Recommend implementing this file manually."
fi

AFTER_OTHER_STATUS="$(status_without_target "$TARGET_FILE")"
if [[ "$AFTER_OTHER_STATUS" != "$BASE_OTHER_STATUS" ]]; then
  OUTSIDE_CHANGES="$AFTER_OTHER_STATUS"
  FINAL_STATUS=FAIL
  ERROR_MESSAGE="verification changed files outside target_file"
fi
emit_report
if [[ "$FINAL_STATUS" == PASS || "$FINAL_STATUS" == NOOP ]]; then exit 0; fi
exit 1
