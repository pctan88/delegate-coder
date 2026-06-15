# delegate-coder — repo guide for Claude Code

This repo contains a Claude Code skill (`skills/delegate-coder/`) that delegates execution-heavy coding work to a cheaper worker agent (MiMo, Aider, Codex CLI, Gemini CLI, Qwen Code, OpenCode), and an A/B benchmark harness (`benchmark/`) that measures whether the skill reduces Claude credit usage without hurting accuracy.

## Layout

- `skills/delegate-coder/` — the skill: SKILL.md (orchestration workflow), scripts/delegate.sh (universal adapter), scripts/detect.sh (worker detection), references/ (per-agent commands, setup)
- `benchmark/run_benchmark.sh` — A/B runner: condition A = no skill, condition B = skill installed; interleaved, hard git reset between runs
- `benchmark/tasks.json` — task definitions (currently EXAMPLE placeholders — must be adapted to the target repo before running)
- `benchmark/report.py` — aggregates `benchmark/results/*.json` into the publishable table
- `benchmark/README.md` — full methodology; read it before running

## How to run the benchmark (the main job)

1. **Check prerequisites.** All must pass before anything else:
   - `claude --version` (Claude Code CLI, authenticated)
   - `jq --version`
   - A worker agent installed — run `bash skills/delegate-coder/scripts/detect.sh`. If none found, stop and tell the user; the benchmark is meaningless without one.
2. **Confirm the target repo with the user.** It must be a local git repo with a fast, reliable test suite. Never assume; ask. Clone it fresh if needed. Record its path, base commit, and test command.
3. **Adapt `benchmark/tasks.json`** to the target repo: 6–12 tasks covering all four categories (bulk-read, implement, refactor, review). Every `verify` command must exit 0 on success and be objective (tests/lint/grep). Replace ALL example tasks — they reference files that don't exist in the target repo.
4. **Smoke run first.** `REPS=1` with 1–2 tasks to validate wiring before the full run. Each run is a full `claude -p` session and consumes real Claude usage — do not launch the full matrix until the smoke run produces sane JSON in `benchmark/results/`.
5. **Full run:**
   ```bash
   cd benchmark
   REPO_DIR=/path/to/target-repo \
   SKILL_SRC=$(pwd)/../skills/delegate-coder \
   REPS=3 \
   bash run_benchmark.sh
   ```
   Long-running: tasks × 2 conditions × REPS full sessions. Resumable — completed runs are skipped, so it's safe to re-invoke.
6. **Report:** `python3 report.py results/ tasks.json`. Save the output table to `benchmark/RESULTS.md` together with: Claude model used, worker agent + model, target repo + commit, date, REPS.

## Rules

- Never edit `run_benchmark.sh` methodology (interleaving, reset, verify) without asking — it exists to keep the comparison fair.
- Per-category results matter more than the overall average. Report losses as well as wins.
- The skill install target during condition B is `$REPO_DIR/.claude/skills/delegate-coder` — the harness manages this; don't pre-install the skill into the target repo yourself.
- If `success=0` or `triggered=0` dominates condition B, stop and investigate (verify command wrong? skill description not triggering?) instead of burning reps.
