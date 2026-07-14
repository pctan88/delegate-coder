#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
ROUTER="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/contract-router.sh"
DISPATCH="$REPO_ROOT/plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/delegate-coder-contract-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
contains() { grep -Fq -- "$2" "$1" || fail "$3"; }

setup_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p "$CASE_DIR/bin"
  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" config user.email test@example.invalid
  git -C "$CASE_DIR" config user.name test
  cat > "$CASE_DIR/.gitignore" <<'EOF'
/contract.json
/batch.json
/stdout
/stderr
/stdin.stdout
/stdin.stderr
/curl.*
/request.*
/ollama.*
/new.txt
/.claude/
EOF
  printf 'original\n' > "$CASE_DIR/target.txt"
  chmod 640 "$CASE_DIR/target.txt"
  git -C "$CASE_DIR" add .gitignore target.txt
  git -C "$CASE_DIR" commit -qm initial

  cat > "$CASE_DIR/bin/ollama" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == ps ]]; then
  cat "${OLLAMA_PS_FILE:?OLLAMA_PS_FILE is required}"
elif [[ "${1:-}" == stop ]]; then
  printf '%s\n' "${2:-}" >> "${OLLAMA_STOP_LOG:?OLLAMA_STOP_LOG is required}"
fi
SH

  cat > "$CASE_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
count_file="${CURL_COUNT_FILE:?CURL_COUNT_FILE is required}"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf '%s\n%s\n' "${DISABLE_AUTOUPDATER:-}" "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" > "${CURL_ENV_FILE:?CURL_ENV_FILE is required}"
printf '%s\n' "$@" > "${CURL_ARGS_FILE:?CURL_ARGS_FILE is required}"
request_file=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == --data-binary ]]; then
    request_file="${arg#@}"
  fi
  previous="$arg"
done
[[ -z "$request_file" ]] || cp "$request_file" "${CURL_REQUEST_PREFIX:?CURL_REQUEST_PREFIX}$count"
if [[ -n "${CURL_ORDER_FILE:-}" && -n "$request_file" ]]; then
  python3 - "$request_file" "$CURL_ORDER_FILE" <<'PY'
import json, pathlib, re, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
match = re.search(r"^Target file: ([^\n]+)", payload.get("prompt", ""), re.MULTILINE)
with pathlib.Path(sys.argv[2]).open("a") as output:
    output.write((match.group(1) if match else "unknown") + "\n")
PY
fi
mode="${CURL_MODE:-good}"
content=good
if [[ "$mode" == outside ]]; then printf 'changed\n' > outside.txt; fi
if [[ "$mode" == retry && "$count" -eq 1 ]]; then content=bad; fi
if [[ "$mode" == bad ]]; then content=bad; fi
if [[ "$mode" == batch-fail && "$count" -le 2 ]]; then content=bad; fi
if [[ "$mode" == noop ]]; then content=original; fi
if [[ "$mode" == batch-noop && "$count" -eq 2 ]]; then content=original; fi
if [[ "$mode" == nested ]]; then content=$'before\n```markdown\ninner\n```\nafter\n'; fi
if [[ "$mode" == source-fence ]]; then content=$'const fence = "```";\nconst value = `raw`;\n'; fi
done_reason=stop
if [[ "$mode" == truncated ]]; then content=partial; done_reason=length; fi
if [[ "$mode" == malformed ]]; then
  printf '{"response":"not-json","done_reason":"stop"}'
  exit 0
fi
if [[ "$mode" == empty ]]; then
  RESPONSE_MODE=empty python3 - <<'PY'
import json, os
print(json.dumps({"response": json.dumps({"updated_file": ""}), "done_reason": "stop"}))
PY
  exit 0
fi
if [[ "$mode" == additional ]]; then
  RESPONSE_MODE=additional python3 - <<'PY'
import json
print(json.dumps({"response": json.dumps({"updated_file": "good", "extra": "ambiguous"}), "done_reason": "stop"}))
PY
  exit 0
fi
CONTENT="$content" DONE_REASON="$done_reason" python3 - <<'PY'
import json, os
content = os.environ["CONTENT"]
done_reason = os.environ["DONE_REASON"]
print(json.dumps({"response": json.dumps({"updated_file": content}), "done_reason": done_reason,
                  "total_duration": 100, "load_duration": 20, "prompt_eval_count": 30,
                  "prompt_eval_duration": 40, "eval_count": 10, "eval_duration": 50}))
