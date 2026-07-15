# HLD: Worker orchestration + plugin marketplace

**Feature:** DELEGATE-CODER-000  ·  **Last updated:** 2026-07-14

## Context

Claude is the orchestrator; a second CLI coding agent on the same machine is the
worker. The design keeps the benchmarked core skill small and stable and pushes
all new control surface into human-invoked plugin commands, so the default
delegated code path stays byte-identical to the published benchmark.

## Components and responsibilities

| Component | Responsibility |
|---|---|
| `.claude-plugin/marketplace.json` | Declare the `tan-tools` marketplace |
| `plugins/delegate-coder/.claude-plugin/plugin.json` | Declare the plugin |
| `skills/delegate-coder/SKILL.md` | Routing policy: orchestrator/worker split, mode table, scope guard, spec discipline, verification, two-strike escalation *(benchmarked)* |
| `scripts/delegate.sh` | Resolve agent/model/config, map `read`/`exec` to the per-agent CLI invocation, run it, audit-log, and check `allow_paths` *(benchmarked invocation)* |
| `scripts/detect.sh` | List installed workers with install/auth hints *(benchmarked agent resolution)* |
| `scripts/detect-test.sh` | Infer the project test command from on-disk markers |
| `scripts/doctor.sh` | Health-check install/auth for one or all agents |
| `scripts/stats.sh` | Summarize the JSON audit log (needs `jq`) |
| `commands/delegate-*.md` | Slash commands that write config or read the log; never on the delegated path |
| `references/{adapters,setup,models}.md` | Per-agent commands, config/permission setup, model options |
| `.delegate-coder/config.json` | Preferred shared per-project config (agent, model, scope, fallback, allow_paths, overrides) |
| `.claude/delegate-coder.json` | Legacy Claude config fallback |
| `.claude/delegate-coder.log` | JSON audit events for `stats.sh` |
| `benchmark/` | Paired A/B harness and the frozen v1 dataset |

## Target flow

```text
user request
  -> Claude (orchestrator) reads SKILL.md
  -> scope guard: enabled? scope allows this mode?
  -> pick mode: read (understand/summarize/review) | exec (implement/refactor/fix)
  -> write exact spec (paths, behavior, constraints, verify command)
  -> exec only: git checkout -b delegate/<task>
  -> delegate.sh <mode> "<spec>"
       resolve agent (DELEGATE_AGENT > config) + model + fallback + allow_paths
       audit:start
       command_override? -> run it
       else per-agent adapter: read = read-only/dry-run where supported;
            exec = change-making flags
       audit:end (duration, exit_code)
       exec + allow_paths -> flag files changed outside the allowlist
  -> Claude verifies exec: git diff --stat + project test command
       (full git diff only if large / core / tests fail / worker unsure)
  -> worker fails same task twice -> stop delegating (rewrite spec or do natively)
```

## Trust and safety boundaries

- `read` mode requests the agent-specific plan, dry-run, or read-only sandbox
  where one exists (MiMo, Aider, and Codex). Gemini, Qwen, and OpenCode have no
  enforced read-only control in their current adapters, so `read` is not a
  zero-write guarantee for those agents. `exec` mode makes changes and is
  always verified.
- Change isolation is Git branch + reviewable diff; the worker's summary is
  never accepted as proof.
- `allow_paths` is a post-run prefix check over `git diff --name-only`; a
  violation aborts with a distinct exit code.
- `fallback: strict` (used for benchmarking) forbids silent native fallback when
  the worker is missing; `graceful` is the daily-use default.
- Worker permissions should come from the agent's own allow/deny config and Git
  isolation before any blanket auto-approval flag.

## Benchmark boundary

The benchmark is a headless `claude -p` run that reads the skill and exercises
the delegated path. Only three files change what that run executes and therefore
force a re-benchmark: `SKILL.md`, `detect.sh`, and the benchmarked `delegate.sh`
invocation. Slash commands, `doctor`, `stats`, setup, and docs are all
human-invoked and never require a rerun. The v1 dataset in `benchmark/RESULTS.md`
is frozen; new behavior is published as new columns on a separately labeled
dataset, never as a redo *(confirm release process)*.

## Extension point

DELEGATE-CODER-001 (contract router) adds an opt-in `delegate.sh contract` mode
for strict single-file, full-file replacement against a local model. It is
separate from the `read`/`exec` adapters described here and does not change this
default path.
