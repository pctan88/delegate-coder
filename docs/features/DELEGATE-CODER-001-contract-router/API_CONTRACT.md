# API Contract: Local Task Contract router

**Feature:** DELEGATE-CODER-001  ·  **Status:** Implemented contract, pending
maintainer sign-off  ·  **Last updated:** 2026-07-14

## Input

The dispatcher accepts JSON as the second argument or on stdin. A single
contract is an object with exactly these required string fields:

```json
{
  "target_file": "relative/path/to/file.ts",
  "instructions": "Specific functional change or removal goal.",
  "test_command": "npm test -- --runInBand relative/path/to/file.spec.ts"
}
```

The top-level value may also be an array of contract objects. Items run
sequentially in exact JSON-array order, stop after the first failed child, and
produce one aggregate report with completed, failed, and skipped counts.
Batch parsing requires `python3`; without it, an array is rejected rather than
being misread by the single-contract fallback parser.

### Field semantics

| Field | Required | Semantics |
|---|---:|---|
| `target_file` | yes | Existing regular file, or new file whose parent exists; repository-relative and non-symlink |
| `instructions` | yes | Functional request including external interfaces/signatures, invariants, dependency ordering, forbidden changes, and relevant context |
| `test_command` | yes | Shell command run from the repository root after generation |

Malformed JSON may use the deliberately limited field-extraction fallback. A
valid JSON object is the supported protocol and should be preferred. Shape,
Git-worktree, cleanliness, every batch-child path, timeout-runner, and
context-budget checks are performed before the dispatcher creates an isolation
branch whenever possible. Project-configured contract numeric limits are also
resolved and validated before branch creation.

## Ollama request

Before the request is sent, the router estimates the complete prompt size
(`system` + labels + `target_file` + `instructions` + current file contents, and
retry failure output when correcting; ~3 bytes per token). If that estimate
exceeds `num_ctx`, the contract is rejected up front with a non-zero exit and no
request or file write, so an oversized file cannot be silently prompt-truncated.

The router then sends `POST {OLLAMA_HOST}/api/generate` with `stream: false`, the
configured model, compiler system prompt, `options.num_ctx`, `temperature: 0`,
bounded `num_predict`, and `keep_alive`. The response must be JSON with exactly
one non-empty string field, `updated_file`; malformed, additional, or empty
fields fail. Markdown and source triple-backtick fences are preserved as file
content. `done_reason: length` is a hard failure and never accepts a file.

## Output

Stdout is a markdown report. Progress and operational errors go to stderr.

```markdown
# Contract Result

- Status: PASS | NOOP | FAIL
- Retries: 0 or 1
- Target: `relative/path`
- Branch: isolated feature/delegate branch
- Restored: `true | false`
- Candidate accepted: `true | false`
- Ollama metrics: `total_duration`, `load_duration`, `prompt_eval_count`, `prompt_eval_duration`, `eval_count`, `eval_duration`

## Git diff
...

## Final test log
...
```

Exit status is zero for `PASS` and `NOOP`, non-zero for `FAIL` or setup/
generation errors. A batch report is `PASS` when every child is `PASS` or
`NOOP`, otherwise `FAIL`; it reports completed, failed, and skipped counts and
its retry count is the sum of child retries. The diff compares the pre-contract
target snapshot to the accepted candidate, not to `HEAD`; outside-target changes
fail. On an unsuccessful child, the target's original existence/bytes/mode and
the child's full eligible worktree snapshot are restored. New outside-target
untracked files are removed. A successful earlier child in a batch is included
in the next child's baseline and is preserved when a later child fails.

## Environment defaults

| Variable | Default |
|---|---|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` |
| `DELEGATE_MODEL` | `qwen3-coder:30b` |
| `DELEGATE_NUM_CTX` | `32768` |
| `DELEGATE_KEEP_ALIVE` | `30m` |
| `DELEGATE_CURL_TIMEOUT` | `600` seconds |
| `DELEGATE_TEST_TIMEOUT` | `300` seconds |

All numeric limits are strictly positive. Verification must use `timeout`,
`gtimeout`, `perl`, or another bounded mechanism; unbounded tests are not run.
Loopback hosts force curl proxy bypass with `--noproxy '*'`; explicitly remote
hosts retain normal proxy behavior and are a privacy boundary.

The no-off-machine privacy claim applies only when `OLLAMA_HOST` remains at its
default loopback value. The router intentionally permits an `OLLAMA_HOST`
override; when it points to another machine or service, prompt contents are sent
there and that endpoint's privacy policy applies.

## Audit event

`delegate.sh` appends valid JSON start/end events containing agent, model, mode,
duration, exit code, status, retries, restoration state, branch, errors, and
all six Ollama metrics. This is local operational telemetry, not a durable task
database. Contract setup ensures `.claude/delegate-coder.log` is ignored via
`.git/info/exclude`; it does not edit a tracked consumer ignore file.
