# Feature: Contract-driven local Qwen worker (DELEGATE-CODER-001)

Turn `delegate-coder` into a strict local execution harness for bounded,
single-file edits while keeping Claude/Codex/other cloud orchestrators in the
planning and acceptance role.

Execution runs entirely against a local Ollama model, so code never leaves the
machine — the privacy-safe path for confidential work, unlike hosted chat-agent
workers.

This feature layers on the foundational worker orchestration documented in
[DELEGATE-CODER-000](../DELEGATE-CODER-000-worker-orchestration/README.md); the
default `read`/`exec` adapters and benchmark policy are recorded there.

| | |
|---|---|
| **Feature** | DELEGATE-CODER-001 — contract-driven local Qwen worker |
| **Status** | Implemented in `f88aa20`; documentation and acceptance tracking backfilled |
| **Repository** | `delegate-coder` — plugin marketplace plus benchmark harness |
| **Source implementation** | `f88aa20` — Add contract-driven local Ollama router, 2026-07-14 |
| **Cross-repo work** | Not applicable; the router and its tests are contained here |

## Files in this pack

`PRD.md` · `HLD.md` · `API_CONTRACT.md` · `PLAN.md` · `TEST_PLAN.md` ·
`DECISION_LOG.md` · `RELEASE_CHECKLIST.md`

## AI-first handoff

An implementation agent should read `PRD.md`, `HLD.md`, `API_CONTRACT.md`,
`PLAN.md`, and `TEST_PLAN.md` before editing. Keep each contract bounded to one
file, use the contract router only when the file can be safely replaced in
full, and return the target-only diff plus test log to the orchestrator.

## Current gates

- Local Ollama must be serving the selected model, normally
  `qwen3-coder:30b`.
- Contract-router tests must pass, including retry, timeout, truncation,
  no-op, new-file, batch, and path-boundary cases.
- The frozen v1 benchmark must remain unchanged. Any benchmark-impacting
  default-path change requires a separately labeled dataset *(confirm owner and
  process)*.
- Historical decisions in `DECISION_LOG.md` are backfilled from commit history;
  they document intent and require maintainer confirmation where marked.
