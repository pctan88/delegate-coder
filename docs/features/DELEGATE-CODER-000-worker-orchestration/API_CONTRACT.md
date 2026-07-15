# API Contract: Worker orchestration

**Feature:** DELEGATE-CODER-000  ·  **Status:** Shipped, sign-off pending  ·
**Last updated:** 2026-07-14

## `delegate.sh` invocation

```bash
bash scripts/delegate.sh <read|exec> "<task spec>"
```

- Argument 1 is the mode; only `read` and `exec` are valid.
- Argument 2 is the full task spec passed to the worker.
- The worker is resolved from `DELEGATE_AGENT`, else the `agent` field in
  `.delegate-coder/config.json`, falling back to the legacy
  `.claude/delegate-coder.json`.

### Exit codes

| Code | Meaning |
|---:|---|
| 0 | Worker ran and returned success |
| worker's code | Non-zero worker exit is propagated |
| 2 | Missing/empty mode or task, or mode not `read`/`exec` |
| 3 | No worker agent configured (lists installed candidates on stderr) |
| 4 | Configured agent not on `PATH` (critical under `fallback: strict`) |
| 5 | No built-in adapter for the configured agent and no `command_override` |
| 6 | `exec` worker modified a file outside `allow_paths` |

Progress and warnings go to stderr; worker output goes to stdout.

## Config schema — `.delegate-coder/config.json`

Existing `.claude/delegate-coder.json` files use the same schema and are read
only when the neutral config is absent.

Every field is optional; an absent field uses the current default behavior, so
an empty or missing file reproduces the benchmarked default path.

```jsonc
{
  "agent": "mimo",                 // mimo|aider|codex|gemini|qwen|opencode|custom
  "model": "",                     // per-agent model; threaded as --model (or -m for gemini/qwen)
  "test_command": "npm test",      // project verify command, run after each exec
  "enabled": true,                 // master switch (orchestrator-enforced via SKILL.md)
  "scope": "all",                  // all|read_only|exec_only|off (orchestrator-enforced)
  "fallback": "graceful",          // graceful (daily) | strict (benchmark; no native fallback)
  "allow_paths": ["lib/", "tests/"], // exec worker may only touch these prefixes (needs jq)
  "command_override": {            // full shell per mode; {task} is substituted
    "read": "",
    "exec": ""
  },
  "max_files_before_full_diff_review": 5,
  "implementation_backend": "agent", // agent (default) | contract (opt-in)
  "contract": {
    "model": "qwen3-coder:30b",
    "num_ctx": 32768,
    "keep_alive": "30m",
    "curl_timeout": 600,
    "test_timeout": 300
  }
}
```

- `enabled` and `scope` are honored by the orchestrator (per `SKILL.md`), not by
  `delegate.sh`; `off` or `enabled:false` means do the work natively.
- `fallback`, `allow_paths`, `command_override`, `agent`, and `model` are read
  and enforced by `delegate.sh`.
- `DELEGATE_AGENT` overrides the `agent` field. `DELEGATE_PATH_EXTRA` prepends
  directories to `PATH` for agent discovery.
- `implementation_backend` is optional and defaults to `agent`, preserving
  existing `read`/`exec`. `contract` applies only to JSON `exec` Task Contracts;
  it requires a clean isolated branch and never silently falls back to a hosted
  worker. Contract instructions must include interfaces/signatures, invariants,
  dependency ordering, forbidden changes, and the exact objective test.
- Contract numeric limits must be strictly positive. See the DELEGATE-CODER-001
  API contract for transactional and structured-output semantics.

## Local contract dispatch

```bash
bash plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh contract '<json contract>'
```

The default backend remains the normal agent adapter. Cloud orchestrators use
contract mode only for bounded one-file implementation, decompose ordered
multi-file work into sequential contracts, and retain architecture, security,
cumulative-diff, and full-repository verification responsibility.

## Built-in adapters

For each agent, `read` uses the available read-only or dry-run control, while
`exec` uses a change-making invocation. `model`, when set, is threaded into the
per-agent flag. Read-only enforcement is adapter-specific: Gemini, Qwen, and
OpenCode currently have no enforced read-only control, so their `read` mode must
not be treated as a zero-write guarantee.

| Agent | `read` | `exec` |
|---|---|---|
| `mimo` | `mimo run <task> --agent plan …` (600s timeout) | `mimo run <task> …` (600s timeout) |
| `aider` | `aider --message <task> --yes --dry-run` | `aider --message <task> --yes` |
| `codex` | `codex exec <task> --sandbox read-only` | `codex exec <task> --sandbox workspace-write` |
| `gemini` / `qwen` | `<agent> -p <task>` (no enforced read-only control) | `<agent> -p <task> --yolo` |
| `opencode` | `opencode run <task>` (no enforced read-only control) | `opencode run <task>` |
| `custom` | requires `command_override.read` | requires `command_override.exec` |

All invocations redirect stdin from `/dev/null` so a headless worker cannot hang
waiting on EOF. Flags drift between agent versions; `command_override` and
`references/adapters.md` are the escape hatch.

## Audit event — `.claude/delegate-coder.log`

One JSON object per line. A logging failure never aborts the delegation.

```json
{"ts":"2026-07-14T10:00:00Z","agent":"mimo","model":"","mode":"exec","event":"start"}
{"ts":"2026-07-14T10:01:12Z","agent":"mimo","model":"","mode":"exec","event":"end","duration_s":72,"exit_code":0}
```

`stats.sh [logfile]` summarizes counts, success/fail, and average duration per
agent+mode; it requires `jq` and tolerates legacy pre-v2 plaintext lines.

## Detection helpers

- `detect.sh` prints `FOUND: <agent> (<version>)` or `NOT FOUND: <agent>` with
  install/auth hints, for `mimo aider codex gemini qwen opencode`.
- `detect-test.sh [dir]` prints one inferred test command
  (`npm test` → `python3 -m pytest -q` → `go test ./...` → `cargo test` →
  `make test`) or nothing. It only pre-fills a suggestion; setup must confirm.
- `doctor.sh [--all]` reports install and auth status for the configured agent,
  or every known agent with `--all`.
