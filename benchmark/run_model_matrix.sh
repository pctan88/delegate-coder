#!/usr/bin/env bash
# Additive model-matrix driver: each task tier x each worker model, through the
# repo's own local-contract harness. Writes only into OUT_ROOT.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source benchmark/model_matrix_tasks.sh

OUT_ROOT="${OUT_ROOT:-benchmark/matrix-results}"
REPS="${REPS:-5}"
TASKS="${TASKS:-T1_simple T2_algorithmic T3_refactor}"
# "model[:THINK]" — THINK omitted means send no think field at all.
CONFIGS="${CONFIGS:-qwen3-coder:30b qwen3.8:27b|false}"

mkdir -p "$OUT_ROOT"
for task in $TASKS; do
  "task_$task"
  for config in $CONFIGS; do
    model="${config%%|*}"
    think=""
    [[ "$config" == *"|"* ]] && think="${config##*|}"
    slug="$(printf '%s' "$model" | tr -c 'A-Za-z0-9._-' '-')${think:+-think$think}"
    out_dir="$OUT_ROOT/$LABEL--$slug"
    rm -rf "$out_dir"
    echo "### $LABEL | model=$model think=${think:-<unset>} ###"
    if LABEL="$LABEL" TARGET_FILE="$TARGET_FILE" INSTRUCTIONS="$INSTRUCTIONS" \
       TEST_COMMAND="$TEST_COMMAND" REPS="$REPS" MODEL="$model" THINK="$think" \
       OUT_DIR="$out_dir" bash benchmark/run_local_contract.sh >"$out_dir.log" 2>&1; then
      python3 benchmark/local_contract_report.py "$out_dir"/*.jsonl | tail -n +2
    else
      echo "  HARNESS ERROR (see $out_dir.log)"; tail -3 "$out_dir.log" | sed 's/^/    /'
    fi
    echo
  done
done
echo "Matrix complete: $OUT_ROOT"
