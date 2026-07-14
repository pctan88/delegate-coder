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
CONFIG=".claude/delegate-coder.json"

# Contract mode is intentionally independent of the configured chat worker.
# It reads stdin when the JSON argument is omitted.
if [[ "$MODE" == "contract" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CONTRACT_LOGFILE=".claude/delegate-coder.log"
  CONTRACT_MODEL="${DELEGATE_MODEL:-qwen3-coder:30b}"
  CONTRACT_T0="$(date +%s)"
  mkdir -p "$(dirname "$CONTRACT_LOGFILE")" 2>/dev/null || true
  printf '{"ts":"%s","agent":"local-ollama","model":"%s","mode":"contract","event":"start"}\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$CONTRACT_MODEL" >> "$CONTRACT_LOGFILE" 2>/dev/null || true
  CONTRACT_REPORT="$(mktemp "${TMPDIR:-/tmp}/delegate-coder-report.XXXXXX")" || exit 1
  if [[ $# -ge 2 ]]; then
    "$SCRIPT_DIR/contract-router.sh" "$TASK" > "$CONTRACT_REPORT"
  else
    "$SCRIPT_DIR/contract-router.sh" > "$CONTRACT_REPORT"
  fi
  CONTRACT_EXIT=$?
  cat "$CONTRACT_REPORT"
  CONTRACT_STATUS="$(sed -n 's/^- Status: //p' "$CONTRACT_REPORT" | head -n1)"
  case "$CONTRACT_STATUS" in
    PASS|NOOP|FAIL) ;;
    *) CONTRACT_STATUS="ERROR" ;;
  esac
  CONTRACT_RETRIES=0
  CONTRACT_RETRIES="$(sed -n 's/^- Retries: //p' "$CONTRACT_REPORT" | head -n1)"
  [[ -n "$CONTRACT_RETRIES" ]] || CONTRACT_RETRIES=0
  rm -f "$CONTRACT_REPORT"
  printf '{"ts":"%s","agent":"local-ollama","model":"%s","mode":"contract","event":"end","duration_s":%s,"exit_code":%s,"status":"%s","retries":%s}\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$CONTRACT_MODEL" "$(( $(date +%s) - CONTRACT_T0 ))" "$CONTRACT_EXIT" "$CONTRACT_STATUS" "$CONTRACT_RETRIES" >> "$CONTRACT_LOGFILE" 2>/dev/null || true
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
log_event() { # log_event <event> [extra_fields]
  local event="$1" extra="${2:-}"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  local line="{\"ts\":\"$ts\",\"agent\":\"$AGENT\",\"model\":\"${MODEL}\",\"mode\":\"$MODE\",\"event\":\"$event\"${extra}}"
  # Tolerate a missing .claude/ dir (e.g. worker run in a bare repo); never
  # let a logging failure abort the delegation.
  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || return 0
  echo "$line" >> "$LOGFILE" 2>/dev/null || true
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
    log_event "end" ",\"duration_s\":0,\"exit_code\":$_exit"
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
log_event "end" ",\"duration_s\":$((_t1 - _t0)),\"exit_code\":$_exit"

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
