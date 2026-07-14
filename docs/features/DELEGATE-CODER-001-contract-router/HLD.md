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
| `contract-router.sh` | Require Git/branch/clean-worktree preconditions, snapshot target, prepare Ollama, generate strict structured output, stage/verify/promote transactionally, retry once, and render attributable report |
| Ollama `/api/generate` | Produce the complete updated file using the configured local model |
| `contract-router.test.sh` | Exercise the router with fake Ollama/curl commands and deterministic fixtures |
| `.claude/delegate-coder.log` | Store operational JSON events for `/delegate stats` and diagnosis |

## Target flow

```text
contract JSON
  -> delegate.sh audit:start
  -> contract-router parse + path guards
  -> estimate complete prompt; reject if it exceeds num_ctx
  -> stop non-selected Ollama models
  -> POST /api/generate (single turn, full-file response)
  -> reject malformed/additional/empty output or done_reason=length
  -> normalize exactly one trailing newline; stage candidate at target path
  -> timeout(test_command)
       pass + changed  -> promote candidate -> PASS
       pass + unchanged -> restore -> NOOP
       fail             -> one generation with exact failure log -> promote or restore
  -> pre-contract target diff + metrics + final test log
  -> delegate.sh audit:end
```

## Safety boundaries

- `target_file` is relative, cannot traverse, cannot resolve outside the Git
  repository, and cannot be a symlink.
- The parent directory must already exist; a missing target file is allowed for
  new-file contracts.
- The full worktree must be clean and execution must be on a named isolated
  feature/delegate branch. Dirty targets are rejected.
- The original file's existence, bytes, and mode are snapshotted before
  generation. A candidate may occupy the target for verification, but promotion
  happens only after success; all unsuccessful exits restore or remove it.
- Structured JSON output is the only accepted transport; markdown/source fences
  are ordinary UTF-8 content and are never parsed as transport delimiters.
- The complete initial prompt is estimated before Ollama model eviction or an
  HTTP request; correction prompts are estimated again with the failure log.
- Generation and tests have bounded timeouts. A failed test can trigger only
  one retry.

## Runtime configuration

`implementation_backend` (default `agent`), `DELEGATE_MODEL`, `DELEGATE_NUM_CTX`, `DELEGATE_KEEP_ALIVE`,
`DELEGATE_CURL_TIMEOUT`, `DELEGATE_TEST_TIMEOUT`, and `OLLAMA_HOST` are
environment-level controls. Defaults and semantics are defined in
`API_CONTRACT.md`.

## Compatibility and benchmark boundary

Contract mode is opt-in through configuration or `delegate.sh contract`; the
existing `read` and default `exec` adapter paths remain separate. Changes to the default headless delegation
path (`SKILL.md`, `detect.sh`, or `delegate.sh` behavior used by the benchmark)
must be treated as benchmark-impacting *(confirm release process)*. Human-invoked
router and documentation changes do not overwrite the v1 dataset.
