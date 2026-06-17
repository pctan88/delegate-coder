# Project: delegate-coder

> Handoff doc for a fresh Claude session with no memory of prior work. Read this first, then the files it points to. Everything below is drawn from the actual contents of this folder as of 2026-06-16.

## Purpose

delegate-coder is a **Claude Code skill** (packaged as a Claude Code **plugin**) plus an **A/B benchmark harness** that measures it.

The idea: Claude Code usage is expensive, and most of what burns it is execution, not thinking — reading 50 files, typing routine code. The skill makes Claude act as an **orchestrator** that hands execution-heavy work (bulk codebase reading, implementation, refactoring, first-pass review) to a cheaper/free second CLI coding agent (the **worker**: MiMo, Aider, Codex CLI, Gemini CLI, Qwen Code, OpenCode, or any headless CLI). Claude keeps planning, architecture, and final judgment.

What makes it more than a CLI wrapper is the **trust/safety framework** baked into the workflow: precise spec handoff, git branch isolation for every exec task (`delegate/*`), cheap deterministic verification via `git diff --stat` + the test suite (not by re-reading code), read-only modes where the worker supports them, and a hard "two failures = stop delegating" escalation rule.

The benchmark exists to answer one question honestly: **does the skill actually reduce Claude cost without hurting accuracy?** The published answer is "directionally yes, ~11% per successful task, but uneven and worker-dependent."

## What's in This Folder

Top level:

- **`README.md`** — the public-facing project README (pitch, supported workers, install instructions, measured results table, privacy notes). This is the polished external doc.
- **`CLAUDE.md`** — repo guide for Claude Code: layout, exact step-by-step instructions for running the benchmark, and the hard rules (don't edit the benchmark methodology, don't pre-install the skill into the target repo, etc.). Treat its rules as binding.
- **`ROADMAP.md`** — v2 design notes. Important: states the "golden rule" of what forces a re-benchmark, and that all listed v2 features are now **[COMPLETED]**.
- **`HANDOFF.md`** (root) — narrative handoff covering smoke results, the trigger-metric flaw and fix, the mimo-vs-gemini worker mismatch, the trivial-control finding, and the list of completed v2 enhancements.
- **`BENCHMARK_PROMPT.md`** — a ready-to-paste prompt for driving a fresh benchmark run in Claude Code, with the placeholder `<TARGET_REPO>` and the pause-for-confirmation checkpoints.
- **`install.sh`** — installs the skill to `~/.claude/skills` (or `--target`) by cloning `github.com/pctan88/delegate-coder`.
- **`LICENSE`** — MIT.
- **`.env`** — ⚠️ contains a real `GEMINI_API_KEY`. Gitignored, but present on disk. See Open Questions — rotate it.
- **`.gitignore` / `.gitattributes`** — standard; ignores `.env`, `benchmark/target-repo/`, `benchmark/results/`, runtime logs, `_archive/`.

`plugins/delegate-coder/skills/delegate-coder/` — **the actual skill** (the thing that gets installed):

- **`SKILL.md`** — the orchestration workflow: identify worker → scope guard → choose read/exec mode → write spec & delegate → verify cheaply → escalation rule → session continuity. The frontmatter `description` is deliberately worded for triggering (see Key Decisions).
- **`scripts/detect.sh`** — lists installed worker agents; prints install/auth hints when one is missing.
- **`scripts/delegate.sh`** — the universal adapter; maps `read`/`exec` mode to the right CLI invocation for the configured agent. Also writes the audit log used by the benchmark's trigger metric.
- **`scripts/doctor.sh`** — health check (installed? authenticated? config valid? test command present?) per agent.
- **`scripts/stats.sh`** — summarizes the JSON audit log (`.claude/delegate-coder.log`).
- **`references/adapters.md`** — per-agent commands, read-only modes, session flags, permission settings.
- **`references/setup.md`** — first-time setup: config file format and safe permission guidance.

`plugins/delegate-coder/commands/` — plugin slash commands (human-invoked, NOT on the delegated path): `delegate-on.md`, `delegate-off.md`, `delegate-scope.md`, `delegate-model.md`, `delegate-setup.md`, `delegate-doctor.md`, `delegate-stats.md`. Each just writes config or reads the log. (They reference scripts via `${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/...`, so they resolve correctly under the plugin layout.)

