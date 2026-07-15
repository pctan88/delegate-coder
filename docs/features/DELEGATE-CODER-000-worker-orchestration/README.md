# Feature: Worker orchestration + plugin marketplace (DELEGATE-CODER-000)

The foundational `delegate-coder` product: a Claude Code plugin marketplace
(`tan-tools`) whose skill keeps Claude in the planner/reviewer role and hands
execution-heavy work — bulk reading, routine implementation, refactors,
first-pass review — to a cheaper local or hosted CLI worker agent.

This pack is the AI-first record for everything that shipped before the
contract router. The contract router is documented separately as
[DELEGATE-CODER-001](../DELEGATE-CODER-001-contract-router/README.md) and builds
on top of the `read`/`exec` orchestration described here.

| | |
|---|---|
| **Feature** | DELEGATE-CODER-000 — worker orchestration, config surface, benchmark harness |
| **Status** | Shipped (`v0.2.0`–`v0.2.2`); documentation backfilled 2026-07-14 |
| **Repository** | `delegate-coder` — marketplace + plugin + benchmark harness |
| **Source implementation** | `626406b` (v0.2.0), `89e4935` (marketplace), `630774a` (v0.2.1), `b0ad6f6` (v0.2.2), `c698526` (read-policy correction) |
| **Cross-repo work** | Not applicable; the plugin and harness are contained here |

## Files in this pack

`PRD.md` · `HLD.md` · `API_CONTRACT.md` · `PLAN.md` · `TEST_PLAN.md` ·
`DECISION_LOG.md` · `RELEASE_CHECKLIST.md`

## AI-first handoff

An agent changing orchestration behavior should read `PRD.md`, `HLD.md`,
`API_CONTRACT.md`, `PLAN.md`, and `TEST_PLAN.md` first. The routing policy lives
in `SKILL.md`; the machine-facing contract (config schema, adapter invocations,
audit-log format, exit codes) is in `API_CONTRACT.md`. Treat worker summaries as
claims, not proof — the target diff and the project test command are the
evidence.

## Current gates

- The default headless delegation path (`SKILL.md`, `detect.sh`, and the
  benchmarked `delegate.sh` invocation) is benchmark-impacting. Changing it
  requires a new, separately labeled benchmark dataset — never a rerun of the
  frozen v1 matrix in `benchmark/RESULTS.md`.
- Every new config field must default to the current behavior when absent, so an
  unconfigured project runs exactly as the benchmarked version.
- Worker output for `exec` tasks must be verified with `git diff` plus the
  project test command before it is trusted.
- Hosted workers send code off-machine; the off-machine privacy warning must
  fire during setup for those agents.
