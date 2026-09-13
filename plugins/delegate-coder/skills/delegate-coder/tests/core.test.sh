#!/usr/bin/env bash
# core.test.sh — deterministic tests for the foundational orchestration scripts
# (delegate.sh dispatch/adapters/fallback/allow_paths/audit, detect-test.sh).
# Uses a fake worker on PATH and temp fixtures; no real agent, network, or model.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
DISPATCH="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh"
DETECT_TEST="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/detect-test.sh"
STATS="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/stats.sh"
REPORT="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/report.sh"
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
contains "$LOG" '"agent":"codex"' "audit log should record agent"
jq -se 'any(.[]; .event=="end" and .exit_code == 0)' "$LOG" >/dev/null 2>&1 || fail "end event should carry exit_code"
jq -se 'any(.[]; .event=="start" and .run_id != null and .task_id != null and .attempt == 1 and .parent_run_id == null)' "$LOG" >/dev/null 2>&1 || fail "start event should carry correlation fields"
jq -se 'any(.[]; .event=="end" and .run_id != null and .task_id != null and .attempt == 1 and .status == "PASS")' "$LOG" >/dev/null 2>&1 || fail "end event should carry correlation fields and status PASS"
jq -se 'any(.[]; .event=="start" and .repo == "audit" and .git_root != null and .branch != null and .target_files == [] and .changed_file_count == 0)' "$LOG" >/dev/null 2>&1 || fail "start event should carry context metadata"
jq -se 'any(.[]; .event=="end" and .repo == "audit" and .git_root != null and .branch != null and .target_files == [] and .changed_file_count == 0 and .test_command == null and .commit_sha == null)' "$LOG" >/dev/null 2>&1 || fail "end event should carry context metadata"
pass "audit log records start/end with agent, exit_code, correlation, and context metadata"

# ── delegate.sh: explicit DELEGATE_TASK_ID propagation ───────────────────
setup_case audit_task_id
CUSTOM_TASK_ID="12345678-1234-5678-1234-567812345678"
DELEGATE_AGENT=codex DELEGATE_TASK_ID="$CUSTOM_TASK_ID" run_dispatch read "understand" >/dev/null 2>&1 || fail "audit with task_id run failed"
LOG="$CASE_DIR/.claude/delegate-coder.log"
jq -se --arg tid "$CUSTOM_TASK_ID" 'any(.[]; .event=="start" and .task_id == $tid)' "$LOG" >/dev/null 2>&1 || fail "start event should preserve DELEGATE_TASK_ID"
jq -se --arg tid "$CUSTOM_TASK_ID" 'any(.[]; .event=="end" and .task_id == $tid)' "$LOG" >/dev/null 2>&1 || fail "end event should preserve DELEGATE_TASK_ID"
pass "audit log preserves explicit DELEGATE_TASK_ID"

# ── delegate.sh: missing agent logs WORKER_START_FAIL ─────────────────────
setup_case missing_agent_audit
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "delegate_coder_missing_agent_9fd0d3", "fallback": "graceful" }
JSON
run_dispatch exec "do it" >/dev/null 2>&1 || true
LOG="$CASE_DIR/.claude/delegate-coder.log"
jq -se 'any(.[]; .event=="end" and .status == "WORKER_START_FAIL" and .exit_code == 4 and (.error | contains("not found")) and (.hint | contains("Install")))' "$LOG" >/dev/null 2>&1 || fail "missing agent should log WORKER_START_FAIL with exit 4, error and hint"
pass "missing agent logs start and end with WORKER_START_FAIL"

