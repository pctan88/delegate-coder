# delegate-coder

**Let Claude think. Let a cheaper agent type.**

A Claude Code skill that delegates execution-heavy coding work — bulk codebase reading, implementation, refactoring, first-pass review — to a second CLI coding agent (MiMo Code, Aider, Codex CLI, Gemini CLI, Qwen Code, OpenCode, or any headless agent), while Claude keeps the planning, architecture, and final judgment.

**Why:** Claude Code usage is precious. Most of what burns it isn't thinking — it's reading 50 files and typing routine code. Free-tier worker agents can do that part. This skill makes the handoff automatic *and safe*.

## What makes this different

This is not just a CLI wrapper. The skill encodes a **trust framework** for delegation:

1. **Precise spec handoff** — Claude writes exact scope, constraints, and verification criteria before delegating. Vague handoffs are the #1 cause of wasted cycles.
2. **Git branch isolation** — every exec task runs on a `delegate/*` branch. Nothing touches your working state.
3. **Cheap, deterministic verification** — results are verified by `git diff --stat` + your test suite, not by Claude re-reading code. Diffs can't lie; summaries can.
4. **Read-only modes where supported** — analysis tasks use the worker's read-only mode (MiMo `plan`, Codex `read-only` sandbox) for zero-risk delegation.
5. **Escalation rule** — two failures on the same task and Claude stops delegating it. No silent retry loops eating your savings.
6. **Safe permissions guidance** — granular allow/deny config instead of blanket `--dangerously-skip-permissions` / `--yolo`.

## Experimental (v2)

v2 adds several new config options: **model selection**, **enable/scope** guards, **strict/graceful fallback**, and a **path allowlist**. These all default to off or prior behavior, so existing setups are unaffected. The v2 routing and contract paths have deterministic unit coverage. Local-Qwen performance is still unproven until the paired local benchmark is run; the frozen benchmark results below are historical Claude+MiMo v1 evidence and do not measure Qwen.

## Supported worker agents

| Agent | exec | read-only | sessions |
|---|---|---|---|
| MiMo Code | ✅ | ✅ (`plan` mode) | ✅ |
| Aider | ✅ | ◐ (`--dry-run`) | — |
| Codex CLI | ✅ | ✅ (sandbox) | ✅ |
| Gemini CLI | ✅ | ◐ | — |
| Qwen Code | ✅ | ◐ | — |
| OpenCode | ✅ | ◐ | ◐ |
| Anything else | via `command_override` — any CLI with a headless mode works | | |

## Install

### As a plugin (recommended)

This repo is a Claude Code marketplace and a Codex plugin marketplace. From
inside Claude Code:

```
/plugin marketplace add pctan88/delegate-coder
/plugin install delegate-coder@tan-tools
```

This installs the skill **and** the `/delegate-*` slash commands.

### In Codex

The repository also ships a Codex plugin manifest and repo marketplace. After
cloning the repository, add the local marketplace and open Codex's plugin
browser:

```bash
cd delegate-coder
codex plugin marketplace add .
codex
```

In Codex, run `/plugins`, choose **Tan Tools**, and install **Delegate Coder**.
Then start a new task and invoke the skill with `$delegate-coder` or by asking
Codex to delegate a bounded implementation, refactor, repository read, or
first-pass review to a configured worker. Claude's `/delegate-*` command files
remain available in Claude Code; Codex uses skills and its natural-language
workflow instead. On first use, invoke `$delegate-coder-codex-onboarding` (or
ask Codex to set up Delegate Coder). It detects `qwen`, Ollama models, and the
project test command, explains the Qwen Code CLI versus local Ollama contract
choice, asks for confirmation, and then creates the shared
`.delegate-coder/config.json`. It never writes configuration or installs a
worker without your confirmation.

For a skill-only installation (without the plugin browser), use the existing
installer with Codex's skill directory:

```bash
curl -fsSL https://raw.githubusercontent.com/pctan88/delegate-coder/main/install.sh \
  | bash -s -- --target "$HOME/.agents/skills"
```

The runtime prefers the shared `.delegate-coder/config.json` and falls back to
the legacy `.claude/delegate-coder.json`, so existing Claude Code projects keep
working unchanged. Local Ollama/Qwen is selected through the onboarding flow or
the `implementation_backend: "contract"` configuration; keep planning,
architecture, security-sensitive decisions, and final diff/test acceptance in
the orchestrator.

### Manual (skill only)

```bash
# Personal (all projects)
git clone https://github.com/pctan88/delegate-coder.git
cp -r delegate-coder/plugins/delegate-coder/skills/delegate-coder ~/.claude/skills/

# Or per-project
cp -r delegate-coder/plugins/delegate-coder/skills/delegate-coder YOUR_PROJECT/.claude/skills/
```

