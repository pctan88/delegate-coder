# Model matrix: qwen3.8:27b vs qwen3-coder:30b

Additive to `RESULTS.md` (frozen v1 Claude+MiMo data) — nothing here modifies it.

Date 2026-08-19 · Ollama 0.32.14 · Apple silicon, 36 GB · `num_ctx` 32768 · `temperature` 0
Raw data: `matrix-results/` (contract/, freeform-v2.jsonl, scaling.jsonl)

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
