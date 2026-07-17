#!/usr/bin/env bash
# core.test.sh — deterministic tests for the foundational orchestration scripts
# (delegate.sh dispatch/adapters/fallback/allow_paths/audit, detect-test.sh).
# Uses a fake worker on PATH and temp fixtures; no real agent, network, or model.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
DISPATCH="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh"
DETECT_TEST="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/detect-test.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/delegate-coder-core-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/home"

# The host may have a real worker installed. Keep the fixture's missing-agent
# cases from finding or invoking it, while preserving the rest of the test
# toolchain on PATH. Those cases also use a deliberately nonexistent agent
# name rather than a real adapter name.
REAL_CODEX="$(type -P codex 2>/dev/null || true)"
REAL_CODEX_DIR="${REAL_CODEX%/*}"
TEST_PATH=""
IFS=: read -r -a PATH_PARTS <<< "${PATH:-}"
for path_entry in "${PATH_PARTS[@]}"; do
  [[ -n "$REAL_CODEX" && "$path_entry" == "$REAL_CODEX_DIR" ]] && continue
  if [[ -z "$TEST_PATH" ]]; then
    TEST_PATH="$path_entry"
  else
    TEST_PATH="$TEST_PATH:$path_entry"
  fi
done
[[ -n "$TEST_PATH" ]] || TEST_PATH="/usr/bin:/bin"

PASS=0
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; PASS=$((PASS + 1)); }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }
absent()   { grep -Fq -- "$2" "$1" && fail "$3"; return 0; }

# Build a case dir: a git repo with a fake worker "codex" that records its argv
# and (optionally) modifies a tracked file named by $FAKE_TOUCH.
setup_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/lib" "$CASE_DIR/src"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" config user.email test@example.invalid
  git -C "$CASE_DIR" config user.name test
  printf 'a\n' > "$CASE_DIR/lib/keep.txt"
  printf 'b\n' > "$CASE_DIR/src/other.txt"
  git -C "$CASE_DIR" add -A
  git -C "$CASE_DIR" commit -qm initial

  cat > "$CASE_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_ARGV:?FAKE_ARGV required}"
[[ -n "${FAKE_TOUCH:-}" ]] && printf 'changed\n' >> "$FAKE_TOUCH"
exit "${FAKE_EXIT:-0}"
SH
  chmod +x "$CASE_DIR/bin/codex"
  export DELEGATE_PATH_EXTRA="$CASE_DIR/bin"
  export FAKE_ARGV="$CASE_DIR/argv.log"
  : > "$FAKE_ARGV"
  unset FAKE_TOUCH FAKE_EXIT DELEGATE_AGENT
}

run_dispatch() {
  (
    cd "$CASE_DIR" || exit 1
    HOME="$TEST_ROOT/home" \
    PATH="$CASE_DIR/bin:$TEST_PATH" \
    DELEGATE_PATH_EXTRA="$CASE_DIR/bin" \
    bash "$DISPATCH" "$@"
  )
}

# ── delegate.sh: argument validation ──────────────────────────────────────
setup_case argval
run_dispatch bogus "task" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 2 ]] || fail "invalid mode should exit 2 (got $rc)"
contains "$CASE_DIR/err" "read" "invalid mode should print usage"
pass "invalid mode exits 2 with usage"

run_dispatch read "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] || fail "empty task should exit 2 (got $rc)"
pass "empty task exits 2"

# ── delegate.sh: no agent configured ──────────────────────────────────────
setup_case noagent
run_dispatch read "summarize repo" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 3 ]] || fail "no agent should exit 3 (got $rc)"
contains "$CASE_DIR/err" "No worker agent configured" "should explain missing agent"
pass "no agent configured exits 3"

# ── delegate.sh: agent from DELEGATE_AGENT + read/exec mapping ─────────────
setup_case fromenv
DELEGATE_AGENT=codex run_dispatch read "understand src" >/dev/null 2>&1 || fail "env-agent read run failed"
contains "$FAKE_ARGV" "read-only" "read mode should use --sandbox read-only"
absent   "$FAKE_ARGV" "workspace-write" "read mode must not use workspace-write"
pass "agent resolved from DELEGATE_AGENT; read maps to read-only"

