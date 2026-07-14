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
  printf 'original\n' > "$CASE_DIR/target.txt"
  git -C "$CASE_DIR" add target.txt
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
request_file=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == --data-binary ]]; then
    request_file="${arg#@}"
  fi
  previous="$arg"
done
[[ -z "$request_file" ]] || cp "$request_file" "${CURL_REQUEST_PREFIX:?CURL_REQUEST_PREFIX}$count"
mode="${CURL_MODE:-good}"
content=good
if [[ "$mode" == retry && "$count" -eq 1 ]]; then content=bad; fi
if [[ "$mode" == bad ]]; then content=bad; fi
if [[ "$mode" == noop ]]; then content=original; fi
if [[ "$mode" == batch-noop && "$count" -eq 2 ]]; then content=original; fi
done_reason=stop
if [[ "$mode" == truncated ]]; then content=partial; done_reason=length; fi
printf '{"response":"```text\\n%s\\n```","done_reason":"%s"}' "$content" "$done_reason"
SH
  chmod +x "$CASE_DIR/bin/ollama" "$CASE_DIR/bin/curl"
  printf 'NAME ID SIZE PROCESSOR UNTIL\nold-model abc 1GB 100%% 1m\nqwen3-coder:30b def 1GB 100%% 1m\n' > "$CASE_DIR/ollama.ps"
  : > "$CASE_DIR/ollama.stops"
  : > "$CASE_DIR/curl.count"
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
! grep -Fq 'contract-router:' "$CASE_DIR/stdout" || fail "progress must not pollute stdout"
pass "valid JSON contract and clean report"

# The dispatcher also accepts the same contract on stdin.
if ! (
  cd "$CASE_DIR" || exit 1
  printf '%s' "$(cat "$CASE_DIR/contract.json")" | \
    PATH="$CASE_DIR/bin:$PATH" \
    OLLAMA_PS_FILE="$CASE_DIR/ollama.ps" \
    OLLAMA_STOP_LOG="$CASE_DIR/ollama.stops" \
    CURL_COUNT_FILE="$CASE_DIR/curl.count" \
    CURL_REQUEST_PREFIX="$CASE_DIR/request.stdin." \
    CURL_ENV_FILE="$CASE_DIR/curl.env.stdin" \
    CURL_MODE=good \
    bash "$DISPATCH" contract > "$CASE_DIR/stdin.stdout" 2> "$CASE_DIR/stdin.stderr"
); then
  fail "stdin contract should pass"
fi
grep -Eq -- '- Status: (PASS|NOOP)' "$CASE_DIR/stdin.stdout" || fail "stdin contract report status"
pass "stdin contract input"

# Audit events include contract status and retry count.
contains "$CASE_DIR/.claude/delegate-coder.log" '"mode":"contract"' "contract run should be audited"
contains "$CASE_DIR/.claude/delegate-coder.log" '"status":"PASS"' "audit should record contract status"
contains "$CASE_DIR/.claude/delegate-coder.log" '"retries":0' "audit should record retry count"

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
contains "$CASE_DIR/stdout" '- Status: FAIL' "failed report status"
pass "retry limit and failed report"

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
make_contract new.txt "grep -q '^good$' new.txt" "$CASE_DIR/contract.json"
run_dispatch "$(cat "$CASE_DIR/contract.json")" || fail "new-file contract should pass"
[[ -f "$CASE_DIR/new.txt" ]] || fail "new-file contract should create target"
contains "$CASE_DIR/stdout" '- Status: PASS' "new-file report status"
pass "new-file target support"

# A top-level array runs sequentially and returns one combined report.
setup_case batch
printf 'original\n' > "$CASE_DIR/second.txt"
git -C "$CASE_DIR" add second.txt
git -C "$CASE_DIR" commit -qm second
python3 - "$CASE_DIR/batch.json" <<'PY'
import json, sys
json.dump([
    {"target_file": "target.txt", "instructions": "update", "test_command": "grep -q '^good$' target.txt"},
    {"target_file": "second.txt", "instructions": "update", "test_command": "grep -q '^original$' second.txt"},
], open(sys.argv[1], "w"))
PY
CURL_MODE=batch-noop run_dispatch "$(cat "$CASE_DIR/batch.json")" || fail "contract batch should pass"
[[ "$(cat "$CASE_DIR/curl.count")" == 2 ]] || fail "batch should generate each contract once"
contains "$CASE_DIR/stdout" '# Contract Batch Result' "batch report heading"
contains "$CASE_DIR/stdout" '## Contract 1' "batch report first contract"
contains "$CASE_DIR/stdout" '## Contract 2' "batch report second contract"
contains "$CASE_DIR/stdout" -- '- Status: PASS' "batch with a NOOP child should aggregate as PASS"
contains "$CASE_DIR/.claude/delegate-coder.log" '"status":"PASS"' "batch audit should use aggregate status"
pass "sequential contract batch"

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

# Traversal is rejected before Ollama is contacted.
setup_case traversal
make_contract ../outside.txt "true" "$CASE_DIR/contract.json"
set +e
run_dispatch "$(cat "$CASE_DIR/contract.json")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "traversal target should be rejected"
[[ ! -s "$CASE_DIR/curl.count" ]] || fail "rejected target must not call Ollama"
contains "$CASE_DIR/stderr" 'relative path without traversal' "traversal error"
pass "path traversal rejection"

echo "All contract-router tests passed."
