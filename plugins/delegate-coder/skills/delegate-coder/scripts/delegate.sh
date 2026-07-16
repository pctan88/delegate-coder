#!/usr/bin/env bash
# delegate.sh — route a task to the configured worker coding agent.
# Usage: delegate.sh <read|exec> "<task spec>"
#        delegate.sh contract ["<task contract JSON>"]
set -uo pipefail
# Enhance PATH with common installation directories for worker agents
EXTRA_PATHS="${DELEGATE_PATH_EXTRA:-}"
COMMON_DIRS="$HOME/.mimocode/bin:$HOME/.local/bin:$HOME/.cargo/bin"
export PATH="$EXTRA_PATHS:$COMMON_DIRS:$PATH"

MODE="${1:-}"
TASK="${2:-}"
DELEGATE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
CONFIG="$DELEGATE_ROOT/.delegate-coder/config.json"
LEGACY_CONFIG="$DELEGATE_ROOT/.claude/delegate-coder.json"
if [[ ! -f "$CONFIG" && -f "$LEGACY_CONFIG" ]]; then
  CONFIG="$LEGACY_CONFIG"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

config_get() {
  local path="$1"
  [[ -f "$CONFIG" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r ".${path} // empty" "$CONFIG" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG" "$path" <<'PY'
import json
import pathlib
import sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text())
    for part in sys.argv[2].split('.'):
        value = value.get(part) if isinstance(value, dict) else None
        if value is None:
            break
    if isinstance(value, (str, int, float)) and not isinstance(value, bool):
        print(value)
except Exception:
    pass
PY
  fi
}

append_json_event() {
  local logfile="$1" agent="$2" model="$3" mode="$4" event="$5"
  shift 5
  mkdir -p "$(dirname "$logfile")" 2>/dev/null || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$logfile" "$agent" "$model" "$mode" "$event" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$@" <<'PY'
import json
import pathlib
import sys
record = {
    "ts": sys.argv[6],
    "agent": sys.argv[2],
    "model": sys.argv[3],
    "mode": sys.argv[4],
    "event": sys.argv[5],
}
extra = sys.argv[7:]
for index in range(0, len(extra), 2):
    key, value = extra[index:index + 2]
    if key in {"duration_s", "exit_code", "retries", "total_duration", "load_duration", "prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration"}:
        try:
            record[key] = int(value)
        except ValueError:
            try:
                record[key] = float(value)
            except ValueError:
                record[key] = None if value == "None" else value
    elif key == "restored":
        record[key] = value == "true"
    else:
        record[key] = value
with pathlib.Path(sys.argv[1]).open("a") as output:
    output.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
  elif command -v jq >/dev/null 2>&1; then
    jq -n --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg agent "$agent" --arg model "$model" --arg mode "$mode" --arg event "$event" \
      '{ts:$ts,agent:$agent,model:$model,mode:$mode,event:$event}' >> "$logfile"
  fi
}

validate_contract_entry() {
  local contract="$1" first_nonspace
  first_nonspace="$(printf '%s' "$contract" | sed -n '/[^[:space:]]/s/^[[:space:]]*\(.\).*/\1/p' | head -n1)"
  if command -v python3 >/dev/null 2>&1; then
    if CONTRACT_INPUT="$contract" python3 - <<'PY' 2>/dev/null
import json
import os
value = json.loads(os.environ["CONTRACT_INPUT"])
items = value if isinstance(value, list) else [value]
if not items:
    raise ValueError("contract batch must be non-empty")
for item in items:
    if not isinstance(item, dict):
        raise ValueError("contract must be an object")
    for key in ("target_file", "instructions", "test_command"):
        if not isinstance(item.get(key), str):
            raise ValueError(f"{key} must be a string")
    # Phase 2: Accept optional context_files array in entry validation
    if "context_files" in item and item["context_files"] is not None:
        if not isinstance(item["context_files"], list) or not all(isinstance(f, str) for f in item["context_files"]):
            raise ValueError("context_files must be an array of strings")
PY
    then
      return 0
    fi
  elif [[ "$first_nonspace" == "[" ]]; then
    echo "contract mode requires python3 for contract batches" >&2
    return 1
  fi
  [[ "$first_nonspace" != "[" ]] || { echo "invalid contract batch" >&2; return 1; }
  local key
  for key in target_file instructions test_command; do
    printf '%s' "$contract" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n1 | grep -q . || {
      echo "invalid contract: expected target_file, instructions, and test_command strings" >&2
      return 1
    }
  done
}

validate_contract_paths() {
  local contract="$1" root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "contract mode requires a Git worktree" >&2
    return 1
  }
  [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || {
    echo "contract mode requires a Git worktree" >&2
    return 1
  }
  CONTRACT_INPUT="$contract" ROOT_INPUT="$root" python3 - <<'PY'
import json
import os
import pathlib
import subprocess
from pathlib import PurePosixPath

root = pathlib.Path(os.environ["ROOT_INPUT"]).resolve()
raw = os.environ["CONTRACT_INPUT"]
try:
    value = json.loads(raw)
    items = value if isinstance(value, list) else [value]
except json.JSONDecodeError:
    import re
    match = re.search(r'"target_file"\s*:\s*"([^\"]*)"', raw)
    if not match:
        raise ValueError("invalid contract target_file")
    items = [{"target_file": match.group(1)}]

for index, item in enumerate(items, 1):
    target = item.get("target_file")
    if not isinstance(target, str) or not target:
        raise ValueError(f"contract {index}: target_file must be a non-empty string")
    pure = PurePosixPath(target)
    if pure.is_absolute() or target.startswith("~/") or ".." in pure.parts:
        raise ValueError(f"target_file resolves outside the repository: {target}")
    target_path = root / pathlib.Path(target)
    parent = target_path.parent
    try:
        parent_real = parent.resolve(strict=True)
    except FileNotFoundError:
        raise ValueError(f"target directory does not exist: {parent.relative_to(root)}")
    if parent_real != root and root not in parent_real.parents:
        raise ValueError(f"target_file resolves outside the repository: {target}")
    if target_path.is_symlink():
        raise ValueError(f"target_file must not be a symlink: {target}")
    if target_path.exists() and not target_path.is_file():
        raise ValueError(f"target_file must be a regular file: {target}")
    status = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all", "--", target],
        text=True,
    )
    if status:
        raise ValueError(f"target_file is dirty; commit or stash it before contract execution: {target}")

    # Phase 2: Validate context_files paths
    context_files = item.get("context_files", [])
    if context_files is None:
        context_files = []
    if not isinstance(context_files, list):
        raise ValueError(f"contract {index}: context_files must be a JSON array")

    total_context_size = 0
    for cf in context_files:
        if not isinstance(cf, str) or not cf:
            raise ValueError(f"contract {index}: context_files items must be non-empty strings")
        cf_pure = PurePosixPath(cf)
        if cf_pure.is_absolute() or cf.startswith("~/") or ".." in cf_pure.parts:
            raise ValueError(f"context file resolves outside the repository: {cf}")

        # Check directories for blocked sensitive ones (case-insensitive, including .git)
        for part in cf_pure.parts:
            if part.lower() in [".aws", ".ssh", ".kube", ".docker", ".git"]:
                raise ValueError(f"context file path contains a blocked sensitive directory: {cf}")

        # Check for secret-like filenames
        cf_name = cf_pure.name.lower()
        secret_keywords = ["credential", "private_key", "secret", "password", "passwd", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
        secret_extensions = [".pem", ".key", ".pkcs12", ".pfx", ".p12", ".gpg", ".pgp", ".vault"]
        if cf_name.startswith(".env") or \
           cf_name in [".npmrc", ".netrc", ".git-credentials"] or \
           any(kw in cf_name for kw in secret_keywords) or \
           any(cf_name.endswith(ext) for ext in secret_extensions):
            raise ValueError(f"context file contains sensitive/secret data: {cf}")

        cf_path = root / pathlib.Path(cf)
        if not cf_path.exists():
            raise ValueError(f"context file does not exist: {cf}")

        # Ensure the resolved path remains inside the repository
        root_real = root.resolve()
        cf_path_real = cf_path.resolve(strict=True)
        if root_real not in cf_path_real.parents and cf_path_real != root_real:
            raise ValueError(f"context file resolves outside the repository: {cf}")

        # Check if any component in the path (from root to target) is a symlink
        current = root
        for part in pathlib.Path(cf).parts:
            current = current / part
            if current.is_symlink():
                raise ValueError(f"context file path contains a symlink: {cf}")

        if not cf_path.is_file():
            raise ValueError(f"context file must be a regular file: {cf}")

        # Check size caps
        file_size = cf_path.stat().st_size
        if file_size > 65536:
            raise ValueError(f"context file size exceeds 64KB: {cf}")
        total_context_size += file_size
        if total_context_size > 262144:
            raise ValueError(f"total context files size exceeds 256KB")
PY
}

resolve_contract_settings() {
  CONTRACT_MODEL="${DELEGATE_MODEL:-$(config_get contract.model)}"
  CONTRACT_MODEL="${CONTRACT_MODEL:-qwen3-coder:30b}"
  CONTRACT_NUM_CTX="${DELEGATE_NUM_CTX:-$(config_get contract.num_ctx)}"
  CONTRACT_NUM_CTX="${CONTRACT_NUM_CTX:-32768}"
  CONTRACT_KEEP_ALIVE="${DELEGATE_KEEP_ALIVE:-$(config_get contract.keep_alive)}"
  CONTRACT_KEEP_ALIVE="${CONTRACT_KEEP_ALIVE:-30m}"
  CONTRACT_CURL_TIMEOUT="${DELEGATE_CURL_TIMEOUT:-$(config_get contract.curl_timeout)}"
  CONTRACT_CURL_TIMEOUT="${CONTRACT_CURL_TIMEOUT:-600}"
  CONTRACT_TEST_TIMEOUT="${DELEGATE_TEST_TIMEOUT:-$(config_get contract.test_timeout)}"
  CONTRACT_TEST_TIMEOUT="${CONTRACT_TEST_TIMEOUT:-300}"
  CONTRACT_MIN_OUTPUT_BUDGET="${DELEGATE_MIN_OUTPUT_BUDGET:-$(config_get contract.min_output_budget)}"
  CONTRACT_MIN_OUTPUT_BUDGET="${CONTRACT_MIN_OUTPUT_BUDGET:-4096}"
  local setting_name setting_value
  for setting_name in CONTRACT_NUM_CTX CONTRACT_CURL_TIMEOUT CONTRACT_TEST_TIMEOUT CONTRACT_MIN_OUTPUT_BUDGET; do
    setting_value="${!setting_name}"
    case "$setting_value" in
      ''|*[!0-9]*|0) echo "contract mode: $setting_name must be a strictly positive integer" >&2; return 1 ;;
    esac
  done
  [[ "$CONTRACT_MIN_OUTPUT_BUDGET" -ge 4096 ]] || { echo "contract mode: CONTRACT_MIN_OUTPUT_BUDGET must be >= 4096" >&2; return 1; }
}

