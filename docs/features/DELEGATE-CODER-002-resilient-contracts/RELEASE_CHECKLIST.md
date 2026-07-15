# Release checklist: resilient contract execution

## Documentation and ownership

- [x] PR #6 implementation is linked from this pack.
- [x] Parent 000/001 decision logs contain correction links and no new 002
      behavior is documented as belonging to them.
- [ ] Maintainer confirms the contract boundary and local-privacy policy.

## Safety gates

- [x] `context_files` reject secret-like paths and oversized files before model
      contact.
- [x] Syntax preflight uses direct argument execution; no `eval` remains on
      repository-derived paths.
- [x] Test detection selects and verifies the active project interpreter.
- [x] Failed preflight, generation, timeout, and verification restore the full
      Git-visible child state and index.

## Verification

- [x] Core shell suite passes.
- [x] Contract-router suite passes, including the new security regressions.
- [x] Codex package validation passes.
- [x] `git diff --check` passes.
- [x] Frozen v1 benchmark artifacts are unchanged.
- [x] Any new performance numbers use a separately named additive dataset.

## Sign-off

| Role | Name | Status | Date |
|---|---|---|---|
| Maintainer | | Pending | |
| Plugin owner | | Pending | |
| Benchmark owner | | Pending | |
