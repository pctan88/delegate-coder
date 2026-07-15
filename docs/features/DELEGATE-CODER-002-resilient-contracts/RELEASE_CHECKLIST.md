# Release checklist: resilient contract execution

## Documentation and ownership

- [ ] PR #6 implementation is linked from this pack.
- [ ] Parent 000/001 decision logs contain correction links and no new 002
      behavior is documented as belonging to them.
- [ ] Maintainer confirms the contract boundary and local-privacy policy.

## Safety gates

- [ ] `context_files` reject secret-like paths and oversized files before model
      contact.
- [ ] Syntax preflight uses direct argument execution; no `eval` remains on
      repository-derived paths.
- [ ] Test detection selects and verifies the active project interpreter.
- [ ] Failed preflight, generation, timeout, and verification restore the full
      Git-visible child state and index.

## Verification

- [ ] Core shell suite passes.
- [ ] Contract-router suite passes, including the new security regressions.
- [ ] Codex package validation passes.
- [ ] `git diff --check` passes.
- [ ] Frozen v1 benchmark artifacts are unchanged.
- [ ] Any new performance numbers use a separately named additive dataset.

## Sign-off

| Role | Name | Status | Date |
|---|---|---|---|
| Maintainer | | Pending | |
| Plugin owner | | Pending | |
| Benchmark owner | | Pending | |
