# Release Checklist: Worker orchestration

## Before release

- [ ] Maintainer confirms `PRD.md` scope and that new fields default to current behavior.
- [ ] `API_CONTRACT.md` matches `delegate.sh`, the config schema, and the adapter table.
- [ ] `bash plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh` passes.
- [ ] `git diff --check` passes and the diff rewrites no benchmark result.
- [ ] `SKILL.md`, `detect.sh`, and the benchmarked `delegate.sh` invocation are
      unchanged — or a new labeled benchmark dataset is planned (never a v1 rerun).
- [ ] `references/{adapters,setup,models}.md` reflect any adapter/flag changes.
- [ ] Off-machine privacy warning fires for hosted workers during setup.
- [ ] Historical decisions reviewed; unresolved items remain `(confirm)`.

## Operational smoke test

- [ ] `detect.sh` lists installed agents; `doctor.sh --all` reports auth status.
- [ ] Delegate one trivial `read` task against a disposable repo and confirm output.
- [ ] Confirm enforcing `read` adapters cannot write; review Gemini, Qwen, and
      OpenCode as non-enforcing read paths, and confirm `exec` changes are caught
      by `git diff` + tests.
- [ ] Confirm `.claude/delegate-coder.log` start/end events and that `stats.sh` summarizes them.
- [ ] Confirm an `allow_paths` violation aborts with the expected exit code.

## Benchmark and rollback

- [ ] Do not overwrite the frozen v1 benchmark dataset.
- [ ] If the default path changes, create a new labeled dataset and obtain
      approval *(confirm process)*.
- [ ] Rollback is a Git revert of the offending change; an unconfigured project
      falls back to the benchmarked default behavior.

## Sign-off

| Role | Name | Status | Date |
|---|---|---|---|
| Maintainer | | Pending | |
| Plugin owner | | Pending | |
| Benchmark owner | | Pending | |
