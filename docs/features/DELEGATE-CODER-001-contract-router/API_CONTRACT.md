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
sequentially in the current working tree and produce one aggregate report.

### Field semantics

| Field | Required | Semantics |
|---|---:|---|
| `target_file` | yes | Existing regular file, or new file whose parent exists; repository-relative and non-symlink |
| `instructions` | yes | Functional edit request sent to the local worker |
| `test_command` | yes | Shell command run from the repository root after generation |

Malformed JSON may use the deliberately limited field-extraction fallback. A
valid JSON object is the supported protocol and should be preferred.

## Ollama request

Before the request is sent, the router estimates the prompt size
(`system` + `target_file` + `instructions` + current file contents, ~3 bytes per
token). If that estimate exceeds `num_ctx`, the contract is rejected up front with
a non-zero exit and no request or file write, so an oversized file cannot be
silently prompt-truncated.

The router then sends `POST {OLLAMA_HOST}/api/generate` with `stream: false`, the
configured model, compiler system prompt, `options.num_ctx`, and `keep_alive`.
The model response must contain a non-empty `response`; the first fenced block
is used when present. `done_reason: length` (output-side truncation) is a hard
failure and never writes a file.

## Output

Stdout is a markdown report. Progress and operational errors go to stderr.

```markdown
# Contract Result

- Status: PASS | NOOP | FAIL
- Retries: 0 or 1
- Target: `relative/path`

## Git diff
...

## Final test log
...
```

Exit status is zero for `PASS` and `NOOP`, non-zero for `FAIL` or setup/
generation errors. A batch report aggregates child reports and retries.

## Environment defaults

| Variable | Default |
|---|---|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` |
| `DELEGATE_MODEL` | `qwen3-coder:30b` |
| `DELEGATE_NUM_CTX` | `32768` |
| `DELEGATE_KEEP_ALIVE` | `30m` |
| `DELEGATE_CURL_TIMEOUT` | `600` seconds |
| `DELEGATE_TEST_TIMEOUT` | `300` seconds |

## Audit event

`delegate.sh` appends JSON start/end events containing agent, model, mode,
duration, exit code, status, and retries. This is local operational telemetry,
not a durable task database.
