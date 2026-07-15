# PRD: Worker orchestration + plugin marketplace

**Feature:** DELEGATE-CODER-000  ·  **Status:** Shipped; acceptance tracking
backfilled  ·  **Last updated:** 2026-07-14

## Problem

Claude Code sessions spend expensive tokens on execution-heavy but low-judgment
work: reading whole codebases, routine implementation, mechanical refactors, and
first-pass review. That work can be done by a cheaper or free CLI coding agent
already installed on the machine, leaving Claude to spend its tokens on
decisions — architecture, specs, and judging diffs. Teams also need this to be
safe (scoped, revertible), measurable (auditable), and honest about the
credit savings it claims.

## Target users

- Claude Code users who want to cut credit usage on a real project by delegating
  grunt work to a worker agent (MiMo, Aider, Codex, Gemini, Qwen, OpenCode).
- Maintainers who need per-project control: enable/disable, scope, model, path
  limits, and an audit trail.
- Benchmark users who need an objective A/B measurement of savings and success.

## User flow

The user installs the `tan-tools` marketplace and the `delegate-coder` plugin,
then runs `/delegate-setup`, which detects installed workers, checks their auth,
shows an off-machine privacy warning where relevant, lets them pick an agent and
model, auto-detects the test command, and writes `.delegate-coder/config.json`
(Claude's legacy `.claude/delegate-coder.json` remains supported).
Thereafter the user asks Claude for coding work as normal. With the skill active,
Claude plans, delegates execution to the worker in `read` or `exec` mode via
`delegate.sh`, and verifies `exec` results with `git diff` plus the project test
command. Slash commands adjust config and read the audit log without touching
the delegated code path.

## Scope

- Ship a nested marketplace/plugin layout: marketplace `tan-tools`, plugin
  `delegate-coder`, a stable core skill, and human-invoked slash commands.
- Provide a routing policy (`SKILL.md`): orchestrator/worker split, a task-mode
  table, spec discipline, cheap verification, and a two-strike escalation rule.
- Route tasks through `delegate.sh <read|exec>` with built-in adapters for
  `mimo`, `aider`, `codex`, `gemini`, `qwen`, `opencode`, plus a
  `command_override` path for custom agents.
- Resolve the worker from `DELEGATE_AGENT`, `.delegate-coder/config.json`, or
  the legacy `.claude/delegate-coder.json`, and
  read `model`, `fallback`, `allow_paths`, and `command_override` from config.
- Detect installed agents and infer the project test command.
- Request read-only or dry-run behavior for `read` where the worker adapter
  supports it; `exec` uses a change-making invocation followed by orchestrator
  verification. Gemini, Qwen, and OpenCode `read` invocations do not enforce a
  read-only sandbox.
- Write a JSON audit log of start/end events and summarize it with `stats.sh`.
- Provide a `doctor` health check for install/auth status.
- Provide an A/B benchmark harness that measures cost, tokens, turns, duration,
  success, and triggering.

## Out of scope

- Bundling or installing a worker agent; the plugin orchestrates one the user
  already has.
- Sandboxing arbitrary worker behavior beyond the agent's own permission config,
  Git branch isolation, and the post-run `allow_paths` check.
- Automatic cloud orchestration, PR creation, or merge decisions.
- The strict single-file contract execution path — that is DELEGATE-CODER-001.
- Rerunning or overwriting the frozen v1 benchmark dataset.

## Acceptance criteria

1. `delegate.sh` accepts only `read` or `exec`; a missing/invalid mode or task
   exits non-zero with usage.
2. The worker is resolved from `DELEGATE_AGENT` first, then the `agent` field in
   config; with neither set, the run exits non-zero and lists installed
   candidates.
3. Each built-in adapter maps `read` to its available read-only or dry-run
   control and `exec` to a change-making invocation; adapters without an
   enforced read-only control are documented as such. `model` is threaded into
   the correct per-agent flag when present.
4. `command_override` for the active mode replaces the built-in adapter, with
   `{task}` substituted.
5. `fallback: strict` refuses to run natively when the agent is missing and
   signals a critical failure; `graceful` (default) just reports the agent is
   not found.
6. After an `exec` run, files changed outside `allow_paths` (when configured)
   are reported and the run exits non-zero.
7. Every run appends JSON `start` and `end` audit events with agent, model,
   mode, duration, and exit code; `stats.sh` summarizes them.
8. A new or absent config produces the exact benchmarked default behavior; every
   new field is optional.
9. Setup shows the off-machine privacy warning for hosted workers and omits it
   for purely local workers.
10. The frozen v1 benchmark dataset and methodology remain unchanged.

## Dependencies and risks

- Requires Bash, Git, and the chosen worker CLI on `PATH`; `jq` is required for
  `command_override`, `allow_paths` array parsing, and `stats.sh` *(confirm
  minimum versions)*.
- Worker agents interpret vague specs poorly; success depends on the
  orchestrator writing exact scope, constraints, and a verify command.
- Hosted workers transmit code to third-party providers; this is a policy risk
  for confidential code and is mitigated by the setup warning, not prevented.
- Blanket auto-approval flags (`--dangerously-skip-permissions`, `--yolo`) let a
  confused worker run destructive commands; Git isolation and the `allow_paths`
  check are the current guardrails.
- Adapter flags drift between agent versions; `command_override` and
  `references/adapters.md` are the escape hatch *(confirm maintenance owner)*.

## Approval

| Role | Name | Status | Date |
|---|---|---|---|
| Maintainer | | Pending — orchestration scope and default-path stability | |
| Plugin/skill owner | | Pending — adapters, config surface, audit behavior | |
| Benchmark owner | | Pending — frozen v1 dataset protection | |
