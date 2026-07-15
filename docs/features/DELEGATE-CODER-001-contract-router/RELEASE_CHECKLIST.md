# Release Checklist: Contract-driven local Qwen worker

## Before release

- [ ] Maintainer confirms `PRD.md` scope and the opt-in boundary.
- [ ] `API_CONTRACT.md` matches `delegate.sh` and `contract-router.sh`.
- [ ] Contract-router test suite passes.
- [ ] `git diff --check` passes and the diff contains no benchmark-result rewrite.
- [ ] Existing `read`/`exec` adapters remain available.
- [ ] README and `SKILL.md` explain one-file contracts and sequential
      decomposition for multi-file work.
- [ ] Backend configuration defaults to `agent`; contract mode is explicitly
      opt-in and setup exposes the choice without hosted fallback.
- [ ] Contract instructions require interfaces/signatures, invariants,
      dependency ordering, forbidden changes, and an objective test.
- [ ] Local Ollama prerequisites and provider/privacy implications are documented.
- [ ] Historical decisions are reviewed; unresolved items remain `(confirm)`.

## Operational smoke test

- [ ] Run one harmless contract against a disposable fixture.
- [ ] Confirm non-selected resident models are evicted and the selected model is
      retained.
- [ ] Confirm `PASS`, `NOOP`, and failed-retry reports have expected exit codes.
- [ ] Confirm `.claude/delegate-coder.log` start/end events contain status and
      retry count.
- [ ] Confirm timeout and truncation failures leave the target safe.
- [ ] Confirm malformed output, signals, modified tracked outside files, new
      untracked outside files, tracked/new `.claude/*` files, staged target and
      outside files, and failed new-file contracts restore bytes, modes, the
      Git index, and Git-visible nonignored files safely and report `Restored`.
- [ ] Confirm successful changed contracts restore the pre-child index and
      leave accepted target changes unstaged; index restoration failure cannot
      report `PASS`.
- [ ] Confirm preflight rejects dirty `main`, malformed contracts, invalid later
      batch paths, oversized initial prompts, and zero numeric project settings
      before any `delegate/contract-*` branch or Ollama eviction is performed.
- [ ] Confirm `.claude/delegate-coder.log` is available to stats while the
      idempotent `.git/info/exclude` rule excludes only that file and keeps it
      out of consumer worktree changes; exact marked legacy migration is
      idempotent, while unmarked/user-owned broad rules remain and fail safely.

## Benchmark and rollback

- [ ] Do not overwrite the frozen v1 benchmark dataset.
- [ ] Run deterministic local benchmark reporter tests; fresh local paired
      measurements use five warm repetitions and a separate output directory.
- [ ] Reproduce frozen v1 with `python3 benchmark/report.py
      benchmark/raw_data.jsonl benchmark/full_tasks.json`; the one-run fixtures
      are not the 48-run dataset.
- [ ] If default-path behavior changes, create a new labeled benchmark dataset
      and obtain approval *(confirm process)*.
- [ ] Rollback is a Git revert of the contract-router/dispatcher/docs change;
      existing `read`/`exec` mode remains the fallback path.

## Sign-off

| Role | Name | Status | Date |
|---|---|---|---|
| Maintainer | | Pending | |
| Plugin owner | | Pending | |
| Benchmark owner | | Pending | |