setup_case execmap
DELEGATE_AGENT=codex run_dispatch exec "implement x" >/dev/null 2>&1 || fail "env-agent exec run failed"
contains "$FAKE_ARGV" "workspace-write" "exec mode should use --sandbox workspace-write"
pass "exec maps to workspace-write"

# ── delegate.sh: agent + model from config ────────────────────────────────
setup_case fromcfg
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "codex", "model": "gpt-x-mini" }
JSON
run_dispatch read "understand" >/dev/null 2>&1 || fail "config-agent run failed"
contains "$FAKE_ARGV" "--model gpt-x-mini" "model from config should reach worker argv"
pass "agent + model resolved from config file"

# Codex's neutral project config takes precedence over the legacy Claude path;
# legacy-only projects remain supported.
setup_case neutralcfg
mkdir -p "$CASE_DIR/.delegate-coder" "$CASE_DIR/.claude"
cat > "$CASE_DIR/.delegate-coder/config.json" <<'JSON'
{ "agent": "codex", "model": "neutral-model" }
JSON
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "codex", "model": "legacy-model" }
JSON
run_dispatch read "understand" >/dev/null 2>&1 || fail "neutral config run failed"
contains "$FAKE_ARGV" "--model neutral-model" "neutral config should take precedence"
absent "$FAKE_ARGV" "legacy-model" "legacy config must not override neutral config"
pass "neutral config takes precedence over legacy Claude config"

# Config is resolved from git root even when invoked from a nested subdirectory.
setup_case nestedcwd_config
mkdir -p "$CASE_DIR/.delegate-coder" "$CASE_DIR/nested/dir"
cat > "$CASE_DIR/.delegate-coder/config.json" <<'JSON'
{ "agent": "codex", "model": "rootcfg-model" }
JSON
(
  cd "$CASE_DIR/nested/dir" || exit 1
  HOME="$TEST_ROOT/home" \
  PATH="$CASE_DIR/bin:$TEST_PATH" \
  DELEGATE_PATH_EXTRA="$CASE_DIR/bin" \
  bash "$DISPATCH" read "understand" >/dev/null 2>&1
) || fail "nested-cwd config run failed"
contains "$FAKE_ARGV" "--model rootcfg-model" "config from git root should reach worker argv when invoked from nested subdir"
pass "config resolved from git root when CWD is nested subdir"

# The optional implementation backend preserves the normal agent default and
# refuses non-contract input without silently falling back to a hosted worker.
setup_case backenddefault
DELEGATE_AGENT=codex run_dispatch exec "ordinary implementation task" >/dev/null 2>&1 || fail "default backend should preserve exec"
contains "$FAKE_ARGV" "workspace-write" "default implementation backend should use agent exec"
pass "default implementation backend preserves agent exec"

setup_case backendcontract
mkdir -p "$CASE_DIR/.claude"
printf '%s\n' '{"implementation_backend":"contract"}' > "$CASE_DIR/.claude/delegate-coder.json"
run_dispatch exec "ordinary implementation task" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 2 ]] || fail "contract backend should reject non-contract input without fallback"
contains "$CASE_DIR/err" "no hosted-agent fallback" "contract backend fallback policy"
[[ ! -s "$FAKE_ARGV" ]] || fail "contract backend must not invoke the agent adapter"
pass "contract backend is explicit and no-fallback"

# ── delegate.sh: command_override bypasses adapter ────────────────────────
setup_case override
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "codex", "command_override": { "read": "echo OVERRIDE_RAN {task}" } }
JSON
out="$(run_dispatch read "hello-spec" 2>/dev/null)"
grep -Fq "OVERRIDE_RAN hello-spec" <<<"$out" || fail "override should run with {task} substituted"
[[ -s "$FAKE_ARGV" ]] && fail "override should bypass the built-in adapter"
pass "command_override runs with {task} and bypasses adapter"

# ── delegate.sh: fallback strict vs graceful when agent missing ───────────
setup_case strict
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "delegate_coder_missing_agent_9fd0d3", "fallback": "strict" }
JSON
run_dispatch exec "do it" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 4 ]] || fail "missing agent should exit 4 (got $rc)"
contains "$CASE_DIR/err" "CRITICAL" "strict fallback should warn CRITICAL"
pass "missing agent + strict exits 4 with CRITICAL"

