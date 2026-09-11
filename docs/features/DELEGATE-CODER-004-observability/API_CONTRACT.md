# API Contract: Observability Phase 1 (DELEGATE-CODER-004)

## Audit Log Record Schema (`.claude/delegate-coder.log`)

The log continues to be formatted as newline-delimited JSON (JSONL). Every record (`event: "start"` or `event: "end"`) includes correlation IDs. Completion records (`event: "end"`) include the unified status classification.

### Event: `start`
```json
{
  "ts": "2026-09-11T07:15:00Z",
  "agent": "local-ollama",
  "model": "qwen3-coder:30b",
  "mode": "contract",
  "event": "start",
  "run_id": "c1f76d49-43c2-48a5-8120-1a2b3c4d5e6f",
  "task_id": "8a0ef921-b3b4-4b55-a222-9876543210ab",
  "attempt": 1,
  "parent_run_id": null,
  "branch": "delegate/contract-20260911-071500-12345"
}
```

### Event: `end`
```json
{
  "ts": "2026-09-11T07:15:28Z",
  "agent": "local-ollama",
  "model": "qwen3-coder:30b",
  "mode": "contract",
  "event": "end",
  "run_id": "c1f76d49-43c2-48a5-8120-1a2b3c4d5e6f",
  "task_id": "8a0ef921-b3b4-4b55-a222-9876543210ab",
  "attempt": 1,
  "parent_run_id": null,
  "duration_s": 28,
  "exit_code": 0,
  "status": "PASS",
  "retries": 0,
  "restored": false,
  "branch": "delegate/contract-20260911-071500-12345",
  "error": "",
  "total_duration": 28000000000,
  "load_duration": 15000000,
  "prompt_eval_count": 1250,
  "prompt_eval_duration": 1200000000,
  "eval_count": 350,
  "eval_duration": 26000000000
}
```

## Correlation Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `task_id` | String (UUID) | Yes | Correlation ID representing the logical task. Inherited from `DELEGATE_TASK_ID` environment variable if set; otherwise generated freshly at invocation start. Shared across retries. |
| `run_id` | String (UUID) | Yes | Unique ID for the specific execution attempt. Generated freshly per attempt via `python3 -c 'import uuid; print(uuid.uuid4())'`. |
| `attempt` | Integer | Yes | 1-indexed attempt sequence number for this logical task (default 1). |
| `parent_run_id` | String (UUID) or `null` | Yes | `run_id` of the immediate predecessor run if this is a retry attempt; otherwise `null`. |

## Unified Status Enum (`status`)

| Status | Meaning | Typical Exit Code | Rollback Triggered |
|---|---|---|---|
| `PASS` | Task completed successfully, tests passed, candidate accepted. | 0 | No |
| `NOOP` | Worker candidate produced byte-identical output to original file; safely restored. | 0 | Yes |
| `PREFLIGHT_FAIL` | Syntax preflight failed (e.g. invalid syntax in candidate file). | 1 | Yes |
| `DEPENDENCY_GUARD_FAIL` | Verification command or candidate modified files outside the declared target file or allow_paths. | 1 (or 6 for allow_paths) | Yes |
| `TEST_FAIL` | Verification command exited non-zero with standard test failure (non-timeout). | 1 | Yes |
| `TIMEOUT` | Verification command timed out (exit 124 or 142). | 1 | Yes |
| `WORKER_START_FAIL` | Worker binary not found (exit 127), missing executable, or process failed immediately with 0 bytes output. | 4 (or 127) | Yes |
| `RESTORE_FAIL` | An error occurred attempting to restore worktree snapshot or index during rollback. | 1 | Attempted |
| `ERROR` | Unclassified script execution failure or contract parsing error. | Non-zero | Yes |
