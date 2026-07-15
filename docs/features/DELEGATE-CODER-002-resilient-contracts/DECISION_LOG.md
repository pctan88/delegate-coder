# Decision log: resilient contract execution

Append-only. This log is the canonical record for PR #6 behavior. Parent-pack
decision logs retain their historical entries but must link here when a
decision belongs to this feature.

| # | Date | Decision | Context / why | Consequence | Owner |
|---|---|---|---|---|---|
| 1 | 2026-07-15 | **Implemented in PR #6:** use a minimum output budget for new/small targets | Empty targets were estimated at 512 output tokens and could truncate | Small-file contracts get a bounded minimum while the context guard remains authoritative | Plugin owner *(confirm)* |
| 2 | 2026-07-15 | **Implemented in PR #6:** allow explicit read-only context files | Single-file workers need neighboring interfaces to implement bounded targets | Context is injected as labeled reference material and counted in prompt size | Plugin owner *(confirm)* |
| 3 | 2026-07-15 | **Implemented in PR #6:** run syntax preflight before project tests | Syntax failures waste the full test timeout and obscure the correction signal | Cheap compiler checks fail fast and feed the one-retry path | Plugin owner *(confirm)* |
| 4 | 2026-07-15 | **Open blocker:** context references require secret-path and size guards | Current validation accepts `.env`-like files and has no explicit per-file byte cap | Release cannot claim safe context handling until the denylist and tests land | Maintainer *(confirm)* |
| 5 | 2026-07-15 | **Open blocker:** preflight must not use `eval` | Interpolating repository filenames into `eval` creates a shell-injection boundary | Replace with direct argument execution and add metacharacter tests | Plugin owner *(confirm)* |
| 6 | 2026-07-15 | **Correction:** PR #6 behavior belongs to DELEGATE-CODER-002, not the 000/001 packs | Parent logs were append-only backfills and received misplaced rows during PR preparation | This pack is the canonical source; parent logs should point here without deleting history | Maintainer *(confirm)* |