Or use the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/pctan88/delegate-coder/main/install.sh | bash
```

## Quick start

1. Install a worker agent (e.g. MiMo: `curl -fsSL https://mimo.xiaomi.com/install | bash`)
2. Open Claude Code in your project and say something like:
   > "Use the delegate worker to summarize the architecture of this repo"
   
   or just work normally — the skill triggers when delegation fits the task.
3. First run, the orchestrator detects installed workers, asks which to use,
   and saves the choice to `.delegate-coder/config.json` (existing Claude
   projects may continue using `.claude/delegate-coder.json`).

Configuration details: [setup.md](plugins/delegate-coder/skills/delegate-coder/references/setup.md)

## AI-first planning and tracking

Implementation is documented as reviewable feature packs under `docs/features/`,
each with a PRD, HLD, API contract, plan, test plan, decision log, and release
checklist:

- [DELEGATE-CODER-000](docs/features/DELEGATE-CODER-000-worker-orchestration/README.md)
  — foundational worker orchestration: marketplace, `read`/`exec` adapters,
  config surface, and benchmark harness.
- [DELEGATE-CODER-001](docs/features/DELEGATE-CODER-001-contract-router/README.md)
  — the opt-in strict single-file contract router, layered on 000.
- [DELEGATE-CODER-002](docs/features/DELEGATE-CODER-002-resilient-contracts/README.md)
  — resilient output budgeting, context handling, test detection, and syntax
  preflight for contract execution; PR #6 is still in review.

Read the pack matching the code you touch before changing it. Multi-file work is
decomposed into bounded sequential contracts, and each decision log is the
append-only record of design changes. Both features are single-repository, so no
cross-repo plan is included.

## Local Qwen behind Claude or Codex

Raw contract mode is designed to avoid repeated heavy-harness prefill by sending one bounded full-file request to local Ollama/Qwen. It is not yet proven faster: run the new paired local benchmark before making performance claims.

Claude or Codex remains responsible for planning, dependency analysis, architecture, security review, malformed-input boundaries, cumulative diff review, and final acceptance. Contract mode is eligible for a bounded single-file implementation/refactor when the orchestrator can provide complete constraints and an objective test. Exploration, architecture, authentication/security work, ambiguous changes, repository-wide reasoning, and critical invariant decisions stay on the normal agent/native path.

Contract mode requires a clean worktree and an isolated feature/delegate branch before the first write, and it never silently falls back to a hosted provider. Explicitly ordered multi-file work must be decomposed into one contract per file and run sequentially, stopping on the first failure.

Use the opt-in backend configuration:

```json
{
  "implementation_backend": "agent",
  "contract": {
    "model": "qwen3-coder:30b",
    "num_ctx": 32768,
    "keep_alive": "30m",
    "curl_timeout": 600,
    "test_timeout": 300
  }
}
```

The absent/default `agent` value preserves the existing `read`/`exec` behavior. Set it to `contract` only for JSON Task Contracts. Each contract's instructions must include external interfaces, signatures, invariants, dependency ordering, forbidden changes, and the exact test command.

### Orchestrator prompt

```text
Use delegate-coder with the local contract backend for eligible implementation work.

You remain responsible for architecture, cross-file reasoning, dependency ordering, security-sensitive decisions, and final acceptance.

Before delegating:
1. Create or use an isolated feature/delegate branch and confirm the target is clean.
2. Inspect the repository and identify the exact files and dependency order.
3. For each file, write one complete Task Contract containing:
   - the single target file;
   - precise required behavior;
   - relevant external interfaces and invariants;
   - forbidden changes;
   - an objective targeted verification command.
4. Run contracts sequentially and stop immediately on FAIL.
5. Never trust the worker summary alone.
6. After all contracts pass, inspect the cumulative diff and run the full repository test/lint/typecheck suite.
7. Keep authentication, security, malformed-input boundaries, and critical invariants under your own review.
```

## Contract mode (local Ollama)

For a strict, low-token edit, send `delegate.sh` a Task Contract instead of a chat prompt. Keep contracts single-file and sequential: a three-file feature should be three contracts, never one exploratory multi-file request.

```json
{
  "target_file": "src/path/to/file.ts",
  "instructions": "Specific functional target or removal goal here.",
  "test_command": "npm run test -- src/path/to/file.spec.ts"
}
```

Run it from the target repository with:

```bash
bash path/to/delegate.sh contract '{"target_file":"src/file.ts","instructions":"...","test_command":"npm test -- src/file.spec.ts"}'
```

