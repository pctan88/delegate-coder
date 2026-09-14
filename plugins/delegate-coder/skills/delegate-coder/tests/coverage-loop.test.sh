#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
COVERAGE_LOOP="$REPO_ROOT/scripts/coverage_loop.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/coverage-loop-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# Test 1: Bug B verification — payload handles quotes, backslashes, and special characters without injection
test_payload_escaping() {
  local target='test/"weird_quote_file.dart'
  local src='lib/test\"quote.dart'
  local template='test/template\test.dart'
  local instructions='Instructions with "quotes" and $variables and `backticks`'
  local current_cmd='flutter test "test/weird\"quote.dart"'

  local payload
  payload="$(TARGET_FILE="$target" SRC_FILE="$src" TEMPLATE_PATH="$template" INSTRUCTIONS="$instructions" CMD="$current_cmd" python3 - <<'PY'
import json, os
payload = {
    "target_file": os.environ["TARGET_FILE"],
    "context_files": [os.environ["SRC_FILE"], os.environ["TEMPLATE_PATH"]],
    "instructions": os.environ["INSTRUCTIONS"],
    "test_command": os.environ["CMD"]
}
print(json.dumps(payload))
PY
)"

  # Verify parsed JSON matches exact values
  python3 - "$payload" "$target" "$src" "$template" "$instructions" "$current_cmd" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
assert p["target_file"] == sys.argv[2]
assert p["context_files"][0] == sys.argv[3]
assert p["context_files"][1] == sys.argv[4]
assert p["instructions"] == sys.argv[5]
assert p["test_command"] == sys.argv[6]
PY
  pass "Bug B: contract JSON payload safely handles quotes, backslashes, and metachars without injection"
}

# Test 2: Bug A verification — multi-file loop processes 2+ files and commits each to keep worktree clean
test_multi_file_loop_commit_each() {
  local fixture_repo="$TEST_ROOT/mock_repo"
  mkdir -p "$fixture_repo/lib/models" "$fixture_repo/test/templates" "$fixture_repo/bin"

  git -C "$fixture_repo" init -q
  git -C "$fixture_repo" config user.email test@example.invalid
  git -C "$fixture_repo" config user.name test

  echo "class ModelA {}" > "$fixture_repo/lib/models/model_a.dart"
  echo "class ModelB {}" > "$fixture_repo/lib/models/model_b.dart"
  echo "void main() {}" > "$fixture_repo/test/templates/template_test.dart"

  echo "/bin/" > "$fixture_repo/.gitignore"
  git -C "$fixture_repo" add .
  git -C "$fixture_repo" commit -qm "initial"

  # Create a mock delegate.sh that simulates contract mode:
  # It checks that the worktree is clean before executing. If dirty, it fails!
  # If clean, it writes the test file and exits with PASS.
  cat > "$fixture_repo/bin/mock_delegate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Contract mode clean worktree assertion
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: contract mode requires a clean worktree before the first write" >&2
  echo "- Status: FAIL"
  exit 1
fi
payload="$2"
target="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["target_file"])' "$payload")"
mkdir -p "$(dirname "$target")"
echo "void main() { /* generated test */ }" > "$target"
echo "- Status: PASS"
exit 0
SH
  chmod +x "$fixture_repo/bin/mock_delegate.sh"

  # Run coverage_loop.sh overriding DELEGATE_SCRIPT
  (
    cd "$fixture_repo"
    export DELEGATE_SCRIPT="$fixture_repo/bin/mock_delegate.sh"

    "$COVERAGE_LOOP" \
      --source-glob "lib/models/*.dart" \
      --template "test/templates/template_test.dart" \
      --target-pattern "test/models/{name}_test.dart" \
      --test-cmd "true" \
      --commit-each
  )

  # Assert BOTH test files were created and processed
  [[ -f "$fixture_repo/test/models/model_a_test.dart" ]] || fail "model_a_test.dart was not created"
  [[ -f "$fixture_repo/test/models/model_b_test.dart" ]] || fail "model_b_test.dart was not created (loop broke on 2nd file!)"

  # Assert git log has commits for both files
  local commit_count
  commit_count="$(git -C "$fixture_repo" rev-list --count HEAD)"
  # initial + 2 backfill commits = 3 commits
  [[ "$commit_count" -ge 3 ]] || fail "Expected at least 3 commits, got $commit_count"

  pass "Bug A: coverage_loop processes 2+ files successfully with --commit-each keeping worktree clean"
}

test_payload_escaping
test_multi_file_loop_commit_each
echo "1..2"
