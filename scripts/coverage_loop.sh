#!/usr/bin/env bash
# scripts/coverage_loop.sh — Unattended test coverage backfill loop using delegate-contract.
#
# Usage:
#   scripts/coverage_loop.sh \
#     --source-glob "lib/domain/model/*.dart" \
#     --template "test/core/utils/duration_formatter_test.dart" \
#     --target-pattern "test/domain/model/{name}_test.dart" \
#     --test-cmd "flutter test {test_target}" \
#     [--commit-each] \
#     [--base-branch <branch>] \
#     [--stop-on-failure] \
#     [--dry-run]
#
set -euo pipefail

SOURCE_GLOB=""
TEMPLATE_FILE=""
TARGET_PATTERN=""
TEST_CMD=""
DRY_RUN=0
STOP_ON_FAILURE=0
COMMIT_EACH=0
BASE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-glob) SOURCE_GLOB="$2"; shift 2 ;;
    --template) TEMPLATE_FILE="$2"; shift 2 ;;
    --target-pattern) TARGET_PATTERN="$2"; shift 2 ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    --commit-each) COMMIT_EACH=1; shift ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --stop-on-failure) STOP_ON_FAILURE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: scripts/coverage_loop.sh --source-glob <glob> --template <template_path> --target-pattern <pattern> --test-cmd <cmd> [options]"
      echo ""
      echo "Options:"
      echo "  --commit-each         Stage and commit passing tests between iterations to keep the worktree clean"
      echo "  --base-branch <name>  Checkout base branch before each iteration (resets uncommitted changes to keep tree clean)"
      echo "  --stop-on-failure     Stop the loop immediately if a contract fails"
      echo "  --dry-run             Print planned executions without dispatching contracts"
      echo "  -h, --help            Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SOURCE_GLOB" || -z "$TEMPLATE_FILE" || -z "$TARGET_PATTERN" || -z "$TEST_CMD" ]]; then
  echo "Error: Missing required arguments. Run with --help for usage." >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Error: Template file '$TEMPLATE_FILE' not found." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELEGATE_SCRIPT="${DELEGATE_SCRIPT:-$SCRIPT_DIR/../plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh}"

# Default to --commit-each if neither --commit-each nor --base-branch is specified
if [[ "$COMMIT_EACH" -eq 0 && -z "$BASE_BRANCH" ]]; then
  COMMIT_EACH=1
fi

echo "=================================================="
echo "⚡ delegate-coder unattended coverage backfill loop"
echo "=================================================="
echo "Source glob:     $SOURCE_GLOB"
echo "Template file:   $TEMPLATE_FILE"
echo "Target pattern:  $TARGET_PATTERN"
echo "Test command:    $TEST_CMD"
echo "Commit each:     $COMMIT_EACH"
echo "Base branch:     ${BASE_BRANCH:-(none)}"
echo "Dry run:         $DRY_RUN"
echo "=================================================="

# Expand glob
shopt -s nullglob
# shellcheck disable=SC2206
sources=( $SOURCE_GLOB )
shopt -u nullglob

if [[ ${#sources[@]} -eq 0 ]]; then
  echo "No source files matched pattern: $SOURCE_GLOB"
  exit 0
fi

total=${#sources[@]}
passed=0
failed=0
skipped=0

for i in "${!sources[@]}"; do
  src="${sources[$i]}"
  base="$(basename "$src")"
  name="${base%.*}"
  target="${TARGET_PATTERN//\{name\}/$name}"
  current_cmd="${TEST_CMD//\{test_target\}/$target}"
  current_cmd="${current_cmd//\{source\}/$src}"

  echo ""
  echo "[$((i + 1))/$total] Processing: $src"
  echo "  -> Target Test: $target"

  if [[ -n "$BASE_BRANCH" ]]; then
    echo "  -> Checking out base branch: $BASE_BRANCH"
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || {
      echo "Error: Failed to checkout base branch '$BASE_BRANCH'" >&2
      exit 1
    }
  fi

  if [[ -f "$target" ]]; then
    echo "  -> Test file already exists. Checking existing test..."
    if bash -c "$current_cmd" >/dev/null 2>&1; then
      echo "  -> Existing test already passes. Skipping."
      skipped=$((skipped + 1))
      continue
    else
      echo "  -> Existing test fails or is incomplete. Re-generating..."
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [Dry Run] Would dispatch contract for $target"
    continue
  fi

  instructions="Write unit tests for the model/classes in $src: cover initialization, serialization/parsing, methods, and edge cases. Match the structural style (imports, framework runner, test organization) of the provided template test file $TEMPLATE_FILE. Target public API only."

  # Bug B fix: pass arguments safely via environment variables to python to avoid shell heredoc interpolation injection
  contract_payload="$(TARGET_FILE="$target" SRC_FILE="$src" TEMPLATE_PATH="$TEMPLATE_FILE" INSTRUCTIONS="$instructions" CMD="$current_cmd" python3 - <<'PY'
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

  echo "  -> Dispatching contract to delegate.sh..."
  set +e
  report="$(bash "$DELEGATE_SCRIPT" contract "$contract_payload" 2>&1)"
  exit_code=$?
  set -e

  status="$(echo "$report" | sed -n 's/^- Status: //p' | head -n1)"
  [[ -n "$status" ]] || status="FAIL"

  if [[ "$status" =~ ^(PASS|NOOP)$ && $exit_code -eq 0 ]]; then
    echo "  -> Result: PASS"
    passed=$((passed + 1))

    # Bug A fix: commit each accepted test or prepare clean worktree for subsequent contract
    if [[ "$COMMIT_EACH" -eq 1 && -f "$target" ]]; then
      echo "  -> Committing accepted test to keep worktree clean for next contract..."
      git add "$target"
      git commit -m "test: backfill $target via delegate-coder" >/dev/null 2>&1 || true
    fi
  else
    echo "  -> Result: $status (exit code $exit_code)"
    failed=$((failed + 1))
    if [[ "$STOP_ON_FAILURE" -eq 1 ]]; then
      echo "Stop-on-failure requested. Halting loop."
      break
    fi
  fi
done

echo ""
echo "=================================================="
echo "Backfill Summary:"
echo "Total eligible: $total"
echo "Passed:         $passed"
echo "Failed:         $failed"
echo "Skipped:        $skipped"
echo "=================================================="

if [[ $failed -gt 0 ]]; then
  exit 1
fi
exit 0
