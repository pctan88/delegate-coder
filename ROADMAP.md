# delegate-coder — v2 Roadmap

**Note (2026-06-14):** An accidental re-run of the benchmark matrix with the v2 skill was stopped and the partial `results/` directory was wiped. The v1 dataset in `benchmark/RESULTS.md` stands as the published and official result. Re-running the benchmark with the v2 skill is forbidden as it overwrites the dataset.

Design notes for enhancements proposed during benchmarking. **Build after the
current benchmark completes.** Nothing here should be merged into the live skill
while the 48-run matrix is in flight.

## Golden rule: what forces a re-benchmark

The benchmark is a headless `claude -p` session that reads the skill and runs
its delegation path. A change requires re-running **only if** it alters what that
headless run actually executes:

- `skills/delegate-coder/SKILL.md` — instructions / triggering wording
- `skills/delegate-coder/scripts/detect.sh` — agent resolution
- `skills/delegate-coder/scripts/delegate.sh` — the worker invocation for the
  benchmarked agent/mode

Everything else is safe. The design principle below is therefore:

> **Keep the default code path byte-identical to the benchmarked version.**
> All new behavior is opt-in via config or human-invoked commands. Config absent
> = today's exact behavior. The current published result then stands, and new
> configs (e.g. a different worker/model) are published as *new columns*, never
> as a redo.

Re-benchmark needed: enable/disable default change, model selection becoming
active, fallback-policy change.
No re-benchmark: slash commands, `doctor`, `stats`, install/setup guides — all
human-invoked, none on the delegated path.

## Architecture: thin skill + plugin wrapper

Keep the core skill minimal and stable. Move all new control surface into a
Claude Code **plugin wrapper** whose slash commands just (a) write config and
(b) read the audit log, then call the same `delegate.sh`.

```
delegate-coder/
  skills/delegate-coder/        # core, kept stable (benchmarked)
    SKILL.md
    scripts/{detect.sh,delegate.sh}
    references/{adapters.md,setup.md}
  commands/                     # slash commands -> config writes / log reads
    delegate-on.md  delegate-off.md  delegate-model.md
    delegate-stats.md  delegate-doctor.md  delegate-setup.md
  .claude-plugin/               # plugin metadata
    plugin.json
    marketplace.json
```

This satisfies ideas 1, 5, 6, 7 cleanly while leaving the benchmarked skill
untouched.

## Config schema (`.claude/delegate-coder.json`)

Backward compatible — every new field is optional and defaults to current
behavior when absent.

```jsonc
{
  "agent": "mimo",              // existing
  "test_command": "npm test",  // existing
  "model": "...",              // NEW idea 4 — per-agent model, threaded into CLI
  "enabled": true,             // NEW idea 5 — master switch
  "scope": "all",             // NEW idea 5 — all | read_only | exec_only | off
  "fallback": "strict",       // NEW — strict (benchmark) | graceful (daily use)
  "allow_paths": ["lib/", "tests/"], // NEW — exec worker may only touch these
  "command_override": { "read": "...", "exec": "..." } // existing
}
```

## Completed Features

### High
1. **[COMPLETED] `doctor` command (idea 3 + safety).** installed? authenticated? config
   valid? test_command present? Reports `ready / needs-auth / missing` per agent.
2. **[COMPLETED] Enable/disable + scope (idea 5).** `enabled` + `scope` in config; SKILL.md
   checks it before delegating. Slash commands `/delegate on|off`.
3. **[COMPLETED] Model selection (idea 4).** `model` field threaded into each adapter
   (`codex --model`, `gemini -m`, etc.); recorded in the audit log.
4. **[COMPLETED] Monitoring (idea 6).** Upgrade `delegate-coder.log` to one JSON line per
   task: `{ts, agent, model, mode, duration_s, exit_code, retries}`. Add
   `/delegate stats` summarizing count, per-agent success/retry rate, time.

### Medium
5. **[COMPLETED] Smarter `detect.sh` (idea 2).** When an agent is missing, print copy-paste
   install + auth commands per OS.
6. **[COMPLETED] Install/setup flow (idea 1).** Keep `install.sh`; add a guided `/delegate
   setup` that runs detect → doctor → writes initial config.

### Standard features
- **[COMPLETED] Path allowlist** — `allow_paths` limits what an `exec` worker may touch;
  tightens `git diff --stat` verification and reduces blast radius.
- **[COMPLETED] Strict vs graceful fallback** — benchmark wants "configured worker or fail";
  daily users want graceful fallback. One config switch.
- **[COMPLETED] Worker version pinning** in the log for reproducibility.
- **[COMPLETED] Dry-run preview** — print the exact delegated command before executing.

## Suggested build order
[COMPLETED] doctor → monitoring log/stats → enable/disable → model selection → detect
install hints → setup flow → allowlist + fallback switch. Package the
human-facing pieces as the plugin wrapper last, once the config fields exist.
