# Delegate-Coder Skill Benchmark Results

**Date**: 2026-06-14
**Claude model (orchestrator)**: `claude-sonnet-4-6` (Anthropic API, via Claude Code `-p`)
**Worker agent**: `mimo 0.1.0` (underlying model not independently verified — see Limitations)
**Target repository**: `commander.js` @ `ba6d13ddb4243e5913367734f8c159089ffe7834`
**Design**: A (no skill) vs B (skill installed), 8 tasks × 2 conditions × 3 reps = 48 sessions, interleaved, hard `git reset` between runs.

---

## Headline

Installing the skill produced a **~11% reduction in cost per successful task** ($0.493 → $0.440) across the suite. That number is an *intent-to-treat* result: the skill was available in condition B but **only chose to delegate in 10 of 24 runs (42%)**, and very unevenly by category. The savings come from a few heavy execution tasks; they are partly offset by a clear loss on bulk codebase reading.

**This run should be read as directional, not conclusive.** With n=3 per cell and high run-to-run variance, and with delegation firing in only 1 of 4 categories reliably, per-category effects outside bulk-read are under-powered.

---

## Why raw category averages mislead here

In 3 of 4 categories the skill rarely fired, so "condition B" is mostly "condition A with occasional delegation." A naive category mean then blends delegated runs, non-delegated runs, and the trivial control together and produces savings/losses that are **not caused by delegation**. The table below separates trigger states. The only fair causal comparison is **task-matched A vs B-when-delegated**.

| Category | Trigger rate (B) | A mean $ | B mean $ (all) | B mean $ (delegated only) | Mean wall A/B (s) | Read |
|---|---|---|---|---|---|---|
| bulk-read | **6/6** | 0.285 | 0.341 | 0.341 | 154 / 480 | Clean comparison → **loss** |
| implement | 2/6 | 0.463 | — | 0.502 (n=2) | 174 / 299 | Category mean confounded by trivial control |
| refactor | 1/6 | 0.439 | — | 0.282 (n=1) | 320 / 250 | Inconclusive |
| review | 1/6 | 0.703 | — | 0.216 (n=1) | 323 / 267 | Delegation essentially didn't happen |
| **Overall** | **10/24 (42%)** | 0.473 | 0.403 | — | 243 / 324 | per-attempt −15% / **per-success −11%** |

Task-matched, delegated-only comparisons (the causal numbers):

| Task | A mean $ | B delegated $ | Δ | n (B deleg.) |
|---|---|---|---|---|
| implement-exclusive-option | 0.794 | 0.502 | **−37%** | 2 |
| refactor-error | 0.662 | 0.282 | **−57%** | 1 |
| bulkread-architecture | 0.201 | 0.187 | −7% | 3 |
| bulkread-parse-flow | 0.370 | 0.496 | **+34%** | 3 |
| review-option | 0.159 | 0.216 | +36% | 1 |

---

## Findings

### 1. Bulk reading is a real loss (strongest result)
Bulk-read is the only category where the skill fired every time (6/6), so the comparison is clean. Delegating codebase reading to the worker cost **~20% more** and ran **~3× slower** (154s → 480s mean). The effect scales with task heaviness: the light `architecture` summary was roughly break-even (−7%), but the heavier `parse-flow` trace cost +34% and took 9–16 minutes per delegated run.

This **contradicts the skill's own pitch**, which lists "bulk codebase reading/analysis" as a primary use. With mimo as the worker, that use is counterproductive. Recommended follow-up: drop bulk-read from the skill's recommended modes, or test a faster worker for read-only tasks.

### 2. Heavy execution tasks do benefit — but small-sample
Task-matched, delegating genuine implementation and refactoring work saved cost: `implement-exclusive-option` −37% (n=2 delegated runs), `refactor-error` −57% (n=1). These are the source of the positive overall number. They are directionally encouraging but rest on very few delegated runs.

### 3. Review is inconclusive — and the earlier "context-loss" reading was wrong
`review-diff` never delegated (0/3); `review-option` delegated once (and that run **passed**). So delegation barely happened in review, and no causal claim about review cost or quality is supportable. The dip in review success (A 5/6 → B 4/6) is **not** a delegation effect: both failed B runs had `skill_triggered=0` (3 turns, ~$0.15 — Claude produced a review too short to pass the ≥10-line / `file:line` verify). The single *delegated* review succeeded. The failure is a flaky task/verify, not lost context.

### 4. Trivial control behaves correctly
`implement-ping` delegated 0/6 — the skill correctly declined to hand a one-line stub to the worker. This validates selective triggering as a *feature*. Note that even when it declined, condition B was slightly more expensive than A ($0.208 vs $0.133): considering-then-declining carries a small overhead.