`plugins/delegate-coder/.claude-plugin/plugin.json` — the plugin manifest: name `delegate-coder`, version **0.2.0**, author Tan (`tanpoicheong@gmail.com`), homepage `github.com/pctan88/delegate-coder`.

`.claude-plugin/marketplace.json` (repo root) — the marketplace manifest: name `tan-tools`, owner Tan (`tanpoicheong@gmail.com`), one plugin entry with `source: ./plugins/delegate-coder`.

`benchmark/` — the A/B measurement harness:

- **`README.md`** — full methodology; read before running.
- **`run_benchmark.sh`** — the A/B runner. Condition A = no skill, B = skill installed; interleaved order, hard `git reset --hard && git clean -fd` between runs. **Do not edit its methodology without asking** (per CLAUDE.md).
- **`tasks.json`** — the 8 real tasks used (commander.js), covering bulk-read / implement / refactor / review with objective `verify` commands. `full_tasks.json` is a copy/variant.
- **`report.py`** — aggregates `results/*.json` into the published table.
- **`RESULTS.md`** — **the official published result** (v1). Headline numbers, per-category breakdown, limitations, and the full 48-run raw dataset inline.
- **`HANDOFF.md`** (benchmark) — the run log: progress, rate-limit interruptions, and confirmation the 48-run matrix completed.
- **`raw_data.jsonl`** — raw run records.
- **`results/`** — empty (gitignored; the live results were folded into RESULTS.md and the dir was wiped — see below).
- **`test_results/`** — `run_test.json`, `run_test_B.json` (smoke artifacts).
- **`target-repo/`** — a full clone of **commander.js** (the benchmark target; gitignored, not part of this project's source). Tag present: `v15.0.0`.

`_archive/` — `delegate-coder-repo.zip`, an early snapshot (gitignored).

## Current Status

**Finished:**

- v1 skill built, benchmarked, and published. The benchmark ran the full 48-session matrix (8 tasks × 2 conditions × 3 reps) to completion despite several Claude 429 rate-limit interruptions. `benchmark/RESULTS.md` is the official, published result.
- v2 enhancements all implemented and marked `[COMPLETED]` in ROADMAP.md and root HANDOFF.md: `doctor.sh`, JSON audit logging + `stats.sh`, scope guard (`enabled`/`scope`), `model` selection threaded into adapters, strict/graceful `fallback`, `allow_paths` allowlist, worker version pinning, dry-run preview, smarter `detect.sh` install hints, and the plugin wrapper with `/delegate` slash commands. Plugin version bumped to 0.2.0.
- Trigger metric flaw found and fixed (grep on Claude's JSON transcript always read 0 because intermediate bash calls are stripped; replaced by an audit-log-existence check).
- `report.py` fixed to handle streaming CLI dumps and deduce true `num_turns`.

**In progress / not done:**

- **v2 has NOT been benchmarked or unit-tested.** The published numbers reflect v1 behavior only. v2 features default to off / prior behavior so existing setups are unaffected, but they're unverified.
- **Reliable triggering on execution tasks** is the main open item. Description tuning got bulk-read to fire 100% of the time but implement/refactor/review stayed low (overall 42%).

**Explicitly forbidden / settled:**

- Re-running the benchmark with the v2 skill is **forbidden** — it would overwrite the v1 dataset. An accidental v2 re-run was already stopped and `benchmark/results/` was wiped on purpose. The v1 RESULTS.md stands.

## Key Decisions & Approach (do not undo or contradict)

- **The v1 benchmark dataset is frozen.** `benchmark/RESULTS.md` is the canonical published result. Do not re-run the benchmark with the current (v2) skill, and do not regenerate/overwrite RESULTS.md. If new configs need measuring, publish them as **new columns**, never as a redo of v1.
- **Keep the default code path byte-identical to the benchmarked version.** The "golden rule" in ROADMAP.md: only changes to `SKILL.md`, `detect.sh`, or `delegate.sh` that alter what a headless `claude -p` run executes force a re-benchmark. All new v2 behavior is opt-in via config (absent config = exact v1 behavior) or human-invoked slash commands.
- **Benchmark methodology is protected.** Interleaving (A,B,A,B), hard git reset between runs, and objective exit-0 `verify` commands exist to keep the comparison fair. Don't change them in `run_benchmark.sh` without asking.
- **Honest, directional reporting.** Numbers are reported as directional, not conclusive (n=3, high variance, 42% trigger rate). Losses are reported alongside wins — notably **bulk-read was a loss** (~20% costlier, ~3× slower with mimo), which contradicts the skill's own pitch and is stated plainly. Per-category results matter more than the overall average.
- **Trust framework over raw speed:** git branch isolation for exec, cheap deterministic verification (diffs/tests, not re-reading), read-only modes, two-strikes escalation, granular permissions instead of blanket `--dangerously-skip-permissions`/`--yolo`.
- **Trigger metric = audit-log existence**, not grep on the transcript. Keep it that way.
- **Architecture: thin stable skill + plugin wrapper.** Core skill stays minimal/stable; all new control surface lives in slash commands that write config or read the log.

## My Preferences for This Project

Inferred from how the existing files are written:

- **Intellectual honesty above marketing.** Every results doc leads with caveats, separates causal from confounded comparisons, and explicitly calls out losses and low statistical power. Don't cherry-pick a headline. The README literally says "Run the benchmark on your own repo before trusting any number, including ours."
- **Precise, technical, plain-language prose.** Markdown with clear headers and compact tables. Comparison tables are used heavily and well. Minimal fluff.
- **Reproducibility and provenance.** Results always state model, worker + version, target repo + commit, reps, and date. Scripts have header comments explaining usage.
- **Safety-first defaults.** Opt-in everything; preserve prior behavior; isolate changes; protect the dataset.
- **Concise and direct communication.** (Also the user's stated global preference — keep explanations tight, cut redundant words.)
- Tone is candid and slightly opinionated in docs ("Diffs can't lie; summaries can"), but claims are always backed by the data.

## Work in Progress / Open Questions

- **Reliable execution-task triggering (the #1 open item).** With natural prompts the skill fires readily for bulk reads but reluctantly for implement/refactor/review at small task sizes (overall 42%). Open question: is that reluctance correct (avoiding overhead) or a tuning gap (skipping delegable work)? v2 hasn't resolved it.
- **v2 is unverified.** None of the v2 config features (model selection, scope guard, fallback, allow_paths) have been benchmarked or unit-tested.
- **Bulk-read is counterproductive with mimo.** Open follow-up from RESULTS.md: either drop bulk-read from the skill's recommended modes, or test a faster worker for read-only tasks.
- **Worker model unverified.** The benchmark measured "mimo 0.1.0 as worker"; its underlying model was intentionally not asserted.
- **Known tooling note:** `report.py` historically emitted interleaved `null` records and a broken `num_turns` (since fixed) — cosmetic for aggregates but worth confirming if re-aggregating.
- ⚠️ **Secret exposure:** `.env` contains a live `GEMINI_API_KEY`. It's gitignored so it shouldn't be in git history, but verify it was never committed, and rotate the key to be safe.

## Next Steps (priority order)

1. **Confirm the dataset/secret guardrails before touching anything:** verify `.env` was never committed (`git log --all -- .env`), and rotate the Gemini key. Confirm `benchmark/RESULTS.md` is intact and unchanged.
2. **Decide the v2 validation path** without breaking the freeze: add unit tests for the new config behaviors (scope guard, fallback, allow_paths, model threading) since those are off the benchmarked path and don't require a re-run.
3. **Address the bulk-read loss:** update the skill's recommended modes (de-emphasize bulk-read for slow workers) and/or document a faster read-only worker — published as new guidance, not a v1 redo.
4. **Work the triggering problem:** iterate on `SKILL.md` description wording / heuristics for implement/refactor/review. If this changes the default headless path, it requires a *new* benchmark column, not an overwrite.
5. **If a new benchmark is wanted,** run it as a clearly-labeled new dataset (new worker/model/repo = new columns) using `BENCHMARK_PROMPT.md`, preserving the v1 results.
6. Optional polish: finalize the plugin/marketplace listing and the public install flow.

## Starting Prompt

Paste this into a fresh session:

> Read all files in this folder, especially README_CLAUDE.md, plus CLAUDE.md, ROADMAP.md, and benchmark/RESULTS.md. Confirm you understand the project (the delegate-coder skill + its A/B benchmark), its current status, the frozen v1 dataset and the "don't re-benchmark v2 / keep the default path byte-identical" rules, and my preference for honest, directional reporting. Then suggest the next steps before doing anything — and flag the `.env` secret. Do not run the benchmark or modify any benchmarked file without asking me first.
