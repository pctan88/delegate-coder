# Feature: Observability Phase 1 — Run Correlation & Unified Status Classification (DELEGATE-CODER-004)

Provides end-to-end trace correlation and granular execution status classification across all `delegate-coder` execution modes (`contract`, `exec`, `read`, and `command_override`).

Prior to DELEGATE-CODER-004, logging in `.claude/delegate-coder.log` lacked unique run identifiers, retry linkages, and fine-grained failure categorisation. Operational failures (e.g., worker missing, syntax preflight check, timeout, dependency guards) were either conflated into coarse `FAIL`/`TEST_FAIL` or unobserved across multiple task attempts.

Phase 1 introduces:
1. **Correlation IDs**: `task_id` (shared across retries or explicit via `DELEGATE_TASK_ID`), `run_id` (unique per attempt), `attempt` (1-indexed attempt number), and `parent_run_id` (UUID of parent attempt if retried, else `null`).
2. **Unified Status Classification**: An explicit `status` field on completion (`end`) records:
   `PASS`, `NOOP`, `PREFLIGHT_FAIL`, `DEPENDENCY_GUARD_FAIL`, `TEST_FAIL`, `TIMEOUT`, `WORKER_START_FAIL`, `RESTORE_FAIL`, `ERROR`.
3. **Additive Schema & Backward Compatibility**: Existing log fields (`ts`, `agent`, `model`, `mode`, `event`, `duration_s`, `exit_code`, `retries`, `restored`, Ollama metrics) and script exit codes remain byte-compatible. Downstream tools such as `stats.sh` continue to function without modification.

| | |
|---|---|
| **Feature** | DELEGATE-CODER-004 — Observability Phase 1 (Run correlation & status enum) |
| **Status** | Implemented; verified by deterministic unit and regression test suites |
| **Repository** | `delegate-coder` |
| **Related Packs** | [DELEGATE-CODER-000](../DELEGATE-CODER-000-worker-orchestration/README.md), [DELEGATE-CODER-001](../DELEGATE-CODER-001-contract-router/README.md) |
| **Roadmap** | Phase 1: Run correlation & status enum<br>Phase 2: Per-run task/artifact directories<br>Phase 3: Token extraction<br>Phase 4: Fleet aggregation<br>Phase 5: Adaptive routing |
