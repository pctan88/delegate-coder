# Test plan: resilient contract execution

## Existing evidence from PR #6

- `plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh` — 22 checks pass.
- `plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh` — all existing and new checks pass.
- `plugins/delegate-coder/tests/codex-package.test.sh` — package validation passes.

## Implemented verification cases

| Area | Case | Expected result | Status |
|---|---|---|---|
| Output | Empty/new target | Minimum budget (safety floor 4096) is applied; no silent truncation | Passed |
| Output | Configurable output budget | Enforces values >= 4096; rejects invalid values early | Passed |
| Output | Prompt plus output exceeds context | Fails before Ollama/eviction | Passed |
| Context | Valid interface file | Included in prompt and counted in budget | Passed |
| Context | Secrets denylist (`.env*`, `.npmrc`, keys, etc.) | Rejected before model contact (no curl requests made) | Passed |
| Context | Sensitive directories (`.aws/`, `.ssh/`, etc.) | Rejected before model contact (no curl requests made) | Passed |
| Context | Symlinked parent directories | Rejected before model contact (no curl requests made) | Passed |
| Context | Oversized file (> 64KB per file, > 256KB total) | Rejected before model contact (no curl requests made) | Passed |
| Context | Filename/content containing Markdown fences | Prompt remains structurally safe using dynamic fences | Passed |
| Preflight | Python, shell, JS, TS syntax failure | Fails before project tests and retries once | Passed |
| Preflight | Filename containing quotes, `$()`, spaces, or backticks | No shell expansion or `eval` execution; files remain untouched | Passed |
| Detection | Virtualenv python detection & pytest import check | Resolves interpreter (.venv, etc.) and falls back to unittest if pytest absent | Passed |
| Rollback | Preflight failure | Target, outside files, and index restore | Passed |
| Compatibility | No contract configuration | Existing agent/read/exec behavior unchanged | Passed |

## Commands

```bash
bash plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh
bash plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh
bash plugins/delegate-coder/tests/codex-package.test.sh
git diff --check
```

Do not overwrite `benchmark/RESULTS.md` or `benchmark/raw_data.jsonl`.
