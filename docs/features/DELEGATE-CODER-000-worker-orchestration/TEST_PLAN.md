# Test Plan: Worker orchestration

**Last updated:** 2026-07-14

## Must-pass cases

The core suite drives `delegate.sh` and `detect-test.sh` with a fake worker on
`PATH` and temporary fixtures — no real agent, network, or model:

```bash
bash plugins/delegate-coder/skills/delegate-coder/tests/core.test.sh
```

It must cover:

| Case | Expected result |
|---|---|
| Invalid mode | Exit 2 with usage on stderr |
| Missing task spec | Exit 2 |
| No agent configured | Exit 3, lists installed candidates |
| Agent from `DELEGATE_AGENT` | Adapter runs with the resolved agent |
| Agent from config `agent` field | Same resolution from `.delegate-coder/config.json`, then legacy `.claude/delegate-coder.json` |
| `read` vs `exec` mapping | Adapter-specific read-only/dry-run controls where supported; change-making flags for `exec` |
| Model threading | Configured `model` appears in the worker argv |
| `command_override` | Override runs with `{task}` substituted, bypassing the adapter |
| Missing agent + `fallback: strict` | Exit 4 and a CRITICAL "do not do natively" message |
| Missing agent + `fallback: graceful` | Exit 4 without the critical directive |
| `allow_paths` violation (exec) | Exit 6 after a file outside the allowlist is changed |
| `allow_paths` respected (exec) | Exit 0 when changes stay inside the allowlist |
| Audit log | `start` and `end` JSON events written with agent, mode, exit_code |
| `detect-test.sh` — npm real script | `npm test` |
| `detect-test.sh` — npm placeholder | Not detected as npm |
| `detect-test.sh` — pytest / go / cargo / make | Correct per-ecosystem command |
| `detect-test.sh` — no markers | Prints nothing |

## Regression checks

Run the relevant script checks for a release, then inspect:

```bash
git diff --check
git diff --stat
```

## Benchmark protection

The v1 benchmark is a frozen artifact. A change to `SKILL.md`, `detect.sh`, or
the benchmarked `delegate.sh` invocation forces a re-benchmark on a **new,
separately named dataset**; it must never rerun or overwrite the v1 matrix in
`benchmark/RESULTS.md` *(confirm process)*. Human-invoked commands, `doctor`,
`stats`, setup, and documentation do not require a rerun.

## Manual checks

- Configure a real worker, delegate a trivial `read` task ("summarize the
  structure of this repo"), and confirm output returns.
- Confirm `.claude/delegate-coder.log` gains start/end events and `stats.sh`
  summarizes them.
- Confirm `/delegate-setup` shows the off-machine privacy warning for a hosted
  worker and omits it for a purely local one.
- Confirm `doctor.sh --all` reports install/auth status per agent.

## Negative/security checks

- Reject invalid modes and empty task specs.
- Under `fallback: strict`, never fall back to native execution when the worker
  is missing.
- Flag any `exec` change outside `allow_paths`.
- Treat worker-executed commands as trusted local code; the harness relies on
  the agent's own permission config plus Git isolation, not sandboxing.