### 5. Selective, uneven triggering is the core behavioral finding
Trigger rate by category: bulk-read 100%, implement 33%, refactor 17%, review 17%. The skill delegates heavy reads readily but is reluctant on implementation/refactor/review at these task sizes. Whether that reluctance is correct (it avoids overhead) or a tuning gap (it skips delegable work) is the open question for v2.

---

## Limitations

- **Statistical power**: n=3 per cell with large variance (e.g. `review-diff` condition A spanned $0.91–$1.75; one `refactor-error` A run took 1157s vs 258s for another). Per-category differences are not statistically significant; treat all numbers as directional.
- **Low/uneven trigger rate**: 42% overall, and only bulk-read fired reliably. The experiment therefore under-tested its own hypothesis for 3 of 4 categories. A stronger follow-up would raise delegated-sample counts before drawing category conclusions.
- **Worker model unverified**: the worker is `mimo 0.1.0`; its underlying model was not independently confirmed and is intentionally not asserted here. The benchmark measures "mimo as worker," whatever it runs.
- **Tooling**: `report.py` emitted interleaved `null` records in the dump and a broken `num_turns` field (a 1157s/$0.86 run reported `num_turns=1`). Cosmetic for the aggregates, but should be fixed before this is a published artifact.
- **Cost basis**: orchestrator (Claude) cost only. Worker-side cost (mimo free tier) is not included; on a paid worker the economics change.

---

### Notes:
- **v2 Enhancement Caveat**: After this benchmark run, a behavior-preserving "Scope guard" was added to `SKILL.md` (which acts as a no-op when no config is set), meaning the current `SKILL.md` differs slightly from the exact bytes benchmarked here.
- 'Savings' = Claude cost reduction in condition B. Worker-agent cost is assumed free tier;
  if your worker uses a paid API, add its cost manually before claiming net savings.
- A claim is only valid where 'Succ B' >= 'Succ A'. Cheaper-but-wrong is not savings.
- 'Trig B' < 100% means the skill sometimes didn't fire; those runs dilute condition B.
- With reps < 3 treat every number as anecdote, not evidence.

## Triggering required description tuning (publishable finding)

The skill did not trigger at all under its original description. Rewriting the frontmatter `description` was necessary to get any delegation in headless runs.

**Original:**
> Orchestrate a second CLI coding agent (MiMo Code, Aider, Codex CLI, Gemini CLI, OpenCode, Qwen Code, etc.) as a worker to save Claude usage. Claude does the planning, architecture, and review decisions; the worker agent does codebase reading, implementation, and first-pass review. Use this skill whenever the user asks to delegate coding work to another agent/model, mentions saving tokens or usage by offloading tasks, references "mimo", "aider", "codex", "gemini cli", "worker agent", or "sub-agent model", or when a configured delegate agent exists in the project (.claude/delegate-coder.json or DELEGATE_AGENT env var) and the task involves implementation, large codebase analysis, or routine refactoring.

**Final (used for all 48 runs):**
> Use for ANY implementation, refactoring, bulk codebase reading/analysis, or code review task. If this skill is installed in a project, the user has chosen to delegate execution-heavy work by default — do not do bulk reading or routine implementation yourself. Orchestrate a second CLI coding agent (MiMo, Aider, Codex, Gemini, etc.) as a worker to save usage. Also trigger if the user asks to delegate coding work, mentions saving tokens/usage, or references "mimo", "aider", "codex", "gemini cli", "worker agent", or "sub-agent model".

Leading with task types and stating that installation implies intent moved bulk-read triggering to 100%, but implementation/refactor/review triggering remained low — so description wording alone did not fully solve selective triggering.

Note also that the trigger *metric* itself was fixed during development: the original `grep "delegate.sh"` on the JSON transcript always read 0 because Claude Code's JSON output omits intermediate bash calls. It was replaced by a worker-written audit log (`.claude/delegate-coder.log`), cleared in `reset_repo`, checked for existence after each run. This both fixed the metric and shipped a useful audit feature.

---

## Raw data (48 records)