setup_case graceful
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "delegate_coder_missing_agent_9fd0d3", "fallback": "graceful" }
JSON
run_dispatch exec "do it" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 4 ]] || fail "missing agent graceful should exit 4 (got $rc)"
absent "$CASE_DIR/err" "CRITICAL" "graceful fallback must not print CRITICAL"
pass "missing agent + graceful exits 4 without CRITICAL"

# ── delegate.sh: allow_paths enforcement ──────────────────────────────────
setup_case allowbad
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "codex", "allow_paths": ["lib/"] }
JSON
FAKE_TOUCH="$CASE_DIR/src/other.txt" DELEGATE_AGENT=codex run_dispatch exec "edit" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 6 ]] || fail "out-of-scope change should exit 6 (got $rc)"
contains "$CASE_DIR/err" "outside allow_paths" "should warn about allow_paths violation"
pass "exec change outside allow_paths exits 6"

setup_case allowok
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "codex", "allow_paths": ["lib/"] }
JSON
FAKE_TOUCH="$CASE_DIR/lib/keep.txt" DELEGATE_AGENT=codex run_dispatch exec "edit" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || fail "in-scope change should exit 0 (got $rc)"
pass "exec change inside allow_paths exits 0"

# ── delegate.sh: audit log ────────────────────────────────────────────────
setup_case audit
DELEGATE_AGENT=codex run_dispatch read "understand" >/dev/null 2>&1 || fail "audit run failed"
LOG="$CASE_DIR/.claude/delegate-coder.log"
[[ -f "$LOG" ]] || fail "audit log should be created"
contains "$LOG" '"event":"start"' "audit log should record start"
contains "$LOG" '"event":"end"' "audit log should record end"
contains "$LOG" '"agent":"codex"' "audit log should record agent"
jq -e 'select(.event=="end") | .exit_code == 0' "$LOG" >/dev/null 2>&1 || fail "end event should carry exit_code"
pass "audit log records start/end with agent and exit_code"

# ── detect-test.sh: per-ecosystem inference ───────────────────────────────
dt() { ( cd "$1" && bash "$DETECT_TEST" ); }
mk() { mkdir -p "$TEST_ROOT/$1"; echo "$TEST_ROOT/$1"; }

d="$(mk dt_npm)";   printf '{ "scripts": { "test": "jest" } }\n' > "$d/package.json"
[[ "$(dt "$d")" == "npm test" ]] || fail "npm real test script -> npm test"
pass "detect-test: npm real script"

d="$(mk dt_npm_ph)"; printf '{ "scripts": { "test": "echo \\"Error: no test specified\\" && exit 1" } }\n' > "$d/package.json"
[[ -z "$(dt "$d")" ]] || fail "npm placeholder should not resolve to npm test"
pass "detect-test: npm placeholder ignored"

d="$(mk dt_py)";    : > "$d/pytest.ini"
# Phase 1: Smart Test Verification (pytest or unittest fallback).
# Resolve the interpreter detect-test.sh would use (same lookup order: venv → python → python3).
_py_interp=""
if [[ -x "$d/.venv/bin/python" ]]; then _py_interp="$d/.venv/bin/python"
elif [[ -x "$d/venv/bin/python" ]]; then _py_interp="$d/venv/bin/python"
elif command -v python >/dev/null 2>&1; then _py_interp="python"
elif command -v python3 >/dev/null 2>&1; then _py_interp="python3"
fi
if [[ -n "$_py_interp" ]]; then
  _quoted_py="$(printf '%q' "$_py_interp")"
  # Gate on importability, matching the implementation (not command -v pytest).
  if "$_py_interp" -c "import pytest" >/dev/null 2>&1; then
    [[ "$(dt "$d")" == "$_quoted_py -m pytest -q" ]] || fail "pytest.ini -> pytest (interpreter: $_quoted_py)"
  else
    [[ "$(dt "$d")" == "$_quoted_py -m unittest discover" ]] || fail "pytest.ini -> unittest fallback (interpreter: $_quoted_py)"
  fi
fi
pass "detect-test: pytest"

d="$(mk dt_go)";    : > "$d/go.mod"
[[ "$(dt "$d")" == "go test ./..." ]] || fail "go.mod -> go test"
pass "detect-test: go"

d="$(mk dt_rust)";  : > "$d/Cargo.toml"
[[ "$(dt "$d")" == "cargo test" ]] || fail "Cargo.toml -> cargo test"
pass "detect-test: rust"

