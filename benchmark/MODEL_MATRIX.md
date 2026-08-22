# Model matrix: qwen3.8:27b vs qwen3-coder:30b

Additive to `RESULTS.md` (frozen v1 Claude+MiMo data) — nothing here modifies it.

Date 2026-08-19 · Ollama 0.32.14 · Apple silicon, 36 GB · `num_ctx` 32768 · `temperature` 0
Raw data: `matrix-results/` (contract/, freeform-v2.jsonl, scaling.jsonl)

`matrix-results/freeform-v1-DISCARDED-harness-bug.jsonl` is retained for
provenance only — **do not read its numbers.** That run scored
`qwen3-coder:30b` as SYNTAX_FAIL 3/3 on two tasks because the probe's
code-fence extractor could not parse a fence whose info line carried echoed
prompt text (```` ```python code fence. ````), so it syntax-checked the fence
itself. The model's output was correct. `freeform-v2.jsonl` is the valid run,
after the extractor was fixed and unit-tested against six fence shapes.

## Verdict

**Keep `qwen3-coder:30b` as the delegate worker.** 44/44 measured runs passed for
both models — correctness was identical everywhere. The only consistent
difference is speed, favouring the incumbent by 2.2–3.5x on schema-constrained
work.

Mechanism: `qwen3-coder:30b` is sparse MoE (`qwen3moe`, 30.5 B total, a fraction
active per token, ~91 tok/s observed). `qwen3.8:27b` is dense (`qwen35`, 27.3 B,
every parameter per token, ~47 tok/s).

## Routing

| Task | Route to | Why |
|---|---|---|
| Contract-mode implementation & refactor (to ~10 KB) | `qwen3-coder:30b` | Equal correctness, 2.2–3.5x faster |
| Anything with images or screenshots | `qwen3.8:27b` | Only local option — coder30b has no vision |
| Free-form reasoning, no output schema | `qwen3.8:27b` `think=on` | Genuinely reasons; ~3x its own no-think cost, 11–14x coder30b |
| Whole-file regeneration above ~10 KB | `qwen3-coder:30b` | Perfect fidelity at 92 functions, half the wall time; raise `OUTPUT_HEADROOM` |
| Final or security-sensitive review | Sonnet subagent | Unchanged; neither local model evaluated for severity judgement |

## Key finding: thinking is inert under a JSON schema

With Ollama's `format` schema active, `think:true` and `think:false` produce
**byte-identical** output (570 tokens, 2014 chars) — the grammar constrains the
whole generation. Thinking yields no extra reasoning; it only changes which
field the answer lands in (`thinking` instead of `response`), which empties
`response` and fails the contract parse.

Consequence: **the contract path cannot benefit from reasoning at all.** Any
delegate work routed through contract mode gets dense-model cost with zero
reasoning upside. Reasoning only engages when `format` is absent (Phase 2,
760–3800 chars of thinking).

## Three root causes behind the original 0/10

| # | Cause | Affects | Fix |
|---|---|---|---|
| 1 | Thinking on by default; answer lands in `thinking`, `response` empty | qwen3.8, any schema-constrained call | `THINK=false` / `DELEGATE_THINK=false` |
| 2 | Bare `python` is a pyenv shim exiting 127; router read *command not found* as a syntax error | **both models** | interpreter usability probe, prefer `python3` |
| 3 | `file_size/3 + 256` output estimate too tight for a verbose model | qwen3.8 small files; coder30b large files | `OUTPUT_HEADROOM` / `DELEGATE_OUTPUT_HEADROOM` |

Cause 2 was silently invalidating the contract comparison for both models —
`qwen3-coder:30b` reproduced the same `PREFLIGHT_FAIL` exit 127.

Cause 3 evidence: T2 direct 0/5 → 5/5 with `OUTPUT_HEADROOM=2048`. The 10.3 KB
target truncated coder30b at `eval_count` 3931 = its budget exactly, then passed
at 3954 once raised.

## Results

Phase 1 — contract path (schema-constrained, the production route), 5 reps,
median E2E, contract condition. All 5/5 PASS.

| Task | coder30b | qwen3.8 think=false | Gap |
|---|---|---|---|
| T1 simple bounded edit | 8.3s | 21.5s | 2.6x |
| T2 algorithmic (month-end clamping) | 6.6s | 23.1s | 3.5x |
| T3 multi-function refactor | 10.8s | 27.5s | 2.5x |

Phase 2 — free-form (no schema), 3 reps, median. All 3/3 PASS.

| Task | coder30b | qwen3.8 off | qwen3.8 ON | reasoning |
|---|---|---|---|---|
| T1 | 5.0s | 22.0s | 68.4s | 3777 ch |
| T2 | 3.8s | 16.5s | 52.2s | 2320 ch |
| T3 | 5.6s | 24.1s | 60.9s | 3605 ch |
| 3.9 KB / 34 fn | 16.8s | 50.6s | 58.2s | 761 ch |

Phase 3 — whole-file fidelity, 2 reps, median. All 2/2 PASS, zero helper drift.

| Target | coder30b | qwen3.8 |
|---|---|---|
| 3.9 KB / 34 fn | 20.2s | 54.1s |
| 10.3 KB / 92 fn | 68.0s | 141.3s |

## Limitations — read before trusting the verdict

- **The suite did not discriminate on correctness.** All 44 runs passed, so the
  finding is bounded: thinking showed no benefit *on work coder30b already
  handles*. This is not evidence that thinking never helps. Finding qwen3.8's
  real advantage needs tasks coder30b actually fails — multi-file reasoning,
  ambiguous specs, genuine debugging.
- Context capped at `num_ctx` 32768 throughout, well under both models'
  advertised 262 K and under the standing 64 K Ollama ceiling.
- Vision never exercised, though it is qwen3.8's one categorical advantage.

## Reproducing

```bash
bash benchmark/run_full_matrix.sh          # all three phases, ~50 min, sequential
```

Sequential is required: two 17 GB models will not co-reside in 36 GB.

Task tiers live in `benchmark/model_matrix_tasks.sh`; fixtures and checkers in
`benchmark/fixtures/`. Each checker is validated in both directions — it fails
on the unmodified fixture and passes against a reference implementation.

---

# Follow-up: edit format (whole-file vs targeted patches)

Date 2026-08-22 · `qwen3-coder:30b` · 3 reps · raw data `matrix-results/patch.jsonl`

Whole-file contract mode pays a ~99% re-transcription tax (bigmod_large emitted
3954 tokens to express ~23 tokens of change). This tests whether the worker can
instead emit exact-match edits — the open question being whether a local model
can reproduce anchor text byte-for-byte.

**It can, in the right format.**

| Format | Result |
|---|---|
| Aider-style `<<<<<<< SEARCH` fences | **15/15 PASS** |
| Schema-constrained JSON `{"edits":[…]}` | 10/15 PASS |

The JSON variant loses because the anchor must survive JSON escaping. Its two
failure modes were an anchor that never matched (T3: 5 of 7 edits applied, so
`mark_done` was never added) and, on bigmod-med, a *wrong implementation* —
`compute_summary` returned 4 instead of the median 3.5, the classic
`sorted(v)[len(v)//2]` bug on an even-length list. The fenced format got both right.

## The win scales with file size

| Task | Source | Whole-file | Patch (blocks) | Speedup | Tokens cut |
|---|---|---|---|---|---|
| T1 simple edit | 1413 B | 8.3s / 570 tok | 5.8s / 505 tok | 1.4x | 1.1x |
| T2 algorithmic | 732 B | 6.6s / 439 tok | 3.9s / 321 tok | 1.7x | 1.4x |
| T3 refactor | 1413 B | 10.8s / 570 tok | 11.3s / 863 tok | **1.0x** | **0.7x** |
| bigmod-med | 3928 B | 20.2s / 1528 tok | 2.4s / 124 tok | 8.4x | 12.3x |
| bigmod-large | 10257 B | 68.0s / 3954 tok | **1.8s / 124 tok** | **37.6x** | 31.9x |

**Patch output is roughly constant** — 124 tokens for both a 3.9 KB and a 10.3 KB
file — while whole-file output grows linearly with the file. So the crossover sits
around 2 KB, and beyond it the advantage compounds.

**T3 is the honest exception:** a diffuse multi-part refactor touches so many
places that the edits approach the size of the file, and patch mode is *slower*
(11.3s vs 10.8s) and more verbose. Patch mode wins for localised change, not for
rewrites.

## It also raises the size ceiling

Because the output no longer scales with the file, the binding constraint becomes
the prompt:

| | whole-file | patch |
|---|---|---|
| `num_ctx` 32768 | ~23 KB | ~95 KB |
| `num_ctx` 65536 | ~46 KB | ~191 KB |

## Recommendation

Adopt the fenced SEARCH/REPLACE format for targets above ~2 KB; keep whole-file
for small files and for diffuse rewrites. Contract mode's existing test gate and
single retry are what make this safe — a bad anchor fails the test and reverts,
rather than silently corrupting the file.

Not yet integrated into `contract-router.sh`; `patch_probe.py` is a probe only.

## Caveats

- One model, 3 reps, `temperature` 0. Low variance, limited generality.
- Anchor failures were common even when the task passed: T1's JSON variant lost
  1 of 3 edits every rep and still passed, because the applied edits sufficed.
  Partial application is a yellow flag that a pass/fail metric hides.
- Matching is plain substring with a uniqueness requirement — the generous
  reading, chosen to measure the model's ceiling rather than penalise valid
  mid-line anchors.
