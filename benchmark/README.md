# delegate-coder Benchmark Harness

Measures whether the delegate-coder skill reduces Claude credit usage while maintaining task success rate.

## Method: paired A/B comparison

Each task runs under two conditions, multiple times:

- **Condition A (baseline):** Claude Code alone — no skill installed
- **Condition B (with skill):** identical prompt, delegate-coder skill installed, worker agent available

Both conditions use `claude -p "<task>" --output-format json`, which reports token usage, cost (USD), duration, and turn count directly from Claude Code — this is the measurement instrument, no estimation involved.

## Metrics collected per run

| Metric | Source | What it tells you |
|---|---|---|
| `total_cost_usd` | claude JSON output | **Primary metric: credit consumption** |
| input/output tokens | claude JSON output | where the savings come from |
| `num_turns` | claude JSON output | orchestration overhead |
| `duration_ms` | claude JSON output | wall-clock cost of delegating |
| `success` | task's verify command (tests/lint) | **Primary metric: accuracy** |
| skill triggered | grep transcript for delegate.sh | triggering reliability |

## Requirements

1. Claude Code CLI installed and authenticated
2. Worker agent installed (e.g. `mimo`) and configured per the skill's setup.md
3. A target git repo with a working test suite (use a real project or a popular open-source repo)
4. `jq` installed

## Setup

1. Copy this `benchmark/` folder next to your target repo
2. Edit `tasks.json`: define 6–12 tasks against YOUR repo (see categories below) with a `verify` command each
3. Set vars at the top of `run_benchmark.sh` (repo path, skill path, runs per condition)

## Task categories (include all four for a credible claim)

- **bulk-read:** "Summarize the architecture of src/, list all modules and their dependencies" — measure this separately; the frozen v1 evidence shows a loss for delegated bulk reads.
- **implement:** "Add input validation to X with tests" — expect moderate savings
- **refactor:** "Rename concept X to Y across the codebase" — expect moderate savings
- **review:** "Review the diff between main and branch B, list issues" — expect large savings

For each task, `verify` must be objective: a command that exits 0 on success (test suite, lint, grep for expected symbol). Tasks without objective verification don't belong in the benchmark.

## Run

```bash
bash run_benchmark.sh          # runs all tasks x both conditions x N reps
python3 report.py results/     # aggregates into a summary table
```

The repo is hard-reset (`git reset --hard && git clean -fd`) before every run, so runs are independent. Order is interleaved (A,B,A,B) to spread any time-of-day model variance across conditions.

## Reading the results

`report.py` outputs, per task category and overall:

- mean cost USD (A vs B) and **% savings**
- success rate (A vs B) — savings only count if B's success rate is not worse
- mean duration and turns
- skill trigger rate in condition B (if the skill didn't trigger, that run measures nothing — investigate the description)

### Local contract benchmark (additive, never v1)

Contract mode is a separate local-Ollama execution path. The historical Claude+MiMo v1 `RESULTS.md` and `raw_data.jsonl` are frozen, unrelated to local-Qwen performance, and must not be overwritten. The additive path uses five warm repetitions per condition and records direct Ollama and contract-router conditions (plus an optional wrapper) with the same model, prompt, target, context, and output limits. It records prompt-evaluation time, generation time, total Ollama time, end-to-end time, success rate, and retry rate.

Run it against a clean committed target without writing into the frozen dataset:

```bash
TARGET_FILE=src/file.ts \
INSTRUCTIONS='precise bounded change with interfaces, invariants, forbidden changes, and test' \
TEST_COMMAND='npm test -- src/file.spec.ts' \
bash benchmark/run_local_contract.sh
python3 benchmark/local_contract_report.py benchmark/local-results-YYYYMMDD-HHMMSS/<run>.jsonl
python3 benchmark/test_local_contract_report.py
```

The reporter accepts arbitrary named conditions, including `C`, and deterministic fixtures are tested without a live model. Use a fresh `OUT_DIR`; the runner refuses to overwrite an existing output file and writes only there. The existing `report.py` remains the reporter for the frozen 48-run Claude A/B aggregate.

To reproduce that aggregate from the frozen JSONL (48 auxiliary/null rows are ignored and the 24 valid A plus 24 valid B task rows are included):

```bash
python3 benchmark/report.py benchmark/raw_data.jsonl benchmark/full_tasks.json
python3 benchmark/test_report.py
```

The one-run files under `benchmark/test_results/` are reporter fixtures only; they do not represent the 48-run dataset.

## Honest reporting guidance for distribution

- Run at least **3 reps** per task per condition (5 is better) — single runs are noise
- Report per-category numbers, not just the overall average; savings are not uniform. In the frozen v1 evidence, bulk-read cost approximately **20% more** and took approximately **3× longer** when delegated. Do not predict savings for a new worker from this unrelated dataset.
- Report the cases where the skill LOST too — that credibility is worth more than a cherry-picked headline number
- State the setup: Claude model used, worker agent + model, repo size, date
