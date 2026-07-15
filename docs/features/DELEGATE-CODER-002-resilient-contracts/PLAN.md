---
repo: delegate-coder
feature: DELEGATE-CODER-002
status: in_review
last_synced: 2026-07-15
---

# Implementation plan: resilient contract execution

## Source of truth

Read `PRD.md`, `HLD.md`, `API_CONTRACT.md`, and `TEST_PLAN.md` before editing
the router or dispatcher. DELEGATE-CODER-001 remains the parent contract and
rollback specification.

## PR #6 delivered

- Minimum 4096-token output budget for empty/small targets.
- Bash invocation of internal scripts to tolerate lost executable bits.
- pytest availability check with unittest fallback.
- Repository-relative `context_files` validation and prompt injection.
- Syntax preflight before the project test command.
- Deterministic regression coverage for the above behavior.

## Required corrective work before release

1. Replace `eval`-built preflight commands with direct argument execution and
   add a filename-metacharacter regression test.
2. Add secret-path and maximum-byte validation for `context_files`; add tests
   proving `.env`, key files, and oversized references are rejected before
   Ollama contact.
3. Detect the project interpreter (`.venv/bin/python`, `python`, or `python3`)
   and verify the selected runner in the active environment.
4. Add a context prompt-budget regression with a large reference file.
5. Run the full shell suites, deterministic benchmark reporter tests, and
   `git diff --check`.
6. Obtain maintainer and benchmark-owner sign-off; do not alter frozen v1
   benchmark artifacts.

## Definition of done

- All PR #6 behavior is documented in this pack, not in parent feature packs.
- The security and command-construction blockers are fixed and tested.
- Existing adapters and contract rollback semantics remain compatible.
- A new additive benchmark records reliability and latency; no historical
  result is overwritten.
