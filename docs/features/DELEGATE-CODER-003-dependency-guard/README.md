# Feature: Dependency manifest guard (DELEGATE-CODER-003)

This feature adds a package.json-specific safety check to the contract
router, driven directly by a real-world dogfood run: the 2026-08-28 Lead
Portal Angular 22 migration (see `AI/delegate-coder-qwen-findings.md` in the
older reference workspace for the original field report).

| | |
|---|---|
| **Feature** | DELEGATE-CODER-003 — dependency manifest guard |
| **Status** | Implemented, self-tested, not yet reviewed/released |
| **Repository** | `delegate-coder` — contract router |
| **Source implementation** | `contract-router.sh`, `delegate.sh`, `scripts/lib/validate_dependency_manifest.py`, `tests/contract-router.test.sh` |
| **Depends on** | [DELEGATE-CODER-002](../DELEGATE-CODER-002-resilient-contracts/README.md) (syntax preflight ordering, report/status plumbing) |

## Problem

During the Lead Portal Angular 22 migration, run through contract mode with
`qwen3-coder:30b`, the worker produced two undetected defects on
`package.json`-shaped contracts: an invalid Angular version string, and a
downgrade of `keycloak-angular` where an upgrade was intended. Neither was
caught by the existing verification (`test_command` + syntax preflight),
because neither is a syntax error — the JSON was valid, it was just wrong. A
separate follow-up test-writing contract stalled, and the existing
`TEST_FAIL` status gave no signal distinguishing a stall from an ordinary
assertion failure.

## Goals

1. Reject a candidate `package.json` whose `dependencies`/`devDependencies`/
   `peerDependencies`/`optionalDependencies` contain a version string that
   isn't a recognizable semver, before the (expensive, possibly
   network-touching) `test_command` runs.
2. Reject a silent major/minor/patch downgrade of an existing dependency,
   unless the contract explicitly opts in via `allow_downgrade`.
3. Make a verification-command timeout diagnosable as a stall, distinct in
   its hint text from an ordinary test failure, without changing its
   reported status (still `TEST_FAIL`, so existing consumers of the status
   field are unaffected).

## Non-goals

- Registry-existence checks (e.g. `npm view <pkg>@<version>`) — would add a
  network dependency the project's local-only privacy stance
  (docs/ai-first-contract-router) explicitly avoids. The guard is purely
  syntactic/comparative on the two JSON snapshots already in hand.
- Manifests other than `package.json` (no `package-lock.json`,
  `requirements.txt`, `pubspec.yaml`, etc. yet) — scoped to the stack that
  produced the failure. `MANIFEST_NAMES` in
  `scripts/lib/validate_dependency_manifest.py` is the extension point.
- Re-litigating what counts as a "downgrade" beyond simple semver-tuple
  comparison; version forms the guard can't safely parse (`workspace:`,
  `git+`, `file:`, `link:`, `*`, `latest`, `next`) are skipped rather than
  rejected, to avoid false positives.

## Acceptance criteria

- A `package.json` contract with an unparseable version for any changed
  dependency is rejected with status `DEPENDENCY_GUARD_FAIL`, the exact
  offending package named in the error, and the worktree restored — before
  `test_command` runs, and it still gets the router's existing one-shot
  correction retry with that exact error fed back.
- A `package.json` contract that downgrades an existing dependency is
  rejected the same way, unless the package name is listed in
  `allow_downgrade` (or `allow_downgrade: true` for the whole contract).
- An ordinary upgrade, or any dependency version change with no comparable
  baseline (new dependency, or an unvalidatable range form on either side),
  passes through unaffected.
- `delegate.sh`'s contract-mode audit log records `DEPENDENCY_GUARD_FAIL`
  verbatim rather than collapsing it to the generic `ERROR` status.
- A `test_command` that times out reports `TEST_FAIL` (unchanged) plus a
  hint identifying it as a stall and naming the configured timeout.
- All pre-existing suites remain green; 5 new deterministic cases added.

## Incidental fix (found while testing, not part of the above)

`ORIGINAL_MODE="$(stat -f '%Lp' ... || stat -c '%a' ...)"` tried the BSD/macOS
stat form first. On Linux, GNU `stat -f` means "filesystem status" (not
"format" — that's `-c`/`--format`), so it *succeeds* while printing an
unrelated filesystem-info block instead of erroring, and the `||` fallback to
the correct `-c '%a'` form never fires — silently breaking file-mode
preservation on Linux. This blocked a clean self-test run on the Linux
sandbox used to validate this feature and would equally affect the ubuntu
leg of the CI matrix NEXT_STEPS.md calls for. Fixed by trying `-c` first
(errors cleanly on BSD/macOS, so the fallback still works there). Same fix
applied to the two matching assertions in `contract-router.test.sh` that had
the identical ordering bug in the test harness itself.

## Self-test results (2026-08-29)

```
plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh              31/31 passed
plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh   61/61 passed (56 pre-existing + 5 new)
plugins/delegate-coder/tests/codex-package.test.sh                          passed
git diff --check                                                            clean
```

No live Ollama model was used or needed — hermetic, per the project's
existing test discipline; the fake `curl`/`ollama` fixtures in
`contract-router.test.sh` were extended with `pkg_invalid_version`,
`pkg_downgrade`, and `pkg_upgrade` modes.

## Still open before release

- Maintainer sign-off (this pack has no HLD/PLAN/TEST_PLAN/RELEASE_CHECKLIST
  yet — deliberately kept lighter than 002 pending a decision on whether this
  warrants that full ceremony or folds into 002's remaining checklist items).
- A worked example wired into a real `package.json`-touching migration
  contract, to confirm the guard's error text is actually useful feedback
  for a worker's one retry attempt (unit-tested in isolation only so far).