# ── delegate.sh: adaptive fallback to fallback_agent ─────────────────────
setup_case adaptive_fallback_agent
mkdir -p "$CASE_DIR/.delegate-coder"
cat > "$CASE_DIR/.delegate-coder/config.json" <<'JSON'
{
  "agent": "delegate_coder_missing_agent_9fd0d3",
  "fallback": "graceful",
  "fallback_agent": "codex"
}
JSON
run_dispatch exec "adaptive task" >/dev/null 2>&1 || fail "adaptive fallback should succeed with codex"
LOG="$CASE_DIR/.claude/delegate-coder.log"
jq -se 'any(.[]; .attempt==1 and .event=="end" and .status == "WORKER_START_FAIL" and .agent == "delegate_coder_missing_agent_9fd0d3" and (.hint | contains("Adaptively falling back to candidate '\''codex'\''")))' "$LOG" >/dev/null 2>&1 || fail "attempt 1 should record WORKER_START_FAIL with fallback hint"
jq -se 'any(.[]; .attempt==2 and .event=="end" and .status == "PASS" and .agent == "codex" and .exit_code == 0)' "$LOG" >/dev/null 2>&1 || fail "attempt 2 should record PASS with codex"
# Check correlation and event structure: exactly one start and end per attempt
python3 - "$LOG" <<'PY' || fail "correlation or start/end event count mismatch across adaptive fallback attempts"
import json, pathlib, sys
records = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().strip().splitlines()]
att1_starts = [r for r in records if r["event"] == "start" and r["attempt"] == 1]
att1_ends = [r for r in records if r["event"] == "end" and r["attempt"] == 1]
att2_starts = [r for r in records if r["event"] == "start" and r["attempt"] == 2]
att2_ends = [r for r in records if r["event"] == "end" and r["attempt"] == 2]
assert len(att1_starts) == 1, f"expected exactly 1 start for attempt 1, got {len(att1_starts)}"
assert len(att1_ends) == 1, f"expected exactly 1 end for attempt 1, got {len(att1_ends)}"
assert len(att2_starts) == 1, f"expected exactly 1 start for attempt 2, got {len(att2_starts)}"
assert len(att2_ends) == 1, f"expected exactly 1 end for attempt 2, got {len(att2_ends)}"
end1 = att1_ends[0]
start2 = att2_starts[0]
end2 = att2_ends[0]
assert end1["task_id"] == start2["task_id"] == end2["task_id"], "task_id should be identical"
assert start2["parent_run_id"] == end1["run_id"], "attempt 2 parent_run_id should equal attempt 1 run_id"
assert end2["parent_run_id"] == end1["run_id"], "attempt 2 end parent_run_id should equal attempt 1 run_id"
PY
pass "adaptive fallback routes to fallback_agent with correlated audit trail and exact 1 start+end per attempt"

# ── delegate.sh: adaptive fallback re-resolves / clears MODEL ──────────────
setup_case adaptive_fallback_model_reresolution
mkdir -p "$CASE_DIR/.delegate-coder"
cat > "$CASE_DIR/.delegate-coder/config.json" <<'JSON'
{
  "agent": "delegate_coder_missing_qwen",
  "model": "special-qwen-model-X",
  "fallback": "graceful",
  "fallback_agent": "codex"
}
JSON
run_dispatch exec "test model reresolution" >/dev/null 2>&1 || fail "adaptive fallback should succeed with codex"
LOG="$CASE_DIR/.claude/delegate-coder.log"
# Attempt 1 should carry primary model "special-qwen-model-X"
jq -se 'any(.[]; .attempt==1 and .model == "special-qwen-model-X")' "$LOG" >/dev/null 2>&1 || fail "attempt 1 should carry primary model"
# Attempt 2 should NOT carry primary model "special-qwen-model-X"
jq -se 'any(.[]; .attempt==2 and .model == "special-qwen-model-X")' "$LOG" >/dev/null 2>&1 && fail "attempt 2 codex should NOT have primary model X"
# Codex fake worker should NOT have been invoked with --model special-qwen-model-X
[[ -s "$CASE_DIR/argv.log" ]] || fail "codex should have been invoked"
grep -Fq "special-qwen-model-X" "$CASE_DIR/argv.log" && fail "codex should not receive primary's model X in arguments"
pass "adaptive fallback clears/re-resolves primary model for fallback agent"