ensure_runtime_log_ignored() {
  local root="$1" rel_exclude exclude migration_status
  rel_exclude="$(git -C "$root" rev-parse --git-path info/exclude 2>/dev/null)" || return 1
  if [[ "$rel_exclude" == /* ]]; then
    exclude="$rel_exclude"
  else
    exclude="$root/$rel_exclude"
  fi
  mkdir -p "$(dirname "$exclude")" || return 1
  touch "$exclude" || return 1
  python3 - "$exclude" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
marker = b"# delegate-coder runtime log (local metadata)"
broad = b"/.claude/"
narrow = b"/.claude/delegate-coder.log"
lines = path.read_bytes().splitlines(keepends=True)
cleaned = []
index = 0
while index < len(lines):
    current = lines[index].rstrip(b"\r\n")
    following = lines[index + 1].rstrip(b"\r\n") if index + 1 < len(lines) else None
    if current == marker and following == broad:
        index += 2
        continue
    cleaned.append(lines[index])
    index += 1

if any(line.rstrip(b"\r\n") == broad for line in cleaned):
    print(
        "contract mode: refusing to remove an unmarked /.claude/ exclusion "
        "from .git/info/exclude; remove it manually or mark the exact "
        "delegate-coder legacy stanza before retrying",
        file=sys.stderr,
    )
    raise SystemExit(2)

data = b"".join(cleaned)
if not any(line.rstrip(b"\r\n") == narrow for line in cleaned):
    if data and not data.endswith(b"\n"):
        data += b"\n"
    data += b"\n# delegate-coder runtime log (local metadata)\n" + narrow + b"\n"
path.write_bytes(data)
PY
  migration_status=$?
  if [[ "$migration_status" -eq 2 ]]; then
    return 1
  fi
  [[ "$migration_status" -eq 0 ]] || return 1
}

prepare_contract_entry() {
  local root branch dirty
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "contract mode requires a Git worktree" >&2; return 1; }
  [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || { echo "contract mode requires a Git worktree" >&2; return 1; }
  branch="$(git branch --show-current 2>/dev/null)"
  [[ -n "$branch" ]] || { echo "contract mode requires a named feature/delegate branch" >&2; return 1; }
  ensure_runtime_log_ignored "$root" || { echo "could not configure the local runtime-log exclusion" >&2; return 1; }
  dirty="$(git status --porcelain --untracked-files=all)"
  [[ -z "$dirty" ]] || { echo "contract mode requires a clean worktree before the first write" >&2; return 1; }
  CONTRACT_BRANCH="$branch"
  CONTRACT_ROOT="$root"
}

report_value() {
  sed -n "s/^- $1: //p" "$2" | head -n1
}

# Contract mode is intentionally independent of the configured chat worker.
# It reads stdin when the JSON argument is omitted.
if [[ "$MODE" == "contract" ]]; then
  if [[ $# -ge 2 ]]; then
    TASK="$2"
  else
    TASK="$(cat)" || exit 1
  fi
  validate_contract_entry "$TASK" || exit 1
  validate_contract_paths "$TASK" || exit 1
  resolve_contract_settings || exit 1
  prepare_contract_entry || exit 1
  CONTRACT_LOGFILE="$CONTRACT_ROOT/.claude/delegate-coder.log"
  CONTRACT_T0="$(date +%s)"
  export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  append_json_event "$CONTRACT_LOGFILE" local-ollama "$CONTRACT_MODEL" contract start branch "$CONTRACT_BRANCH"
  CONTRACT_REPORT="$(mktemp "${TMPDIR:-/tmp}/delegate-coder-report.XXXXXX")" || exit 1
  export DELEGATE_MODEL="$CONTRACT_MODEL" DELEGATE_NUM_CTX="$CONTRACT_NUM_CTX" DELEGATE_KEEP_ALIVE="$CONTRACT_KEEP_ALIVE" DELEGATE_CURL_TIMEOUT="$CONTRACT_CURL_TIMEOUT" DELEGATE_TEST_TIMEOUT="$CONTRACT_TEST_TIMEOUT" DELEGATE_MIN_OUTPUT_BUDGET="$CONTRACT_MIN_OUTPUT_BUDGET"
  # Phase 1: Robust Script Execution (prevent chmod +x loss)
  bash "$SCRIPT_DIR/contract-router.sh" "$TASK" > "$CONTRACT_REPORT"
  CONTRACT_EXIT=$?
  cat "$CONTRACT_REPORT"
  CONTRACT_STATUS="$(report_value Status "$CONTRACT_REPORT")"
  case "$CONTRACT_STATUS" in
    PASS|NOOP|FAIL) ;;
    *) CONTRACT_STATUS="ERROR" ;;
  esac
  CONTRACT_RETRIES="$(report_value Retries "$CONTRACT_REPORT")"
  [[ -n "$CONTRACT_RETRIES" ]] || CONTRACT_RETRIES=0
  CONTRACT_RESTORED="$(report_value Restored "$CONTRACT_REPORT")"
  CONTRACT_ERROR="$(report_value Error "$CONTRACT_REPORT")"
  CONTRACT_BRANCH="$(report_value Branch "$CONTRACT_REPORT")"
  append_json_event "$CONTRACT_LOGFILE" local-ollama "$CONTRACT_MODEL" contract end \
    duration_s "$(( $(date +%s) - CONTRACT_T0 ))" exit_code "$CONTRACT_EXIT" status "$CONTRACT_STATUS" retries "$CONTRACT_RETRIES" restored "${CONTRACT_RESTORED:-false}" branch "${CONTRACT_BRANCH:-$CONTRACT_BRANCH}" error "$CONTRACT_ERROR" \
    total_duration "$(report_value 'Ollama total_duration' "$CONTRACT_REPORT")" load_duration "$(report_value 'Ollama load_duration' "$CONTRACT_REPORT")" prompt_eval_count "$(report_value 'Ollama prompt_eval_count' "$CONTRACT_REPORT")" prompt_eval_duration "$(report_value 'Ollama prompt_eval_duration' "$CONTRACT_REPORT")" eval_count "$(report_value 'Ollama eval_count' "$CONTRACT_REPORT")" eval_duration "$(report_value 'Ollama eval_duration' "$CONTRACT_REPORT")"
  rm -f "$CONTRACT_REPORT"
  exit "$CONTRACT_EXIT"
fi

if [[ -z "$MODE" || -z "$TASK" ]]; then
  echo "Usage: delegate.sh <read|exec> \"<task spec>\"" >&2
  echo "       delegate.sh contract [\"<task contract JSON>\"]" >&2
  exit 2
fi
if [[ "$MODE" != "read" && "$MODE" != "exec" ]]; then
  echo "Mode must be 'read' or 'exec', got: $MODE" >&2
  exit 2
fi

IMPLEMENTATION_BACKEND="$(config_get implementation_backend)"
IMPLEMENTATION_BACKEND="${IMPLEMENTATION_BACKEND:-agent}"
case "$IMPLEMENTATION_BACKEND" in
  agent) ;;
  contract)
    [[ "$MODE" == exec ]] || { echo "implementation_backend=contract applies only to exec implementation tasks" >&2; exit 2; }
    first_nonspace="$(printf '%s' "$TASK" | tr -d '[:space:]' | cut -c1)"
    [[ "$first_nonspace" == '{' || "$first_nonspace" == '[' ]] || {
      echo "implementation_backend=contract requires a JSON Task Contract; no hosted-agent fallback is performed" >&2
      exit 2
    }
    # Phase 1: Robust Script Execution (prevent chmod +x loss)
    exec bash "$SCRIPT_DIR/delegate.sh" contract "$TASK"
    ;;
  *)
    echo "Unsupported implementation_backend: $IMPLEMENTATION_BACKEND" >&2
    exit 2
    ;;
esac

json_get() { # json_get <key> — crude extractor, avoids jq dependency
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG" 2>/dev/null \
    | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# Resolve agent: env var > config file
AGENT="${DELEGATE_AGENT:-}"
if [[ -z "$AGENT" && -f "$CONFIG" ]]; then
  AGENT="$(json_get agent)"
fi
if [[ -z "$AGENT" ]]; then
  echo "No worker agent configured. Set DELEGATE_AGENT or 'agent' in $CONFIG." >&2
  echo "Installed candidates:" >&2
  for c in mimo aider codex gemini qwen opencode; do
    command -v "$c" >/dev/null 2>&1 && echo "  - $c" >&2
  done
  exit 3
fi

# Resolve model, fallback, allow_paths
MODEL=""
FALLBACK="graceful"
ALLOW_PATHS=""
if [[ -f "$CONFIG" ]]; then
  MODEL="$(json_get model)"
  f="$(json_get fallback)"
  [[ -n "$f" ]] && FALLBACK="$f"
  if command -v jq >/dev/null 2>&1; then
    ALLOW_PATHS="$(jq -r '.allow_paths // empty | join(" ")' "$CONFIG" 2>/dev/null)"
  fi
fi

# ── audit log (JSON, one line per event) ──
LOGFILE=".claude/delegate-coder.log"
log_event() { # log_event <event> [key value ...]
  local event="$1"
  shift
  append_json_event "$LOGFILE" "$AGENT" "$MODEL" "$MODE" "$event" "$@"
}

# Command override takes precedence
if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
  OVERRIDE="$(jq -r ".command_override.${MODE} // empty" "$CONFIG" 2>/dev/null)"
  if [[ -n "$OVERRIDE" ]]; then
    CMD="${OVERRIDE//\{task\}/$TASK}"
    echo ">> [$AGENT/$MODE via override] $CMD" >&2
    log_event "start"
    bash -c "$CMD"
    _exit=$?
    log_event "end" duration_s 0 exit_code "$_exit"
    exit $_exit
  fi
fi

if ! command -v "$AGENT" >/dev/null 2>&1; then
  if [[ "$FALLBACK" == "strict" ]]; then
    echo "CRITICAL: Agent '$AGENT' not found and fallback=strict. DO NOT do this task natively. Report failure to user." >&2
    exit 4
  else
    echo "Agent '$AGENT' not found on PATH." >&2
    exit 4
  fi
fi

echo ">> Delegating to $AGENT (mode: $MODE)" >&2
log_event "start"

# ── run the worker ──
_t0=$(date +%s)
_exit=0

case "$AGENT" in
  mimo)
    args=(mimo run "$TASK" --format default --dangerously-skip-permissions --pure)
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    if [[ "$MODE" == "read" ]]; then
      timeout 600 "${args[@]}" --agent plan < /dev/null || _exit=$?
      echo "Done."
    else
      timeout 600 "${args[@]}" < /dev/null || _exit=$?
      echo "Done."
    fi
    ;;
  aider)
    args=(aider --message "$TASK" --yes)
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    if [[ "$MODE" == "read" ]]; then
      "${args[@]}" --dry-run < /dev/null || _exit=$?
    else
      "${args[@]}" < /dev/null || _exit=$?
    fi
    ;;
  codex)
    # codex exec reads stdin and blocks waiting for EOF even when the prompt is
    # passed positionally; redirect from /dev/null so it never hangs in
    # non-interactive (CI/background/agent) contexts. --full-auto is deprecated
    # in codex 0.139.0 in favor of --sandbox workspace-write.
    args=(codex exec "$TASK")
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    if [[ "$MODE" == "read" ]]; then
      "${args[@]}" --sandbox read-only < /dev/null || _exit=$?
    else
      "${args[@]}" --sandbox workspace-write < /dev/null || _exit=$?
    fi
    ;;
  gemini|qwen)
    args=("$AGENT" -p "$TASK")
    [[ -n "$MODEL" ]] && args+=(-m "$MODEL")
    if [[ "$MODE" == "read" ]]; then
      "${args[@]}" < /dev/null || _exit=$?
    else
      "${args[@]}" --yolo < /dev/null || _exit=$?
    fi
    ;;
  opencode)
    args=(opencode run "$TASK")
    [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
    "${args[@]}" < /dev/null || _exit=$?
    ;;
  *)
    echo "No built-in adapter for '$AGENT'." >&2
    exit 5
    ;;
esac

_t1=$(date +%s)
log_event "end" duration_s "$((_t1 - _t0))" exit_code "$_exit"

# ── path allowlist check ──
if [[ "$MODE" == "exec" && -n "$ALLOW_PATHS" && $_exit -eq 0 ]]; then
  echo ">> Checking allow_paths..." >&2
  # Convert to array for robust prefix matching
  IFS=' ' read -r -a allowed_array <<< "$ALLOW_PATHS"
  
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    allowed=0
    for p in "${allowed_array[@]}"; do
      if [[ "$file" == "$p"* ]]; then
        allowed=1
        break
      fi
    done
    if [[ $allowed -eq 0 ]]; then
      echo "WARNING: Worker modified '$file' which is outside allow_paths! ($ALLOW_PATHS)" >&2
      exit 6
    fi
  done < <(git diff --name-only)
fi

exit $_exit
