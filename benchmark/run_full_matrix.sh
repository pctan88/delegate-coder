#!/usr/bin/env bash
# Sequential full matrix. Strictly one model resident at a time: two 17GB
# models will not co-reside in 36GB, so parallel runs would thrash.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-benchmark/matrix-results}"
mkdir -p "$OUT"

echo "===== PHASE 1/3: contract path (schema-constrained, the real delegate path) ====="
OUT_ROOT="$OUT/contract" REPS=5 \
  TASKS="T1_simple T2_algorithmic T3_refactor" \
  CONFIGS='qwen3-coder:30b qwen3.8:27b|false' \
  bash benchmark/run_model_matrix.sh

echo "===== PHASE 2/3: free-form path (no schema, so thinking actually engages) ====="
python3 benchmark/freeform_probe.py --mode freeform --reps 3 \
  --tasks T1-simple-edit T2-algorithmic T3-refactor S-bigmod-med \
  --configs 'qwen3-coder:30b|unset' 'qwen3.8:27b|off' 'qwen3.8:27b|on' \
  --out "$OUT/freeform.jsonl"

echo "===== PHASE 3/3: context scaling (whole-file fidelity, contract-style) ====="
python3 benchmark/freeform_probe.py --mode scaling --reps 2 \
  --tasks S-bigmod-med S-bigmod-large \
  --configs 'qwen3-coder:30b|unset' 'qwen3.8:27b|false' \
  --out "$OUT/scaling.jsonl"

echo "===== FULL MATRIX COMPLETE: $OUT ====="