# ── delegate.sh: adaptive fallback through fallback_chain ─────────────────
setup_case adaptive_fallback_chain
mkdir -p "$CASE_DIR/.delegate-coder"
cat > "$CASE_DIR/.delegate-coder/config.json" <<'JSON'
{
  "agent": "missing_agent_1",
  "fallback": "graceful",
  "fallback_chain": ["missing_agent_2", "codex", "missing_agent_3"]
}
JSON
run_dispatch exec "chain task" >/dev/null 2>&1 || fail "adaptive chain fallback should succeed with codex"
LOG="$CASE_DIR/.claude/delegate-coder.log"
jq -se 'any(.[]; .attempt==2 and .event=="end" and .status == "PASS" and .agent == "codex")' "$LOG" >/dev/null 2>&1 || fail "chain attempt 2 should record PASS with codex"
pass "adaptive fallback routes through fallback_chain to first available candidate"

# ── delegate.sh: strict fallback ignores fallback_agent ───────────────────
setup_case strict_ignores_fallback
mkdir -p "$CASE_DIR/.delegate-coder"
cat > "$CASE_DIR/.delegate-coder/config.json" <<'JSON'
{
  "agent": "delegate_coder_missing_agent_9fd0d3",
  "fallback": "strict",
  "fallback_agent": "codex"
}
JSON
run_dispatch exec "strict task" >/dev/null 2>"$CASE_DIR/err"; rc=$?
[[ $rc -eq 4 ]] || fail "strict with fallback_agent should still exit 4 (got $rc)"
contains "$CASE_DIR/err" "CRITICAL" "strict fallback must print CRITICAL"
pass "strict fallback policy ignores fallback_agent and preserves CRITICAL exit 4"

# ── delegate.sh: allow_paths violation logs DEPENDENCY_GUARD_FAIL ─────────
setup_case allow_paths_audit
mkdir -p "$CASE_DIR/.claude"
cat > "$CASE_DIR/.claude/delegate-coder.json" <<'JSON'
{ "agent": "codex", "allow_paths": ["lib/"] }
JSON
FAKE_TOUCH="$CASE_DIR/src/other.txt" DELEGATE_AGENT=codex run_dispatch exec "edit" >/dev/null 2>&1 || true
LOG="$CASE_DIR/.claude/delegate-coder.log"
jq -se 'any(.[]; .event=="end" and .exit_code == 6 and .status == "DEPENDENCY_GUARD_FAIL" and (.error | contains("allow_paths")) and (.hint | contains("Add")))' "$LOG" >/dev/null 2>&1 || fail "allow_paths failure should log DEPENDENCY_GUARD_FAIL with exit 6, error and hint"
[[ "$(jq -s '[.[] | select(.event=="end")] | length' "$LOG")" -eq 1 ]] || fail "expected exactly one end event per run"
pass "allow_paths violation logs DEPENDENCY_GUARD_FAIL"

# ── validate_dependency_manifest.py unit tests ────────────────────────────
python3 - <<'PY' || fail "validate_dependency_manifest unit tests failed"
import sys
from pathlib import Path
repo_root = Path.cwd()
sys.path.insert(0, str(repo_root / "plugins/delegate-coder/skills/delegate-coder/scripts/lib"))
from validate_dependency_manifest import _parse, check

# 1. Unvalidatable / legitimate forms should return None
for legit in ["^1", "1.2", "1.x", "1.2.x", "~2", "workspace:*", "^1.2.3", "1.*", "1.2.*", "x", "*"]:
    res = _parse(legit)
    if legit == "^1.2.3":
        assert res == (1, 2, 3), f"^1.2.3 expected (1, 2, 3), got {res}"
    else:
        assert res is None, f"{legit} expected None (skip), got {res}"

