---
repo: delegate-coder
feature: DELEGATE-CODER-002
status: in_review
source_pr: 6
last_synced: 2026-07-15
---

# Product requirements: resilient contract execution

## Problem

The contract router is intentionally a single-file, full-replacement worker.
In practice, a new or small file can receive an output budget that is too
small, a worker may need neighboring interfaces to implement the target, and
an inferred test command may not exist in the repository's active environment.
The router should fail early and preserve the existing safety boundary while
making these cases diagnosable.

## Goals

1. Give new and small targets a bounded minimum output budget without bypassing
   the context-size guard.
2. Allow explicitly selected repository context files to be supplied as
   read-only references.
3. Detect a usable Python test runner rather than assuming pytest from the
   presence of `tests/`.
4. Run cheap syntax checks before an expensive project test command.
5. Keep contract execution local by default, transactional, and opt-in.
6. Preserve machine-readable reports, one correction retry, rollback, and
   benchmark isolation from DELEGATE-CODER-001.

## Non-goals

- Turning contract mode into a repository-wide autonomous agent.
- Allowing context files to include credentials, `.env` files, or arbitrary
  ignored data.
- Replacing the orchestrator's architecture, security, or final-review role.
- Changing the default `read`/`exec` adapter path.
- Claiming a performance improvement without a new additive benchmark.

## Acceptance criteria

- A new target receives at least the configured minimum output budget and is
  rejected before Ollama if prompt plus output exceeds `num_ctx`.
- `context_files` are repository-relative regular files, are bounded by size,
  and reject secret-like paths before branch creation or model contact.
- The prompt labels context as untrusted read-only reference material and
  preserves arbitrary source text without relying on executable interpolation.
- Test detection chooses an actually available interpreter/runner and reports
  uncertainty instead of writing a false command.
- Syntax preflight executes arguments directly, without `eval` or shell
  interpolation of repository filenames.
- Existing transaction, rollback, retry, timeout, no-op, batch, and index
  guarantees remain true.
- The deterministic suites cover every new boundary and the frozen benchmark
  files remain unchanged.