d="$(mk dt_make)";  printf 'test:\n\techo hi\n' > "$d/Makefile"
[[ "$(dt "$d")" == "make test" ]] || fail "Makefile test: -> make test"
pass "detect-test: make"

d="$(mk dt_none)"
[[ -z "$(dt "$d")" ]] || fail "no markers -> empty"
pass "detect-test: nothing recognized"

# ── doctor.sh: command_override checks ─────────────────────────────────────
DOCTOR="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/doctor.sh"

setup_case docok
mkdir -p "$CASE_DIR/.delegate-coder"
cat > "$CASE_DIR/.delegate-coder/config.json" <<JSON
{
  "agent": "custom",
  "command_override": {
    "read": "$CASE_DIR/bin/codex {task}"
  }
}
JSON
(
  cd "$CASE_DIR" || exit 1
  HOME="$TEST_ROOT/home" \
  PATH="$CASE_DIR/bin:$TEST_PATH" \
  DELEGATE_PATH_EXTRA="$CASE_DIR/bin" \
  bash "$DOCTOR" >/dev/null 2>&1
) || fail "doctor override should report ready when command exists"
pass "doctor.sh command_override (valid executable) is ready"

setup_case docbad
mkdir -p "$CASE_DIR/.delegate-coder"
cat > "$CASE_DIR/.delegate-coder/config.json" <<JSON
{
  "agent": "custom",
  "command_override": {
    "read": "nonexistent-cmd-name-9fd0d3 {task}"
  }
}
JSON
(
  cd "$CASE_DIR" || exit 1
  HOME="$TEST_ROOT/home" \
  PATH="$CASE_DIR/bin:$TEST_PATH" \
  DELEGATE_PATH_EXTRA="$CASE_DIR/bin" \
  bash "$DOCTOR" >/dev/null 2>&1
) && fail "doctor override should report not ready when command is missing"
pass "doctor.sh command_override (missing executable) is not ready"

# ── delegate.sh: command_override duration log ─────────────────────────────
setup_case override_duration
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<JSON
{
  "agent": "custom",
  "command_override": {
    "read": "sleep 1 && echo OVERRIDE_RAN {task}"
  }
}
JSON
run_dispatch read "duration-test" >/dev/null 2>&1 || fail "duration run failed"
LOG="$CASE_DIR/.claude/delegate-coder.log"
[[ -f "$LOG" ]] || fail "audit log should be created for override"
duration="$(jq -e 'select(.event=="end") | .duration_s' "$LOG" 2>/dev/null || grep -o '"duration_s"[[:space:]]*:[[:space:]]*[0-9]*' "$LOG" | sed 's/.*:[[:space:]]*//')"
[[ "$duration" -ge 1 ]] || fail "duration_s should be >= 1 for sleep 1 (got $duration)"
pass "command_override duration_s log is accurate"

# ── detect-test.sh: Python loose root tests fallback ───────────────────────
d="$(mk dt_loose_test)"
: > "$d/test_calculator.py"
_py_interp=""
if [[ -x "$d/.venv/bin/python" ]]; then _py_interp="$d/.venv/bin/python"
elif [[ -x "$d/venv/bin/python" ]]; then _py_interp="$d/venv/bin/python"
elif command -v python >/dev/null 2>&1; then _py_interp="python"
elif command -v python3 >/dev/null 2>&1; then _py_interp="python3"
fi
if [[ -n "$_py_interp" ]]; then
  _quoted_py="$(printf '%q' "$_py_interp")"
  if "$_py_interp" -c "import pytest" >/dev/null 2>&1; then
    [[ "$(dt "$d")" == "$_quoted_py -m pytest -q" ]] || fail "loose test_*.py -> pytest"
  else
    [[ "$(dt "$d")" == "$_quoted_py -m unittest discover" ]] || fail "loose test_*.py -> unittest fallback"
  fi
fi
pass "detect-test: loose test_*.py at root"

d="$(mk dt_loose_test_empty)"
[[ -z "$(dt "$d")" ]] || fail "empty loose test dir -> empty"
pass "detect-test: loose test empty dir remains empty"

# ── delegate.sh: command_override quote safety and injection prevention ────
setup_case override_quotes
mkdir -p "$CASE_DIR/.claude"
mkdir -p "$CASE_DIR/bin"