# 2. Invalid non-version forms should return "invalid"
for bad in ["abc", "", "   ", "not-a-version"]:
    assert _parse(bad) == "invalid", f"{bad} expected invalid, got {_parse(bad)}"

# 3. Check full manifest checks:
# 3a. Legitimate forms PASS
orig = '{"dependencies": {"p1": "1.0.0", "p2": "1.0.0", "p3": "1.0.0", "p4": "1.0.0", "p5": "1.0.0", "p6": "1.0.0", "p7": "1.0.0"}}'
cand = '{"dependencies": {"p1": "^1", "p2": "1.2", "p3": "1.x", "p4": "1.2.x", "p5": "~2", "p6": "workspace:*", "p7": "^1.2.3"}}'
check("package.json", orig, cand, label="test")

# 3b. Real downgrade FAILS
cand_downgrade = '{"dependencies": {"pkg": "^1.0.0"}}'
orig_downgrade = '{"dependencies": {"pkg": "^2.0.0"}}'
try:
    check("package.json", orig_downgrade, cand_downgrade, label="test")
    assert False, "expected downgrade to fail"
except SystemExit:
    pass

# 3c. Downgrade with allow_downgrade PASSES
check("package.json", orig_downgrade, cand_downgrade, allow_downgrade=["pkg"], label="test")
check("package.json", orig_downgrade, cand_downgrade, allow_downgrade=True, label="test")

# 3d. Non-version garbage "abc" FAILS
cand_garbage = '{"dependencies": {"pkg": "abc"}}'
try:
    check("package.json", orig_downgrade, cand_garbage, label="test")
    assert False, "expected abc to fail"
except SystemExit:
    pass

PY
pass "validate_dependency_manifest: legitimate forms, downgrades, allow_downgrade, and invalid values"

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

# ── stats.sh: single log, multi-log fleet, --json export, and token stats ───
setup_case stats_fleet_test
LOG1="$CASE_DIR/.claude/delegate-coder.log"
mkdir -p "$CASE_DIR/.claude"
cat > "$LOG1" <<'JSONL'
{"event":"start","agent":"codex","model":"gpt-4","mode":"exec","run_id":"r1","task_id":"t1","attempt":1,"ts":"2026-09-12T00:00:00Z"}
{"event":"end","agent":"codex","model":"gpt-4","mode":"exec","run_id":"r1","task_id":"t1","attempt":1,"duration_s":10,"exit_code":0,"status":"PASS","ts":"2026-09-12T00:00:10Z"}
{"event":"start","agent":"local-ollama","model":"qwen3-coder:30b","mode":"contract","run_id":"r2","task_id":"t2","attempt":1,"ts":"2026-09-12T00:01:00Z"}
{"event":"end","agent":"local-ollama","model":"qwen3-coder:30b","mode":"contract","run_id":"r2","task_id":"t2","attempt":1,"duration_s":5,"exit_code":1,"status":"PREFLIGHT_FAIL","prompt_eval_count":100,"eval_count":50,"ts":"2026-09-12T00:01:05Z"}
{"event":"start","agent":"local-ollama","model":"qwen3-coder:30b","mode":"contract","run_id":"r3","task_id":"t2","attempt":2,"parent_run_id":"r2","ts":"2026-09-12T00:01:10Z"}
{"event":"end","agent":"local-ollama","model":"qwen3-coder:30b","mode":"contract","run_id":"r3","task_id":"t2","attempt":2,"duration_s":15,"exit_code":0,"status":"PASS","prompt_eval_count":150,"eval_count":80,"ts":"2026-09-12T00:01:25Z"}
JSONL

# Test 1: Single file default stats
out1="$(bash "$STATS" "$LOG1")"
contains_str() { grep -Fq -- "$2" <<< "$1" || fail "$3"; }
contains_str "$out1" "Total delegations:  3" "stats.sh single file total delegations"
contains_str "$out1" "Completions logged: 3" "stats.sh single file completions"
contains_str "$out1" "Logical tasks:      2 (Attempts: 3)" "stats.sh logical tasks count"
contains_str "$out1" "Pass rate:          66.7%" "stats.sh pass rate"
contains_str "$out1" "PREFLIGHT_FAIL" "stats.sh status breakdown"
contains_str "$out1" "Prompt tokens:     250" "stats.sh prompt token sum"
pass "stats.sh single file summary with tasks, status breakdown, and tokens"

