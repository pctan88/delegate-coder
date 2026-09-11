# Decision Log: Observability Phase 1 (DELEGATE-CODER-004)

## 2026-09-11: Additive Schema & Backward Compatibility
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