The JSON may also be piped on stdin. Contract mode uses Ollama structured output with a strict `{updated_file}` schema and deterministic temperature `0`; it preflights prompt plus expected full-file output against `num_ctx`, stops other resident Ollama models, snapshots and transactionally stages only the declared regular file, and runs the supplied bounded test command. A failing test gets exactly one correction attempt; parser failures, truncation, timeout, signal, outside-target changes, index changes, and final test failures restore Git-visible tracked/nonignored state. A successful changed contract also restores the pre-child Git index, leaving the accepted target modification unstaged. Ignored dependency/cache/build trees are not snapshotted. Standard output is a markdown report containing status, restoration state, Ollama timing metrics, the pre-contract target-only diff, and the final test log; progress goes to stderr. With the default `OLLAMA_HOST` (`http://127.0.0.1:11434`), file contents stay on the machine; an explicitly remote override preserves normal proxy behavior and is a privacy boundary. Ollama must be installed and serving the configured host. The existing `read` and default `exec` chat-agent modes remain supported. `test_command` is trusted local code and must not mutate Git references or make commits.

Set `DELEGATE_MODEL` to select another local Ollama model, `DELEGATE_NUM_CTX` to change the context limit (default `32768`), `DELEGATE_CURL_TIMEOUT`/`DELEGATE_TEST_TIMEOUT` for timeouts, and `DELEGATE_KEEP_ALIVE` for model retention (default `30m`). If the model produces no change, the report says `NOOP`; if it reports `done_reason: length`, the file is not replaced. A top-level JSON array runs contracts sequentially and returns one combined report with aggregate retries.

Runs through `delegate.sh` also append valid JSON start/end events, status, duration, retries, restoration state, and Ollama timing metrics to `.claude/delegate-coder.log`, so `/delegate stats` includes contract executions.

## Does it actually save credits?

This repo includes a [benchmark harness](benchmark/) that measures it properly: paired A/B runs (with/without the skill), real cost numbers from Claude Code's own JSON output, and objective pass/fail verification per task.

What we actually measured (MiMo worker, commander.js, Claude Sonnet 4.6, n=3 — see [full results](benchmark/RESULTS.md)): installing the skill gave a **~11% reduction in cost per successful task** ($0.493 → $0.440), but the result is uneven and should be read as directional, not conclusive. The savings come from **heavy implementation/refactor tasks** when delegation actually fires (e.g. a cross-file feature −37%). **Bulk codebase reading was a loss** with this worker — ~20% costlier and ~3× slower — so offloading large reads to MiMo did not pay off in the published evidence. Review was inconclusive. This historical Claude+MiMo v1 dataset is unrelated to local-Qwen performance; run the additive paired benchmark before trusting any local number.

**Note on triggering:** with natural, unmodified prompts the skill delegates *selectively* — readily for heavy reads, reluctantly for small implementation/refactor/review tasks (overall it fired in ~42% of eligible runs), and it correctly declines trivial one-line tasks. Getting it to trigger at all required leading the skill description with task types and stating that installing it implies intent to delegate; see RESULTS.md for the before/after wording. Triggering reliability on execution tasks is the main open item for v2.

### Measured results (directional)

| Category | Trigger rate | Cost effect when delegated | Notes |
|---|---|---|---|
| bulk-read | 6/6 | **+20% (loss)**, ~3× slower | clean comparison; offloading reads didn't pay off |
| implement | 2/6 | **−37%** (heavy task, n=2) | category mean confounded by trivial control |
| refactor | 1/6 | **−57%** (n=1) | inconclusive, tiny sample |
| review | 1/6 | inconclusive | delegation rarely fired |
| **Overall** | **42%** | **−11% cost per success** | n=3, high variance — directional only |

## Privacy & safety notes

- Free-tier workers (MiMo, Gemini) send your code to their provider's servers. Fine for personal/OSS work; check policy before using on employer code.
- Read [setup.md](plugins/delegate-coder/skills/delegate-coder/references/setup.md) before enabling auto-approval flags on any worker.
- All exec work lands on a `delegate/*` git branch — review the diff before merging, always.

## Related projects

- [shinpr/sub-agents-skills](https://github.com/shinpr/sub-agents-skills) — cross-LLM sub-agent routing (define agents in markdown, run on any backend). A router; delegate-coder is a cost-saving workflow. Use theirs if you want per-agent backend selection; use this if you want the orchestrator/worker split with verification built in.
- [zen-mcp-server's clink](https://github.com/BeehiveInnovations/zen-mcp-server) — CLI-to-CLI bridging via MCP.

## License

MIT