PY
SH
  chmod +x "$CASE_DIR/bin/ollama" "$CASE_DIR/bin/curl"
  git -C "$CASE_DIR" add bin
  git -C "$CASE_DIR" commit -qm fixtures
  printf 'NAME ID SIZE PROCESSOR UNTIL\nold-model abc 1GB 100%% 1m\nqwen3-coder:30b def 1GB 100%% 1m\n' > "$CASE_DIR/ollama.ps"
  : > "$CASE_DIR/ollama.stops"
  : > "$CASE_DIR/curl.count"
  : > "$CASE_DIR/curl.args"
  : > "$CASE_DIR/curl.order"
}

make_contract() {
  local target="$1" test_command="$2" output="$3"
  TARGET_VALUE="$target" TEST_VALUE="$test_command" python3 -c \
    'import json, os; print(json.dumps({"target_file": os.environ["TARGET_VALUE"], "instructions": "write the requested fixture", "test_command": os.environ["TEST_VALUE"]}))' > "$output"
}

run_dispatch() {
  (
    cd "$CASE_DIR" || exit 1
    PATH="$CASE_DIR/bin:$PATH" \
    OLLAMA_PS_FILE="$CASE_DIR/ollama.ps" \
    OLLAMA_STOP_LOG="$CASE_DIR/ollama.stops" \
    CURL_COUNT_FILE="$CASE_DIR/curl.count" \
    CURL_REQUEST_PREFIX="$CASE_DIR/request." \
    CURL_ENV_FILE="$CASE_DIR/curl.env" \
    CURL_ARGS_FILE="$CASE_DIR/curl.args" \
    CURL_ORDER_FILE="$CASE_DIR/curl.order" \
    OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}" \
    CURL_MODE="${CURL_MODE:-good}" \
    DELEGATE_MODEL="${DELEGATE_MODEL:-qwen3-coder:30b}" \
    DELEGATE_NUM_CTX="${DELEGATE_NUM_CTX:-32768}" \
    DELEGATE_KEEP_ALIVE="${DELEGATE_KEEP_ALIVE:-30m}" \
    DELEGATE_TEST_TIMEOUT="${DELEGATE_TEST_TIMEOUT:-300}" \
    bash "$DISPATCH" contract "$1" > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  )
}

# Valid JSON, GPU cleanup, fenced extraction, mode preservation, newline sweep,
# and a clean stdout report.
setup_case valid
make_contract target.txt "grep -q '^good$' target.txt" "$CASE_DIR/contract.json"
if ! run_dispatch "$(cat "$CASE_DIR/contract.json")"; then fail "valid contract should pass"; fi
contains "$CASE_DIR/stdout" '- Status: PASS' "successful report status"
contains "$CASE_DIR/stdout" '## Git diff' "successful report diff heading"
[[ "$(cat "$CASE_DIR/ollama.stops")" == old-model ]] || fail "only non-target Ollama model should be stopped"
[[ "$(cat "$CASE_DIR/curl.env")" == $'1\n1' ]] || fail "headless environment variables should be exported"
contains "$CASE_DIR/request.1" '"model": "qwen3-coder:30b"' "configured model should reach Ollama"
contains "$CASE_DIR/request.1" '"num_ctx": 32768' "context limit should reach Ollama"
contains "$CASE_DIR/request.1" '"keep_alive": "30m"' "keep-alive should reach Ollama"
python3 - "$CASE_DIR/target.txt" <<'PY' || fail "generated file should have exactly one trailing newline"
import pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
assert data.endswith(b"\n") and not data.endswith(b"\n\n")
PY
[[ "$(stat -f '%Lp' "$CASE_DIR/target.txt" 2>/dev/null || stat -c '%a' "$CASE_DIR/target.txt")" == 640 ]] || fail "target mode should be preserved"
! grep -Fq 'contract-router:' "$CASE_DIR/stdout" || fail "progress must not pollute stdout"
pass "valid JSON contract and clean report"
VALID_DIR="$CASE_DIR"

# Structured output preserves markdown fences and source strings containing
# fences without relying on the first fenced block.
setup_case nested
make_contract target.txt "grep -q '^after$' target.txt" "$CASE_DIR/contract.json"
CURL_MODE=nested run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "nested markdown contract should pass"
printf 'before\n```markdown\ninner\n```\nafter\n' | cmp -s - "$CASE_DIR/target.txt" || fail "nested fences should be preserved exactly"
pass "nested markdown fences"