```json
{"task":"bulkread-architecture","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.2090902,"wall_seconds":63}
{"task":"bulkread-architecture","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.1870864,"wall_seconds":80}
{"task":"bulkread-architecture","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.2067816,"wall_seconds":125}
{"task":"bulkread-architecture","condition":"B","rep":1,"success":1,"skill_triggered":1,"cost_usd":0.1551945,"wall_seconds":167}
{"task":"bulkread-architecture","condition":"B","rep":2,"success":1,"skill_triggered":1,"cost_usd":0.1693834,"wall_seconds":363}
{"task":"bulkread-architecture","condition":"B","rep":3,"success":1,"skill_triggered":1,"cost_usd":0.23563205,"wall_seconds":120}
{"task":"bulkread-parse-flow","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.29743075,"wall_seconds":87}
{"task":"bulkread-parse-flow","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.3578042,"wall_seconds":223}
{"task":"bulkread-parse-flow","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.45475765,"wall_seconds":345}
{"task":"bulkread-parse-flow","condition":"B","rep":1,"success":1,"skill_triggered":1,"cost_usd":0.5736856,"wall_seconds":649}
{"task":"bulkread-parse-flow","condition":"B","rep":2,"success":1,"skill_triggered":1,"cost_usd":0.44290145,"wall_seconds":592}
{"task":"bulkread-parse-flow","condition":"B","rep":3,"success":1,"skill_triggered":1,"cost_usd":0.47159195,"wall_seconds":991}
{"task":"implement-exclusive-option","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.75513665,"wall_seconds":198}
{"task":"implement-exclusive-option","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.72289355,"wall_seconds":254}
{"task":"implement-exclusive-option","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.90332445,"wall_seconds":380}
{"task":"implement-exclusive-option","condition":"B","rep":1,"success":1,"skill_triggered":1,"cost_usd":0.59162025,"wall_seconds":377}
{"task":"implement-exclusive-option","condition":"B","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.30920645,"wall_seconds":652}
{"task":"implement-exclusive-option","condition":"B","rep":3,"success":1,"skill_triggered":1,"cost_usd":0.41277375,"wall_seconds":522}
{"task":"implement-ping","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.12994595,"wall_seconds":50}
{"task":"implement-ping","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.14507495,"wall_seconds":75}
{"task":"implement-ping","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.12367535,"wall_seconds":85}
{"task":"implement-ping","condition":"B","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.28723085,"wall_seconds":55}
{"task":"implement-ping","condition":"B","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.1799141,"wall_seconds":88}
{"task":"implement-ping","condition":"B","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.1573187,"wall_seconds":99}
{"task":"refactor-error","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.86392635,"wall_seconds":1157}
{"task":"refactor-error","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.60989825,"wall_seconds":282}
{"task":"refactor-error","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.51317045,"wall_seconds":258}
{"task":"refactor-error","condition":"B","rep":1,"success":1,"skill_triggered":1,"cost_usd":0.28213205,"wall_seconds":551}
{"task":"refactor-error","condition":"B","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.9083018,"wall_seconds":324}
{"task":"refactor-error","condition":"B","rep":3,"success":1,"skill_triggered":0,"cost_usd":1.0389779,"wall_seconds":365}
{"task":"refactor-rename-help","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.1652209,"wall_seconds":43}
{"task":"refactor-rename-help","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.2639053,"wall_seconds":95}
{"task":"refactor-rename-help","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.21611825,"wall_seconds":87}
{"task":"refactor-rename-help","condition":"B","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.19214125,"wall_seconds":117}
{"task":"refactor-rename-help","condition":"B","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.18059615,"wall_seconds":82}
{"task":"refactor-rename-help","condition":"B","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.1639879,"wall_seconds":64}
{"task":"review-diff","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":1.08951625,"wall_seconds":438}
{"task":"review-diff","condition":"A","rep":2,"success":1,"skill_triggered":0,"cost_usd":1.7456289,"wall_seconds":594}
{"task":"review-diff","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.9086523,"wall_seconds":552}
{"task":"review-diff","condition":"B","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.9676618,"wall_seconds":436}
{"task":"review-diff","condition":"B","rep":2,"success":1,"skill_triggered":0,"cost_usd":0.55715495,"wall_seconds":353}
{"task":"review-diff","condition":"B","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.86979905,"wall_seconds":358}
{"task":"review-option","condition":"A","rep":1,"success":1,"skill_triggered":0,"cost_usd":0.15843165,"wall_seconds":120}
{"task":"review-option","condition":"A","rep":2,"success":0,"skill_triggered":0,"cost_usd":0.18327705,"wall_seconds":139}
{"task":"review-option","condition":"A","rep":3,"success":1,"skill_triggered":0,"cost_usd":0.13524575,"wall_seconds":95}
{"task":"review-option","condition":"B","rep":1,"success":1,"skill_triggered":1,"cost_usd":0.21629805,"wall_seconds":234}
{"task":"review-option","condition":"B","rep":2,"success":0,"skill_triggered":0,"cost_usd":0.13489145,"wall_seconds":93}
{"task":"review-option","condition":"B","rep":3,"success":0,"skill_triggered":0,"cost_usd":0.18255145,"wall_seconds":129}
```

*Aggregates exclude the trivial control (`implement-ping`) from causal cost claims; it is reported separately as a triggering-behavior check.*
