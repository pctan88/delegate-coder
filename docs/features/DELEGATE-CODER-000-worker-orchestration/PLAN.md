---
repo: delegate-coder
feature: DELEGATE-CODER-000
status: shipped
last_synced: 2026-07-14
---

# Implementation plan: Worker orchestration + plugin marketplace

## Source of truth

Read `PRD.md`, `HLD.md`, `API_CONTRACT.md`, and `TEST_PLAN.md` before changing
orchestration behavior. This feature shipped across `626406b`, `89e4935`,
`630774a`, `b0ad6f6`, and the read-policy correction in `c698526`; the plan
records the intended boundaries and the acceptance evidence for future
maintenance.

## Implemented surface

- `.claude-plugin/marketplace.json`, `plugins/delegate-coder/.claude-plugin/plugin.json`
- `plugins/delegate-coder/skills/delegate-coder/SKILL.md`
- `plugins/delegate-coder/skills/delegate-coder/scripts/{delegate,detect,detect-test,doctor,stats}.sh`
- `plugins/delegate-coder/skills/delegate-coder/references/{adapters,setup,models}.md`
- `plugins/delegate-coder/commands/delegate-{setup,doctor,model,scope,stats,on,off}.md`
- `benchmark/` harness plus the frozen v1 dataset
- `plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh` — deterministic tests for `delegate.sh` and `detect-test.sh`

## Ordered maintenance workflow

1. Classify the change: default delegated path, human-invoked control surface,
   or documentation only.
2. If it touches `SKILL.md`, `detect.sh`, or the benchmarked `delegate.sh`
   invocation, treat it as benchmark-impacting (see `TEST_PLAN.md`).
3. Keep every new config field optional and defaulted to current behavior.
4. Add or update deterministic tests (fake worker on `PATH`, temp fixtures)
   before changing script behavior.
5. Run `bash plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh` and
   `git diff --check`; inspect diff scope.
6. Do not overwrite `benchmark/RESULTS.md` or rerun the frozen v1 matrix.
7. Append a `DECISION_LOG.md` entry when behavior, safety boundaries, adapters,
   or benchmark policy change.

## Definition of done

- Acceptance criteria in `PRD.md` are covered by tests or explicitly marked
  `(confirm)`.
- Unconfigured projects reproduce the benchmarked default path.
- The audit log stays machine-readable and `stats.sh` still parses it.
- No unrelated files or benchmark artifacts are changed.