setup_case sourcefence
make_contract target.txt "grep -q 'const fence' target.txt" "$CASE_DIR/contract.json"
CURL_MODE=source-fence run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "source fence contract should pass"
printf 'const fence = "```";\nconst value = `raw`;\n' | cmp -s - "$CASE_DIR/target.txt" || fail "source fences should be preserved exactly"
pass "source triple-backtick text"

for malformed_mode in malformed empty additional; do
  setup_case "structured-$malformed_mode"
  make_contract target.txt "true" "$CASE_DIR/contract.json"
  set +e
  CURL_MODE="$malformed_mode" run_dispatch "$(cat "$CASE_DIR/contract.json")"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$malformed_mode structured output should fail"
  [[ "$(cat "$CASE_DIR/target.txt")" == original ]] || fail "$malformed_mode output must not change target"
  [[ "$(cat "$CASE_DIR/curl.count")" == 1 ]] || fail "$malformed_mode should stop after parser rejection"
  contains "$CASE_DIR/stdout" '- Restored: false' "$malformed_mode parser failure should report no write"
done
pass "strict structured-output validation"

# The dispatcher also accepts the same contract on stdin.
setup_case stdin
make_contract target.txt "grep -q '^good$' target.txt" "$CASE_DIR/contract.json"
if ! (
  cd "$CASE_DIR" || exit 1
  PATH="$CASE_DIR/bin:$PATH" \
    OLLAMA_PS_FILE="$CASE_DIR/ollama.ps" \
    OLLAMA_STOP_LOG="$CASE_DIR/ollama.stops" \
    CURL_COUNT_FILE="$CASE_DIR/curl.count" \
    CURL_REQUEST_PREFIX="$CASE_DIR/request.stdin." \
    CURL_ENV_FILE="$CASE_DIR/curl.env.stdin" \
    CURL_ARGS_FILE="$CASE_DIR/curl.args.stdin" \
    CURL_ORDER_FILE="$CASE_DIR/curl.order.stdin" \
    CURL_MODE=good \
    bash "$DISPATCH" contract < "$CASE_DIR/contract.json" > "$CASE_DIR/stdin.stdout" 2> "$CASE_DIR/stdin.stderr"
); then
  fail "stdin contract should pass"
fi
grep -Eq -- '- Status: (PASS|NOOP)' "$CASE_DIR/stdin.stdout" || fail "stdin contract report status"
pass "stdin contract input"

# Audit events include contract status and retry count.
contains "$VALID_DIR/.claude/delegate-coder.log" '"mode":"contract"' "contract run should be audited"
contains "$VALID_DIR/.claude/delegate-coder.log" '"status":"PASS"' "audit should record contract status"
contains "$VALID_DIR/.claude/delegate-coder.log" '"retries":0' "audit should record retry count"

# Malformed JSON uses the lightweight field fallback and a failed first test
# triggers exactly one correction containing the exact failure log.
setup_case fallback
fallback_contract='wrapped text {"target_file":"target.txt","instructions":"write the requested fixture","test_command":"grep -q '\''^good$'\'' target.txt"} trailing text'
CURL_MODE=retry run_dispatch "$fallback_contract" || fail "regex fallback should pass after one retry"
[[ "$(cat "$CASE_DIR/curl.count")" == 2 ]] || fail "failed verification should cause exactly one retry"
contains "$CASE_DIR/request.2" 'bad' "retry request should include current generated file"
contains "$CASE_DIR/request.2" 'verification command failed' "retry request should include failure context"
pass "regex fallback and one self-correction"

# A passing test with unchanged output is explicitly reported as NOOP.
setup_case noop
make_contract target.txt "true" "$CASE_DIR/contract.json"
CURL_MODE=noop run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "noop contract should pass"
contains "$CASE_DIR/stdout" '- Status: NOOP' "unchanged output should be reported as NOOP"
pass "empty-diff detection"

# A second failure is returned without a third generation attempt.
setup_case failed
make_contract target.txt "grep -q '^good$' target.txt" "$CASE_DIR/contract.json"
set +e
CURL_MODE=bad run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "final failed verification should return nonzero"
[[ "$(cat "$CASE_DIR/curl.count")" == 2 ]] || fail "router must not make a third generation"
[[ "$(cat "$CASE_DIR/target.txt")" == original ]] || fail "failed verification must restore the existing target"
contains "$CASE_DIR/stdout" '- Restored: true' "failed verification should report restoration"
contains "$CASE_DIR/stdout" '- Status: FAIL' "failed report status"
pass "retry limit and failed report"

