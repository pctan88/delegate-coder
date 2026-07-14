# HLD: Contract-driven local Qwen worker

**Feature:** DELEGATE-CODER-001  ·  **Last updated:** 2026-07-14

## Context

The plugin already has chat-agent adapters selected through `delegate.sh`.
Contract mode adds a strict local path for full-file replacement through
Ollama, so the worker does not need a multi-turn tool loop.

## Components and responsibilities

| Component | Responsibility |
|---|---|
| `delegate.sh` | Dispatch `contract` mode, isolate stdout report from stderr progress, and append audit start/end events |
| `contract-router.sh` | Parse/validate contracts, prepare Ollama, generate, write atomically, test, retry once, and render the report |
| Ollama `/api/generate` | Produce the complete updated file using the configured local model |
| `contract-router.test.sh` | Exercise the router with fake Ollama/curl commands and deterministic fixtures |
| `.claude/delegate-coder.log` | Store operational JSON events for `/delegate stats` and diagnosis |

## Target flow

```text
contract JSON
  -> delegate.sh audit:start
  -> contract-router parse + path guards
  -> stop non-selected Ollama models
  -> POST /api/generate (single turn, full-file response)
  -> reject done_reason=length; extract code fence; normalize newline
  -> atomic target replacement
  -> timeout(test_command)
       pass + changed  -> PASS
       pass + unchanged -> NOOP
       fail             -> one generation with exact failure log -> PASS or FAIL
  -> target-only diff + final test log
  -> delegate.sh audit:end
```

## Safety boundaries

- `target_file` is relative, cannot traverse, cannot resolve outside the Git
  repository, and cannot be a symlink.
- The parent directory must already exist; a missing target file is allowed for
  new-file contracts.
- Writes use a temporary file in the target directory and `mv`, preserving the
  existing mode where applicable.
- The original file is snapshotted before generation and is not replaced when
  generation is rejected.
- Generation and tests have bounded timeouts. A failed test can trigger only
  one retry.

## Runtime configuration

`DELEGATE_MODEL`, `DELEGATE_NUM_CTX`, `DELEGATE_KEEP_ALIVE`,
`DELEGATE_CURL_TIMEOUT`, `DELEGATE_TEST_TIMEOUT`, and `OLLAMA_HOST` are
environment-level controls. Defaults and semantics are defined in
`API_CONTRACT.md`.

## Compatibility and benchmark boundary

Contract mode is opt-in through `delegate.sh contract`; the existing `read` and
`exec` adapter paths remain separate. Changes to the default headless delegation
path (`SKILL.md`, `detect.sh`, or `delegate.sh` behavior used by the benchmark)
must be treated as benchmark-impacting *(confirm release process)*. Human-invoked
router and documentation changes do not overwrite the v1 dataset.
