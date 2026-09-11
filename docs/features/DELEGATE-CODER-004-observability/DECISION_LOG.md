# Decision Log: Observability (DELEGATE-CODER-004)

## 2026-09-11: Additive Schema & Backward Compatibility (Phase 1)
- **Context**: The existing audit log `.claude/delegate-coder.log` is consumed by `stats.sh` and benchmark harnesses, which expect fields like `exit_code`, `duration_s`, and `event`.
- **Decision**: Keep all existing keys intact and preserve JSONL output format. Correlation IDs (`run_id`, `task_id`, `attempt`, `parent_run_id`) and `status` are added at the root level of the JSON record.
- **Rationale**: Ensures zero breakage to existing tooling and benchmark workflows while enabling correlated tracing.

## 2026-09-11: UUID Generation Strategy
- **Context**: Portability across macOS and Linux without assuming external tools like `uuidgen` or non-standard shell utilities.
- **Decision**: Generate UUIDs strictly using Python 3 standard library: `python3 -c 'import uuid; print(uuid.uuid4())'`.
- **Rationale**: Python 3 is already a hard dependency across `delegate-coder` for parsing JSON contracts and context validation.

## 2026-09-11: Task ID Scoping and Cross-Invocation Retries
- **Context**: Tasks can retry within a single contract invocation (the built-in self-correction retry) or across orchestrator runs (e.g. `dc-watch` or chat-agent re-assignment).
- **Decision**: Accept optional `DELEGATE_TASK_ID` from the environment. If unset, generate a new UUID for the logical task. Every invocation generates its own unique `run_id`.
- **Rationale**: Eliminates guesswork across invocations and allows orchestrators to correlate multi-step workflows.

## 2026-09-11: Fine-Grained Status Reclassification
- **Context**: `contract-router.sh` previously mapped multiple failure modes (syntax errors, test failures, timeouts, dependency violations) into coarse `FAIL` or `TEST_FAIL`. Similarly, `delegate.sh` did not log when an agent failed to start.
- **Decision**: Standardize on a unified status enum (`PASS`, `NOOP`, `PREFLIGHT_FAIL`, `DEPENDENCY_GUARD_FAIL`, `TEST_FAIL`, `TIMEOUT`, `WORKER_START_FAIL`, `RESTORE_FAIL`, `ERROR`). Classify timeout exits (124/142) as `TIMEOUT`, outside worktree modifications as `DEPENDENCY_GUARD_FAIL`, restore errors as `RESTORE_FAIL`, and missing/empty worker exits as `WORKER_START_FAIL`.
- **Rationale**: Distinguishes operational/environment failures from code-generation flaws, revealing the true accuracy of models like local Qwen and Codex.

## 2026-09-11: Structured Context Metadata (Phase 2)
- **Context**: Across multi-repo workspaces and worktrees, logs lacked context on which repository was targeted, what branch was used, which target files were modified, what verification test was run, and how many files changed.
- **Decision**: Add 7 context fields to audit records:
  - `repo`: Repository basename (`null` outside Git).
  - `git_root`: Canonical absolute path (`null` outside Git).
  - `branch`: Current branch name (`null` if detached HEAD / unborn).
  - `target_files`: JSON array of relative paths (contract targets, batch targets, or modified files in exec mode; `[]` in read mode).
  - `test_command`: Test command string (`null` if none/not applicable).
  - `commit_sha`: Git commit SHA of accepted change if committed on PASS, else `null`.
  - `changed_file_count`: Modified file count (e.g. 1 on accepted contract, 0 on NOOP or failure rollback).
- **Rationale**: Enables fleet-wide aggregation across worktrees and repos without parsing unstructured text reports, while maintaining strict backward compatibility.

## 2026-09-12: Failure Categorization & Actionable Diagnostic Hints (Phase 3)
- **Context**: When workers or contracts fail, logs previously lacked diagnostic hints and granular categorization for operational vs test/syntax failures. Operators could not immediately tell if an Ollama model failed to start/connect, if tests failed, or if allow_paths were violated.
- **Decision**:
  - Distinguish worker start/connection failures (`WORKER_START_FAIL`) in `contract-router.sh` when Ollama cannot be reached or returns malformed output, providing guidance hints (`Ensure Ollama is running...`).
  - Pass diagnostic hints (`hint`) and error descriptions (`error`) into `append_json_event` across all execution paths (contract router reports, missing agent, worker command failure, allow_paths guard violations, test binary missing 127).
- **Rationale**: Gives operators immediate troubleshooting guidance in structured log records, eliminating guesswork during automated triage.

## 2026-09-12: Fleet-Wide Log Aggregation and Granular Reporting (Phase 4)
- **Context**: When working across multiple git worktrees and sibling repositories, developers previously saw only isolated local statistics (e.g. 2 tasks reported locally out of 41 actual runs). Retries inflated total counts, and pass rates did not distinguish between operational failures and test failures.
- **Decision**:
  - Upgrade `stats.sh` to accept multi-file arguments and auto-discover `.claude/delegate-coder.log` across git worktrees and sibling workspace folders via `--fleet` / `--all`.
  - Distinguish logical tasks (`task_id` deduplication) from execution attempts (`run_id`).
  - Surface status breakdowns (`status_breakdown`), pass rates, and token accounting (`prompt_eval_count` + `eval_count`).
  - Provide a structured JSON export (`--json`) for automation.
  - Retain default single-file human-readable output when invoked with no arguments for full backward compatibility.
- **Rationale**: Unlocks transparent visibility across the full development fleet without breaking existing single-workspace workflows or benchmark scripts.