# A failed new-file contract removes the attempted file transactionally.
setup_case newfile-failed
git -C "$CASE_DIR" rm -q target.txt
git -C "$CASE_DIR" commit -qm remove-target
make_contract new.txt "false" "$CASE_DIR/contract.json"
set +e
CURL_MODE=good run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed new-file contract should return nonzero"
[[ ! -e "$CASE_DIR/new.txt" ]] || fail "failed new-file contract must remove target"
contains "$CASE_DIR/stdout" '- Restored: true' "new-file failure should report restoration"
pass "transactional new-file rollback"

# A model response cut off by the context limit is rejected before replacement.
setup_case truncated
make_contract target.txt "true" "$CASE_DIR/contract.json"
set +e
CURL_MODE=truncated run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "truncated response should fail"
[[ "$(cat "$CASE_DIR/target.txt")" == original ]] || fail "truncated response must not overwrite target"
contains "$CASE_DIR/stderr" 'done_reason=length' "truncation error should be explicit"
pass "truncation guard"

# An oversized complete input prompt is rejected before any Ollama HTTP
# request or target replacement.
setup_case promptguard
make_contract target.txt "true" "$CASE_DIR/contract.json"
set +e
DELEGATE_NUM_CTX=1 run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "oversized prompt should fail"
[[ ! -s "$CASE_DIR/curl.count" ]] || fail "oversized prompt must not call Ollama"
[[ ! -e "$CASE_DIR/request.1" ]] || fail "oversized prompt must not create a request"
[[ "$(cat "$CASE_DIR/target.txt")" == original ]] || fail "oversized prompt must not overwrite target"
contains "$CASE_DIR/stderr" 'exceeds DELEGATE_NUM_CTX' "oversized prompt error should be explicit"
pass "input prompt-size guard"

# New files are allowed when their parent directory is inside the repository.
setup_case newfile
git -C "$CASE_DIR" rm -q target.txt
git -C "$CASE_DIR" commit -qm remove-target
make_contract new.txt "grep -q '^good$' new.txt" "$CASE_DIR/contract.json"
run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "new-file contract should pass"
[[ -f "$CASE_DIR/new.txt" ]] || fail "new-file contract should create target"
contains "$CASE_DIR/stdout" '- Status: PASS' "new-file report status"
pass "new-file target support"

# A top-level array runs sequentially and returns one combined report.
setup_case batch
python3 - "$CASE_DIR/batch.json" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]).parent
contracts = []
for index in range(1, 13):
    target = f"f{index:02d}.txt"
    (root / target).write_text("original\n")
    contracts.append({"target_file": target, "instructions": "update", "test_command": f"grep -q '^good$' {target}"})
json.dump(contracts, open(sys.argv[1], "w"))
PY
git -C "$CASE_DIR" add f*.txt
git -C "$CASE_DIR" commit -qm batch-targets
CURL_MODE=good run_dispatch "$(cat "$CASE_DIR/batch.json")" || fail "contract batch should pass"
[[ "$(cat "$CASE_DIR/curl.count")" == 12 ]] || fail "batch should generate each contract once"
expected_order="$(printf 'f%02d.txt\n' {1..12})"
[[ "$(cat "$CASE_DIR/curl.order")" == "$expected_order" ]] || fail "batch must preserve exact JSON-array order"
contains "$CASE_DIR/stdout" '# Contract Batch Result' "batch report heading"
contains "$CASE_DIR/stdout" '## Contract 1' "batch report first contract"
contains "$CASE_DIR/stdout" '## Contract 12' "batch report twelfth contract"
contains "$CASE_DIR/stdout" -- '- Status: PASS' "batch should aggregate as PASS"
contains "$CASE_DIR/stdout" '- Completed: 12' "batch should report completed count"
contains "$CASE_DIR/stdout" '- Skipped: 0' "batch should report skipped count"
contains "$CASE_DIR/.claude/delegate-coder.log" '"status":"PASS"' "batch audit should use aggregate status"
pass "ordered sequential contract batch"