# Test 2: JSON export mode
out_json="$(bash "$STATS" --json "$LOG1")"
python3 - "$out_json" <<'PY' || fail "stats.sh --json schema mismatch"
import json, sys
data = json.loads(sys.argv[1])
assert data["total_delegations"] == 3
assert data["completions_logged"] == 3
assert data["logical_tasks"] == 2
assert data["execution_attempts"] == 3
assert data["pass_count"] == 2
assert data["fail_count"] == 1
assert data["pass_rate_pct"] == 66.7
assert data["tokens"]["total_prompt_tokens"] == 250
assert data["tokens"]["total_completion_tokens"] == 130
assert data["status_breakdown"].get("PREFLIGHT_FAIL") == 1
assert data["status_breakdown"].get("PASS") == 2
assert len(data["breakdown"]) == 2
PY
pass "stats.sh --json valid schema and metrics"

# Test 3: Multi-file fleet aggregation
LOG2="$CASE_DIR/other_repo.log"
cat > "$LOG2" <<'JSONL'
{"event":"start","agent":"mimo","model":"mimo-v1","mode":"exec","run_id":"r4","task_id":"t3","attempt":1,"ts":"2026-09-12T00:02:00Z"}
{"event":"end","agent":"mimo","model":"mimo-v1","mode":"exec","run_id":"r4","task_id":"t3","attempt":1,"duration_s":20,"exit_code":0,"status":"PASS","ts":"2026-09-12T00:02:20Z"}
JSONL
out_fleet_json="$(bash "$STATS" --json "$LOG1" "$LOG2")"
python3 - "$out_fleet_json" <<'PY' || fail "stats.sh multi-file fleet aggregation failed"
import json, sys
data = json.loads(sys.argv[1])
assert len(data["files"]) == 2
assert data["total_delegations"] == 4
assert data["completions_logged"] == 4
assert data["logical_tasks"] == 3
assert data["execution_attempts"] == 4
assert data["pass_count"] == 3
assert data["fail_count"] == 1
assert data["pass_rate_pct"] == 75.0
PY
pass "stats.sh multi-file fleet aggregation"

# Test 4: Missing log files handled gracefully
out_empty="$(bash "$STATS" "$CASE_DIR/nonexistent.log")"
contains_str "$out_empty" "No audit log found" "stats.sh missing log output"
pass "stats.sh missing log handled gracefully"

# Test 5: stats.sh --since filtering
out_since_recent="$(bash "$STATS" --json --since 1h "$LOG1")"
python3 - "$out_since_recent" <<'PY' || fail "stats.sh --since 1h should filter out old entries"
import json, sys
data = json.loads(sys.argv[1])
assert data["total_delegations"] == 0
assert data["completions_logged"] == 0
PY
pass "stats.sh --since filters records outside cutoff"

# Test 6: report.sh execution and --json structure
out_report="$(bash "$REPORT" --json "$LOG1")"
python3 - "$out_report" <<'PY' || fail "report.sh --json structure mismatch"
import json, sys
data = json.loads(sys.argv[1])
assert data["total_tasks"] == 2
assert data["total_runs"] == 3
assert data["completed_runs"] == 3
assert "codex" in data["workers"]
assert "local-ollama" in data["workers"]
assert data["workers"]["local-ollama"]["pass_rate_pct"] == 50.0
assert data["workers"]["local-ollama"]["status_breakdown"].get("PREFLIGHT_FAIL") == 1
PY
pass "report.sh aggregates tasks and failure breakdown"

echo "# all $PASS checks passed"
