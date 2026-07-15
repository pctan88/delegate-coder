# Test Plan: Contract-driven local Qwen worker

**Last updated:** 2026-07-14

## Must-pass cases

The primary suite is:

```bash
bash plugins/delegate-coder/skills/delegate-coder/tests/contract-router.test.sh
```

It must cover:

| Case | Expected result |
|---|---|
| Valid JSON contract | Generates, tests, reports `PASS`, preserves clean stdout |
| Structured UTF-8 transport | Preserves nested Markdown fences and source triple backticks apart from one newline |
| Malformed/empty/additional output | Rejects strict structured-output violations without writing |
| Stdin contract | Accepts the same schema from stdin |
| Model/context/keep-alive propagation | Request contains configured values |
| GPU preparation | Stops non-selected resident model and keeps selected model |
| Newline sweep | Written file has exactly one trailing newline |
| Regex fallback | Damaged wrapper is parsed for the three required fields |
| Failed verification | Exactly one correction request includes exact failure output |
| Passing unchanged output | Reports `NOOP` |
| Input prompt-size guard | Rejects before branch creation, Ollama eviction, request creation, or target replacement |
| Second verification failure | Reports `FAIL` and makes no third request |
| Transactional rollback | Restores existing bytes/mode, tracked `.claude/*`, modified tracked outside files, new nonignored outside files, and the Git index; ignores dependency trees; preserves earlier accepted batch children; and reports `Restored` |
| Successful index preservation | A passing staged target remains accepted but unstaged; sequential successful children each begin from the correct restored index baseline |
| Truncated model response | Rejects `done_reason=length` without overwriting target |
| New-file target | Creates a file when its existing parent is inside the repo |
| Ordered batch | Runs 12 ordered fixtures (and supports 100+), reports counts, and stops after first failure without later requests |
| Test timeout | Bounds the command and still applies the one-retry rule |
| Traversal target | Rejects before Ollama is contacted |
| Positive limits/proxy | Rejects zero values; asserts loopback `--noproxy` and remote proxy preservation |
| Non-Git/dirty worktree | Rejects before Ollama is contacted |
| Pre-branch validation | Dirty `main` and malformed contracts fail without creating `delegate/contract-*` |
| Batch/config preflight | Invalid later batch paths and zero numeric config limits fail without creating `delegate/contract-*` |
| Consumer audit log | Only `/.claude/delegate-coder.log` is excluded; exact marked legacy migration is idempotent; unmarked and mixed user-owned `/.claude/` rules are preserved and fail preflight |

## Regression checks

Run the existing shell/script checks relevant to a release, then inspect:

```bash
git diff --check
git diff --stat
```

The v1 benchmark result remains a frozen artifact. Do not run the full benchmark
against the current router without creating a new, separately named dataset and
obtaining maintainer approval *(confirm process)*.

Deterministic benchmark checks also include:

```bash
bash benchmark/test_run_local_contract.sh
python3 benchmark/test_report.py
python3 benchmark/report.py benchmark/raw_data.jsonl benchmark/full_tasks.json
```

## Manual checks

- Point `OLLAMA_HOST` at a local server and run one harmless fixture contract.
- Confirm `PASS`, `NOOP`, and `FAIL` exit codes from a shell caller.
- Confirm `.claude/delegate-coder.log` receives contract start/end events and
  that `/delegate stats` can summarize them.
- Try a large fixture and confirm a context-length rejection leaves the source
  unchanged.

## Negative/security checks

Reject absolute paths, `..` traversal, outside-repository resolution, symlinks,
non-regular targets, missing parent directories, malformed required fields,
invalid numeric timeout/context settings, non-Git roots, dirty worktrees, and
outside-target changes. Treat `test_command` as trusted local
code; the router does not sandbox arbitrary shell commands.