# A failed child stops the batch and does not request later children.
setup_case batchfail
printf 'original\n' > "$CASE_DIR/second.txt"
git -C "$CASE_DIR" add second.txt
git -C "$CASE_DIR" commit -qm second
python3 - "$CASE_DIR/batch.json" <<'PY'
import json, sys
json.dump([
    {"target_file": "target.txt", "instructions": "fail", "test_command": "grep -q '^good$' target.txt"},
    {"target_file": "second.txt", "instructions": "must not run", "test_command": "true"},
], open(sys.argv[1], "w"))
PY
set +e
CURL_MODE=batch-fail run_dispatch "$(cat "$CASE_DIR/batch.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed batch should return nonzero"
[[ "$(cat "$CASE_DIR/curl.count")" == 2 ]] || fail "failed child should retry once and skip later children"
[[ "$(cat "$CASE_DIR/target.txt")" == original ]] || fail "failed batch child should be restored"
[[ ! -s "$CASE_DIR/curl.order" || "$(cat "$CASE_DIR/curl.order")" == $'target.txt\ntarget.txt' ]] || fail "later child must never be requested"
contains "$CASE_DIR/stdout" '- Completed: 0' "failed batch completed count"
contains "$CASE_DIR/stdout" '- Failed: 1' "failed batch failed count"
contains "$CASE_DIR/stdout" '- Skipped: 1' "failed batch skipped count"
pass "stop-on-failure batch semantics"

# Verification commands are bounded and still receive the single retry.
setup_case timeout
make_contract target.txt "sleep 2" "$CASE_DIR/contract.json"
set +e
DELEGATE_TEST_TIMEOUT=1 run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "timed-out verification should fail"
[[ "$(cat "$CASE_DIR/curl.count")" == 2 ]] || fail "timed-out verification should receive one retry"
pass "verification timeout"

# Strictly positive limits are rejected before generation.
setup_case zero-context
make_contract target.txt "true" "$CASE_DIR/contract.json"
set +e
DELEGATE_NUM_CTX=0 run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "zero context must fail"
[[ ! -s "$CASE_DIR/curl.count" ]] || fail "zero context must not call Ollama"
contains "$CASE_DIR/stderr" 'strictly positive integer' "zero context error"
pass "positive integer limits"

# Loopback Ollama bypasses proxies explicitly; remote Ollama preserves proxy
# behavior by omitting the bypass flag.
setup_case loopback
make_contract target.txt "true" "$CASE_DIR/contract.json"
OLLAMA_HOST=http://localhost:11434 run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "loopback host should pass"
grep -Fxq -- '--noproxy' "$CASE_DIR/curl.args" || fail "loopback request should force proxy bypass"
setup_case remote
make_contract target.txt "true" "$CASE_DIR/contract.json"
OLLAMA_HOST=http://remote.example:11434 run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "remote host fixture should pass"
! grep -Fxq -- '--noproxy' "$CASE_DIR/curl.args" || fail "remote request should preserve proxy behavior"
pass "loopback and remote proxy handling"

# The target and the whole worktree must be clean before contract execution.
setup_case dirty
printf 'dirty\n' >> "$CASE_DIR/target.txt"
make_contract target.txt "true" "$CASE_DIR/contract.json"
set +e
run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "dirty worktree must fail"
[[ ! -s "$CASE_DIR/curl.count" ]] || fail "dirty worktree must not call Ollama"
contains "$CASE_DIR/stderr" 'clean worktree' "dirty worktree error"
pass "clean-worktree requirement"

# Any change outside the declared target is rejected and the target is restored.
setup_case outside
printf 'untouched\n' > "$CASE_DIR/outside.txt"
git -C "$CASE_DIR" add outside.txt
git -C "$CASE_DIR" commit -qm outside-target
make_contract target.txt "true" "$CASE_DIR/contract.json"
set +e
CURL_MODE=outside run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "outside-target change must fail"
[[ "$(cat "$CASE_DIR/target.txt")" == original ]] || fail "outside-target failure must restore target"
contains "$CASE_DIR/stdout" 'verification changed files outside target_file' "outside-target error"
pass "outside-target change detection"

# Traversal is rejected before Ollama is contacted.
setup_case traversal
make_contract ../outside.txt "true" "$CASE_DIR/contract.json"
set +e
run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "traversal target should be rejected"
[[ ! -s "$CASE_DIR/curl.count" ]] || fail "rejected target must not call Ollama"
contains "$CASE_DIR/stdout" 'relative path without traversal' "traversal error"
pass "path traversal rejection"

# Contract mode is never attempted outside a Git worktree.
NO_GIT_DIR="$TEST_ROOT/non-git"
mkdir -p "$NO_GIT_DIR"
make_contract target.txt "true" "$NO_GIT_DIR/contract.json"
set +e
(cd "$NO_GIT_DIR" && bash "$ROUTER" "$(cat "$NO_GIT_DIR/contract.json")") > "$NO_GIT_DIR/stdout" 2> "$NO_GIT_DIR/stderr"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "non-Git contract must fail"
contains "$NO_GIT_DIR/stderr" 'requires a Git worktree' "non-Git error"
pass "non-Git worktree rejection"

echo "All contract-router tests passed."
