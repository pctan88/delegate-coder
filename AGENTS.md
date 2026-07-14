# delegate-coder AI-first project guide

delegate-coder is a Claude Code plugin marketplace and benchmark harness. The
canonical planning and delivery record for the contract-router work is the
feature pack at:

`docs/features/DELEGATE-CODER-001-contract-router/`

## AI-first workflow

Before changing implementation, read the feature pack's `README.md`, `PRD.md`,
`HLD.md`, `API_CONTRACT.md`, `PLAN.md`, and `TEST_PLAN.md`. Treat the plan as
the implementation contract and update `DECISION_LOG.md` when a design choice
changes.

Keep work bounded and reviewable:

- One contract-router contract targets one file. A multi-file change is split
  into sequential contracts or handled as an explicitly reviewed chat-agent
  task.
- Preserve the frozen v1 benchmark result and methodology. Do not rerun the
  benchmark with the current v2/contract-router code path unless a new dataset
  is explicitly requested.
- Keep the default `read`/`exec` adapter behavior stable unless the PRD and
  benchmark impact are updated first.
- Verify changes with the smallest deterministic test command in `TEST_PLAN.md`,
  then run `git diff --check` and inspect the scope of the diff.
- Do not treat worker summaries as proof. The target diff, test output, and
  audit log are the evidence.

## Documentation conventions

- Use `HLD.md` for high-level design; “HLD” is the canonical name.
- Mark facts that need external confirmation with `(confirm)`.
- Keep `DECISION_LOG.md` append-only. Historical entries must cite the source
  commit and say when they are inferred or backfilled.
- `CROSS_REPO_PLAN.md` is intentionally omitted because this feature is
  contained in this repository.
