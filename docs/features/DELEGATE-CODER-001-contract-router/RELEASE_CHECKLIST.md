# Release Checklist: Contract-driven local Qwen worker

## Before release

- [ ] Maintainer confirms `PRD.md` scope and the opt-in boundary.
- [ ] `API_CONTRACT.md` matches `delegate.sh` and `contract-router.sh`.
- [ ] Contract-router test suite passes.
- [ ] `git diff --check` passes and the diff contains no benchmark-result rewrite.
- [ ] Existing `read`/`exec` adapters remain available.
- [ ] README and `SKILL.md` explain one-file contracts and sequential
      decomposition for multi-file work.
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

## Benchmark and rollback

- [ ] Do not overwrite the frozen v1 benchmark dataset.
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
