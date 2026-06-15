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

v2 adds several new config options: **model selection**, **enable/scope** guards, **strict/graceful fallback**, and a **path allowlist**. These all default to off or prior behavior, so existing setups are unaffected. However, **none of these features have been benchmarked or unit-tested yet** — the benchmark results below reflect v1 behavior only. Treat them as opt-in and report issues.

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

```bash
# Personal (all projects)
git clone https://github.com/pctan88/delegate-coder.git
cp -r delegate-coder/skills/delegate-coder ~/.claude/skills/

# Or per-project
cp -r delegate-coder/skills/delegate-coder YOUR_PROJECT/.claude/skills/
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
3. First run, Claude detects installed workers, asks which to use, and saves the choice to `.claude/delegate-coder.json`.

Configuration details: [skills/delegate-coder/references/setup.md](skills/delegate-coder/references/setup.md)

## Does it actually save credits?

This repo includes a [benchmark harness](benchmark/) that measures it properly: paired A/B runs (with/without the skill), real cost numbers from Claude Code's own JSON output, and objective pass/fail verification per task.

What we actually measured (mimo worker, commander.js, Claude Sonnet 4.6, n=3 — see [full results](benchmark/RESULTS.md)): installing the skill gave a **~11% reduction in cost per successful task** ($0.493 → $0.440), but the result is uneven and should be read as directional, not conclusive. The savings come from **heavy implementation/refactor tasks** when delegation actually fires (e.g. a cross-file feature −37%). **Bulk codebase reading was a loss** with this worker — ~20% costlier and ~3× slower — so despite the intuition, offloading large reads to mimo did not pay off. Review was inconclusive. Run the benchmark on your own repo before trusting any number, including ours.

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
- Read [references/setup.md](skills/delegate-coder/references/setup.md) before enabling auto-approval flags on any worker.
- All exec work lands on a `delegate/*` git branch — review the diff before merging, always.

## Related projects

- [shinpr/sub-agents-skills](https://github.com/shinpr/sub-agents-skills) — cross-LLM sub-agent routing (define agents in markdown, run on any backend). A router; delegate-coder is a cost-saving workflow. Use theirs if you want per-agent backend selection; use this if you want the orchestrator/worker split with verification built in.
- [zen-mcp-server's clink](https://github.com/BeehiveInnovations/zen-mcp-server) — CLI-to-CLI bridging via MCP.

## License

MIT
