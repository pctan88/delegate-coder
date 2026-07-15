# Feature: Contract-driven local Qwen worker (DELEGATE-CODER-001)

Turn `delegate-coder` into a strict local execution harness for bounded,
single-file edits while keeping Claude/Codex/other cloud orchestrators in the
planning and acceptance role.

With the default `OLLAMA_HOST` (`http://127.0.0.1:11434`), execution runs
against a loopback Ollama model, so code stays on the machine. If
`OLLAMA_HOST` is overridden, file contents are sent to that endpoint and its
privacy properties apply; this is unlike hosted chat-agent workers by default.

Raw contract mode is designed to avoid repeated heavy-harness prefill, but no
speed claim is valid until the additive paired local benchmark is run. Claude
or Codex retains planning, dependency analysis, security review, cumulative
diff review, and final acceptance. This feature layers on the foundational worker orchestration documented in
[DELEGATE-CODER-000](../DELEGATE-CODER-000-worker-orchestration/README.md); the
default `read`/`exec` adapters and benchmark policy are recorded there.
The resilience follow-up in PR #6 is documented separately as
[DELEGATE-CODER-002](../DELEGATE-CODER-002-resilient-contracts/README.md).

| | |
|---|---|
| **Feature** | DELEGATE-CODER-001 — contract-driven local Qwen worker |
| **Status** | Implemented; merge-blocking hardening covered by deterministic regression tests |
| **Repository** | `delegate-coder` — plugin marketplace plus benchmark harness |
| **Source implementation** | `f88aa20` (initial router), `0c70396` (review nits), `b620adb` (prompt preflight/privacy correction) |
| **Cross-repo work** | Not applicable; the router and its tests are contained here |

## Files in this pack

`PRD.md` · `HLD.md` · `API_CONTRACT.md` · `PLAN.md` · `TEST_PLAN.md` ·
`DECISION_LOG.md` · `RELEASE_CHECKLIST.md`

## AI-first handoff

An implementation agent should read `PRD.md`, `HLD.md`, `API_CONTRACT.md`,
`PLAN.md`, and `TEST_PLAN.md` before editing. Keep each contract bounded to one
file, use the contract router only when the file can be safely replaced in
full, and return the target-only diff plus test log to the orchestrator. The
worktree must be clean on an isolated feature/delegate branch before the first
write; exploration, architecture, authentication/security, malformed-input
boundaries, and repository-wide reasoning stay on the normal agent path.

## Current gates

- Local Ollama must be serving the selected model, normally
  `qwen3-coder:30b`.
- The router must reject an estimated oversized prompt before model eviction or
  an HTTP request; output-side `done_reason: length` remains a separate guard.
- Failed generation, verification, timeout, signal, parser, and outside-target
  exits restore the Git-visible pre-child snapshot (target bytes/mode, tracked
  and nonignored untracked outside-target files, and index entries); earlier
  accepted batch children remain on the isolated branch.
- Successful changed contracts restore the pre-child Git index before
  acceptance, leaving accepted target changes unstaged. Index restoration
  failure is reported as `FAIL`.
- Contract setup keeps `.claude/delegate-coder.log` available to `/delegate
  stats` while ignoring only that file through `.git/info/exclude`, without a
  tracked consumer-worktree edit. Only the exact marked legacy delegate-coder
  stanza may be migrated; unmarked broad rules fail safely with remediation.
- Dispatcher and direct-router preflight validate all batch target paths and
  configured positive numeric limits before creating `delegate/contract-*`.
- Contract-router tests must pass, including retry, timeout, truncation,
  no-op, new-file, transactional rollback for tracked/untracked outside files,
  strict structured output, ordered batch stop-on-failure, pre-branch
  validation, consumer audit-log isolation, proxy, positive-limit, non-Git,
  and path-boundary cases.
- The additive local benchmark must use five warm repetitions and never write
  the frozen v1 `benchmark/RESULTS.md` or `benchmark/raw_data.jsonl`.
- The frozen v1 benchmark must remain unchanged. Any benchmark-impacting
  default-path change requires a separately labeled dataset *(confirm owner and
  process)*.
- `python3 benchmark/report.py benchmark/raw_data.jsonl benchmark/full_tasks.json`
  reproduces the frozen aggregate; deterministic reporter and no-live-model
  runner tests cover the additive benchmark path.
- Historical decisions in `DECISION_LOG.md` are backfilled from commit history;
  they document intent and require maintainer confirmation where marked.
