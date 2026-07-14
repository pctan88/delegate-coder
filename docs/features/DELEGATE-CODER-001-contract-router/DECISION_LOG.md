# Decision Log: Contract-driven local Qwen worker

Append-only. This log was backfilled on 2026-07-14 from the repository history,
especially commits `626406b`, `89e4935`, `630774a`, `b0ad6f6`, and `f88aa20`.
The entries describe intent inferred from commit messages and surrounding docs;
ownership and any policy marked `(confirm)` still require maintainer validation.

| # | Date | Decision | Context / why | Alternatives considered | Consequence | Owner |
|---|---|---|---|---|---|---|
| 1 | 2026-06-15 | **Backfilled:** package the project as the `tan-tools` Claude Code plugin marketplace | `626406b` established the marketplace/plugin layout and public install path | Keep a flat standalone skill; publish only scripts | Plugin manifests and install guidance become canonical integration points | Maintainer *(confirm)* |
| 2 | 2026-06-17 | **Backfilled:** keep the v1 benchmark dataset frozen and make v2 controls opt-in | `89e4935` and `ROADMAP.md` prioritize byte-identical default behavior and honest comparison | Rerun v1 with every enhancement; change defaults immediately | New behavior needs separate evidence; `benchmark/RESULTS.md` remains historical truth | Benchmark owner *(confirm)* |
| 3 | 2026-06-17 | **Backfilled:** add audit logging, stats, model selection, scope/fallback controls, and path allowlisting around the stable adapter | `630774a` and `b0ad6f6` added operational control and reproducibility features | Depend only on worker summaries; use unrestricted execution by default | Delegation can be measured and constrained without changing the core trust model | Plugin owner *(confirm)* |
| 4 | 2026-07-14 | **Backfilled:** add an opt-in contract mode using raw Ollama generation and full-file replacement | `f88aa20` adds `contract-router.sh`, dispatcher support, and focused tests to reduce chat-loop/prefill overhead | Continue multi-turn chat mode; perform targeted search/replace; trust summaries | A cloud orchestrator can send a low-token, single-file execution unit with deterministic output | Maintainer *(confirm)* |
| 5 | 2026-07-14 | **Backfilled:** make safety gates part of the router contract | `f88aa20` tests path guards, atomic writes, truncation rejection, bounded timeouts, one retry, and `NOOP` | Write any model output; retry indefinitely; allow unbounded commands | Incorrect or incomplete worker output is blocked or made visible before handoff | Plugin owner *(confirm)* |
| 6 | 2026-07-14 | **Proposed:** keep contract mode separate from the benchmarked `read`/`exec` path | The new mode is explicitly invoked as `delegate.sh contract`; existing benchmark policy forbids accidental dataset mutation | Replace the existing adapter path with the local model | Easier rollout and clearer benchmark accounting; new mode still needs its own measurements | Maintainer / benchmark owner *(confirm)* |