# Write a fake worker script that records its arguments byte-for-byte
cat > "$CASE_DIR/bin/fake_worker.sh" <<EOF
#!/usr/bin/env bash
printf "%s" "\$1" > "$CASE_DIR/worker_arg1"
EOF
chmod +x "$CASE_DIR/bin/fake_worker.sh"

# Write config specifying the command_override pointing to the fake worker
cat > "$CASE_DIR/.claude/delegate-coder.json" <<JSON
{
  "agent": "custom",
  "command_override": {
    "read": "fake_worker.sh {task}"
  }
}
JSON

# Run dispatch with a task containing quotes, apostrophe, \$(touch pwned), backticks
injection_task="task's \"quotes\" \$(touch pwned) \`touch pwned_backtick\`"
run_dispatch read "$injection_task" >/dev/null 2>&1 || fail "injection test run failed"

# Verify that:
# 1. No command execution side effects occurred
[[ ! -f "$CASE_DIR/pwned" ]] || fail "injection occurred: file pwned created"
[[ ! -f "$CASE_DIR/pwned_backtick" ]] || fail "injection occurred: file pwned_backtick created"
# 2. The argument reached the worker exactly byte-identical
[[ -f "$CASE_DIR/worker_arg1" ]] || fail "worker did not receive argument"
arg_received="$(cat "$CASE_DIR/worker_arg1")"
[[ "$arg_received" == "$injection_task" ]] || fail "argument corrupted: expected '$injection_task' but got '$arg_received'"
pass "command_override handles quotes and prevents injections safely"

# ── delegate.sh: command_override back-compat for legacy quoted placeholders ──
setup_case override_quoted_legacy_sq
mkdir -p "$CASE_DIR/.claude"
mkdir -p "$CASE_DIR/bin"

# Write a fake worker script that records its arguments byte-for-byte
cat > "$CASE_DIR/bin/fake_worker.sh" <<EOF
#!/usr/bin/env bash
printf "%s" "\$1" > "$CASE_DIR/worker_arg1"
EOF
chmod +x "$CASE_DIR/bin/fake_worker.sh"

# Write legacy config specifying command_override with '{task}' (single-quoted)
cat > "$CASE_DIR/.claude/delegate-coder.json" <<JSON
{
  "agent": "custom",
  "command_override": {
    "read": "fake_worker.sh '{task}'"
  }
}
JSON

legacy_task="legacy single quoted task's content"
run_dispatch read "$legacy_task" >/dev/null 2>&1 || fail "legacy single quoted run failed"

[[ -f "$CASE_DIR/worker_arg1" ]] || fail "legacy worker did not receive argument"
arg_received="$(cat "$CASE_DIR/worker_arg1")"
[[ "$arg_received" == "$legacy_task" ]] || fail "legacy single-quoted output corrupted: expected '$legacy_task' but got '$arg_received'"
pass "command_override handles legacy single-quoted '{task}' correctly"

setup_case override_quoted_legacy_dq
mkdir -p "$CASE_DIR/.claude"
mkdir -p "$CASE_DIR/bin"

# Write a fake worker script that records its arguments byte-for-byte
cat > "$CASE_DIR/bin/fake_worker.sh" <<EOF
#!/usr/bin/env bash
printf "%s" "\$1" > "$CASE_DIR/worker_arg1"
EOF
chmod +x "$CASE_DIR/bin/fake_worker.sh"

# Write legacy config specifying command_override with "{task}" (double-quoted)
cat > "$CASE_DIR/.claude/delegate-coder.json" <<JSON
{
  "agent": "custom",
  "command_override": {
    "read": "fake_worker.sh \"{task}\""
  }
}
JSON

legacy_task="legacy double quoted task's content"
run_dispatch read "$legacy_task" >/dev/null 2>&1 || fail "legacy double quoted run failed"

[[ -f "$CASE_DIR/worker_arg1" ]] || fail "legacy worker did not receive argument"
arg_received="$(cat "$CASE_DIR/worker_arg1")"
[[ "$arg_received" == "$legacy_task" ]] || fail "legacy double-quoted output corrupted: expected '$legacy_task' but got '$arg_received'"
pass "command_override handles legacy double-quoted \"{task}\" correctly"

echo "# all $PASS checks passed"
