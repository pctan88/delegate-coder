# Test plan: resilient contract execution

## Existing evidence from PR #6

- `plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh` — 22 checks
  pass.
- `plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh`
  — all existing and PR #6 checks pass.
- `plugins/delegate-coder/tests/codex-package.test.sh` — package validation
  passes.

## Required regression cases

| Area | Case | Expected result |
|---|---|---|
| Output | Empty/new target | Minimum budget is applied; no silent truncation |
| Output | Prompt plus output exceeds context | Fails before Ollama/eviction |
| Context | Valid interface file | Included in prompt and counted in budget |
| Context | `.env`, private key, credentials, secret store | Rejected before model contact |
| Context | Oversized file | Rejected with a remediation message |
| Context | Filename/content containing Markdown fences | Prompt remains structurally safe |
| Preflight | Python, shell, JavaScript, TypeScript syntax failure | Fails before project tests and retries once |
| Preflight | Filename containing quotes, `$()`, spaces, or backticks | No shell expansion; file remains untouched |
| Detection | `.venv` with unittest but no pytest | Uses the working project interpreter and unittest |
| Rollback | Preflight failure | Target, outside files, and index restore |
| Compatibility | No contract configuration | Existing agent/read/exec behavior unchanged |

## Commands

```bash
bash plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh
bash plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh
bash plugins/delegate-coder/tests/codex-package.test.sh
git diff --check
```

Do not overwrite `benchmark/RESULTS.md` or `benchmark/raw_data.jsonl`.
