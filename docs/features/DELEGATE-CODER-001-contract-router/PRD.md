# PRD: Contract-driven local Qwen worker

**Feature:** DELEGATE-CODER-001  ·  **Status:** Implemented; acceptance tracking
backfilled  ·  **Last updated:** 2026-07-14

## Problem

Open-ended local coding-agent sessions spend tokens re-prefilling long context,
make targeted edits that are difficult to verify, and can return a confident
summary without proving the resulting file is correct. The cloud orchestrator
needs a small, deterministic execution unit with an objective result.

## Target users

- Cloud orchestrators such as Codex, Claude Code, Claude Cowork, or ChatGPT
  that need a local implementation worker.
- Maintainers who want a low-token, auditable path for bounded file edits.
- Benchmark and operations users who need retry, latency, and outcome data.

## User flow

The orchestrator submits a JSON Task Contract. `delegate-coder` validates the
contract and clean worktree before creating an isolated branch, snapshots the
target and child worktree state, prepares Ollama, asks the local model for a
complete structured file replacement, verifies a staged candidate, restores
unsuccessful work transactionally (including outside-target tracked and
untracked mutations), retries once with the exact failure log if needed, and
returns status, restoration state, attributable diff, model metrics, and final
test output.

With the default `OLLAMA_HOST` (`http://127.0.0.1:11434`), generation runs
against a loopback Ollama server, so file contents stay on the machine. If
`OLLAMA_HOST` is overridden, contents are sent to that endpoint and its privacy
properties apply. Contract mode is therefore the privacy-safe execution path
when its host remains loopback, in contrast to hosted chat-agent workers that
send code to a third-party provider.

## Scope

- Parse one contract or a sequential top-level contract array.
- Support `target_file`, `instructions`, and `test_command` with a lightweight
  fallback for damaged JSON.
- Use raw Ollama `/api/generate` with a compiler-style system prompt.
- Require structured `{updated_file}` output with no extra fields, deterministic
  temperature `0`, UTF-8 preservation, and exactly one trailing newline.
- Stop resident Ollama models other than the selected model before generation.
- Require a Git worktree, clean target/worktree, and isolated feature/delegate
  branch; validate shape, path, and bounded-runner preconditions before branch
  creation; enforce repository-relative, non-symlink target boundaries.
- Stage candidates on the target path for tests, promote only after success, and
  restore existing content/mode, modified tracked outside files, and new
  untracked outside files on every failure. Preserve earlier accepted batch
  children.
- Apply newline normalization, context truncation protection, bounded generation
  and test timeouts, one correction retry, and explicit `NOOP` status.
- Record contract start/end status, duration, model, exit code, and retries in
  the existing audit log; keep that log ignored through `.git/info/exclude`
  without editing a tracked consumer ignore file.
- Capture all Ollama timing/token counters and detect changes outside the target.
- Provide an additive five-warm-repetition local benchmark, a deterministic
  no-live-model runner test, and a JSONL reporter that reproduces the frozen
  24-A/24-B aggregate; preserve the historical Claude+MiMo v1 data.
- Document the contract protocol and verify it with deterministic shell tests.

## Out of scope

- Replacing the existing `read` and `exec` chat-agent adapters.
- Automatic cloud orchestration, PR creation, or merge decisions.
- Persistence outside the existing local audit log.
- Inventing a universal test-command discovery policy for every repository.
- Re-running or overwriting the frozen v1 benchmark dataset.

## Acceptance criteria

1. Valid contracts produce a clean markdown report with `PASS`, target-only
   pre-contract diff, restoration state, Ollama metrics, and final test log.
2. Invalid, traversal, outside-repository, symlink, or non-regular targets are
   rejected before Ollama is contacted.
3. The selected `DELEGATE_MODEL`, `DELEGATE_NUM_CTX`, and `DELEGATE_KEEP_ALIVE`
   values reach the Ollama request.
4. An estimated prompt larger than `num_ctx` is rejected before the model is
   contacted, and a response with `done_reason: length` never replaces the
   target file.
5. A failed verification gets exactly one correction attempt containing the
   current file and exact terminal output; a second failure returns `FAIL`.
6. An unchanged passing result returns `NOOP`, not `PASS`.
7. Test commands and generation requests are bounded by configurable timeouts.
8. Sequential batches preserve JSON order for at least 100 items, stop after the
   first failure, and report completed/failed/skipped counts.
9. New files, GPU cleanup, newline normalization, proxy behavior, UTF-8/fence
   preservation, malformed output, and audit logging are covered by tests.
10. Existing adapter behavior and the published v1 benchmark remain protected.

## Dependencies and risks

- Requires `python3`, `curl`, Git, and a reachable Ollama server *(confirm
  supported platforms and minimum versions)*.
- Model context limits can still make a very large file impractical; the
  truncation guard prevents silent writes but does not solve capacity.
- The regex parser fallback is intentionally limited and should not be treated
  as a full JSON parser.
- Arbitrary `test_command` strings execute locally; callers must treat the
  contract source as trusted.
- Ollama eviction can affect unrelated local work; the operator-visible warning
  and selected-model exception are the current trade-off *(confirm UX)*.

## Approval

| Role | Name | Status | Date |
|---|---|---|---|
| Maintainer | | Pending — scope and default-path compatibility | |
| Plugin/skill owner | | Pending — router and audit behavior | |
| Benchmark owner | | Pending — frozen v1 dataset protection | |
