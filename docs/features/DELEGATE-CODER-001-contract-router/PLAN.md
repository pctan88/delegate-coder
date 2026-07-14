---
repo: delegate-coder
feature: DELEGATE-CODER-001
status: implemented
last_synced: 2026-07-14
---

# Implementation plan: Contract-driven local Qwen worker

## Source of truth

Read `PRD.md`, `HLD.md`, `API_CONTRACT.md`, and `TEST_PLAN.md` before making
changes. The initial implementation landed in `f88aa20`, with review hardening
in `0c70396` and `b620adb`; this plan records the intended boundaries and
acceptance evidence for future maintenance.

## Implemented surface

- `plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh`
- `plugins/delegate-coder/skills/delegate-coder/scripts/contract-router.sh`
- `plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh`
- Related README, skill, adapter, setup, and benchmark guidance

## Ordered maintenance workflow

1. Confirm whether the requested change is contract mode, existing `read`/`exec`
   mode, or documentation only.
2. For contract mode, keep one target file per contract and preserve the input,
   output, timeout, and retry semantics in `API_CONTRACT.md`.
3. Add or update deterministic fake-Ollama tests before changing router behavior.
4. Run the contract-router test suite and `git diff --check`.
5. Review target scope, audit output, and benchmark impact. Do not overwrite
   `benchmark/RESULTS.md` or rerun the frozen v1 matrix.
6. Append a decision-log entry when behavior, safety boundaries, or benchmark
   policy changes.

## Definition of done

- Acceptance criteria in `PRD.md` are covered by tests or explicitly marked
  `(confirm)`.
- Existing adapters remain compatible.
- Reports keep stdout machine/cloud-consumable and stderr operational.
- No unrelated files or benchmark artifacts are changed.
