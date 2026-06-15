#!/usr/bin/env bash
# run_benchmark.sh — A/B benchmark for the delegate-coder skill.
# A = baseline (no skill), B = with skill. Interleaved runs, hard reset between runs.
set -uo pipefail

# ===== configure these =====
REPO_DIR="${REPO_DIR:-$HOME/projects/target-repo}"   # target git repo
SKILL_SRC="${SKILL_SRC:-$HOME/.claude/skills/delegate-coder}"  # installed skill location
REPS="${REPS:-3}"                                     # runs per task per condition
MAX_TURNS="${MAX_TURNS:-40}"
BASE_COMMIT="${BASE_COMMIT:-HEAD}"                    # repo state to reset to before each run
# ===========================

HERE="$(cd "$(dirname "$0")" && pwd)"
TASKS="$HERE/tasks.json"
RESULTS="$HERE/results"
SKILL_DIR="$REPO_DIR/.claude/skills/delegate-coder"
SKILL_PARKED="$REPO_DIR/.claude/skills/.delegate-coder.off"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v claude >/dev/null || { echo "claude CLI is required"; exit 1; }
[ -f "$TASKS" ] || { echo "tasks.json not found"; exit 1; }
mkdir -p "$RESULTS"

skill_on()  { mkdir -p "$REPO_DIR/.claude/skills"; rm -rf "$SKILL_DIR"; cp -r "$SKILL_SRC" "$SKILL_DIR"; rm -rf "$SKILL_PARKED"; }
skill_off() { rm -rf "$SKILL_DIR" "$SKILL_PARKED"; }

reset_repo() {
  git -C "$REPO_DIR" reset --hard "$BASE_COMMIT" -q
  git -C "$REPO_DIR" clean -fdq -e .claude -e .mimocode
  rm -f "$REPO_DIR/.claude/delegate-coder.log"
  # remove any leftover delegate branches
  git -C "$REPO_DIR" branch --list 'delegate/*' | xargs -r git -C "$REPO_DIR" branch -D -q 2>/dev/null
}

run_one() { # run_one <task_id> <prompt> <verify> <condition A|B> <rep>
  local id="$1" prompt="$2" verify="$3" cond="$4" rep="$5"
  local out="$RESULTS/${id}_${cond}_${rep}.json"
  local txout="$RESULTS/${id}_${cond}_${rep}.transcript.json"
  [ -f "$out" ] && { echo "skip (exists): $id $cond #$rep"; return; }

  echo "=== $id | condition $cond | rep $rep ==="
  reset_repo
  if [ "$cond" = "B" ]; then skill_on; else skill_off; fi

  local t0 t1 claude_json
  t0=$(date +%s)
  claude_json=$(cd "$REPO_DIR" && claude -p "$prompt" --dangerously-skip-permissions --output-format json --max-turns "$MAX_TURNS" </dev/null 2>"$RESULTS/${id}_${cond}_${rep}.stderr" || true)
  t1=$(date +%s)

  if echo "$claude_json" | grep -q '"api_error_status":429' || { echo "$claude_json" | grep -q '"is_error":true' && echo "$claude_json" | grep -q '"total_cost_usd":0'; }; then
    echo "  -> RATE LIMITED — rerun later"
    rm -f "$RESULTS/${id}_${cond}_${rep}.stderr"
    return 0
  fi

  echo "$claude_json" > "$txout"

  # verify success in the repo (delegate branch may hold the changes in condition B)
  local success=0
  if [ "$cond" = "B" ]; then
    local dbranch
    dbranch=$(git -C "$REPO_DIR" branch --list 'delegate/*' --format='%(refname:short)' | head -n1)
    [ -n "$dbranch" ] && git -C "$REPO_DIR" checkout -q "$dbranch"
  fi
  ( cd "$REPO_DIR" && bash -c "$verify" ) >/dev/null 2>&1 && success=1

  # did the skill actually fire?
  local triggered=0
  [ -f "$REPO_DIR/.claude/delegate-coder.log" ] && triggered=1

  jq -n \
    --arg id "$id" --arg cond "$cond" --argjson rep "$rep" \
    --argjson success "$success" --argjson triggered "$triggered" \
    --argjson wall "$((t1-t0))" \
    --argjson cj "$( [ -n "$claude_json" ] && echo "$claude_json" | jq 'if type=="array" then last else . end' || echo '{}')" \
    '{task:$id, condition:$cond, rep:$rep, success:$success, skill_triggered:$triggered,
      wall_seconds:$wall,
      cost_usd:($cj.total_cost_usd // $cj.cost_usd // null),
      duration_ms:($cj.duration_ms // null),
      num_turns:($cj.num_turns // null),
      usage:($cj.usage // null)}' > "$out"
  echo "  -> success=$success triggered=$triggered cost=$(jq -r '.cost_usd' "$out")"
}

N_TASKS=$(jq '.tasks | length' "$TASKS")
for rep in $(seq 1 "$REPS"); do
  for i in $(seq 0 $((N_TASKS-1))); do
    id=$(jq -r ".tasks[$i].id" "$TASKS")
    prompt=$(jq -r ".tasks[$i].prompt" "$TASKS")
    verify=$(jq -r ".tasks[$i].verify" "$TASKS")
    # interleave conditions within each rep
    run_one "$id" "$prompt" "$verify" "A" "$rep"
    run_one "$id" "$prompt" "$verify" "B" "$rep"
  done
done

skill_off
reset_repo
echo "Done. Aggregate with: python3 report.py results/"
