# Feature: Observability & Adaptive Routing (DELEGATE-CODER-004)

Provides end-to-end trace correlation, granular execution status classification, structured context metadata, actionable failure categorization, fleet-wide aggregation, and adaptive routing across all `delegate-coder` execution modes (`contract`, `exec`, `read`, and `command_override`).

Prior to DELEGATE-CODER-004, logging in `.claude/delegate-coder.log` lacked unique run identifiers, retry linkages, and fine-grained failure categorisation. Operational failures (e.g., worker missing, syntax preflight check, timeout, dependency guards) were either conflated into coarse `FAIL`/`TEST_FAIL` or unobserved across multiple task attempts.

DELEGATE-CODER-004 introduces:
1. **Correlation IDs**: `task_id` (shared across retries or explicit via `DELEGATE_TASK_ID`), `run_id` (unique per attempt), `attempt` (1-indexed attempt number), and `parent_run_id` (UUID of parent attempt if retried, else `null`).
2. **Unified Status Classification**: An explicit `status` field on completion (`end`) records:
   `PASS`, `NOOP`, `PREFLIGHT_FAIL`, `DEPENDENCY_GUARD_FAIL`, `TEST_FAIL`, `TIMEOUT`, `WORKER_START_FAIL`, `RESTORE_FAIL`, `ERROR`.
3. **Structured Context Metadata**: Records repository basename, absolute Git root, branch, targets array, test command, commit SHA, and changed file count.
4. **Actionable Diagnostics & Token Extraction**: Logs error messages and operational hints; parses Ollama prompt/eval token metrics and duration breakdowns.
5. **Fleet-Wide Aggregation (`stats.sh`)**: Multi-file inspection, auto-discovery across worktrees/siblings (`--fleet` / `--all`), task deduplication vs attempt counts, and `--json` export.
6. **Adaptive Routing & Fallback Policies**: Supports `fallback_agent` and `fallback_chain` under `fallback: graceful`, automatically retrying on healthy alternative workers while preserving strict policy controls.
7. **Additive Schema & Backward Compatibility**: Existing log fields and exit codes remain strictly byte-compatible.

| | |
|---|---|
| **Feature** | DELEGATE-CODER-004 — Observability & Adaptive Routing |
| **Status** | Implemented; verified by deterministic unit and regression test suites |
| **Repository** | `delegate-coder` |
| **Related Packs** | [DELEGATE-CODER-000](../DELEGATE-CODER-000-worker-orchestration/README.md), [DELEGATE-CODER-001](../DELEGATE-CODER-001-contract-router/README.md) |
| **Roadmap** | Phase 1: Run correlation & status enum (Complete)<br>Phase 2: Per-run task/artifact directories & context (Complete)<br>Phase 3: Token extraction & diagnostics (Complete)<br>Phase 4: Fleet aggregation (Complete)<br>Phase 5: Adaptive routing (Complete) |
