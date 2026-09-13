#!/usr/bin/env bash
# stats.sh — summarize delegate-coder audit logs across files and worktrees.
# Usage:
#   stats.sh [path/to/.claude/delegate-coder.log ...]
#   stats.sh --fleet [--json]
#   stats.sh --json [path/to/.claude/delegate-coder.log ...]
set -u

FLEET_MODE=false
JSON_MODE=false
SINCE_FILTER=""
LOG_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fleet|--all)
      FLEET_MODE=true
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --since)
      if [[ $# -lt 2 ]]; then
        echo "stats.sh: --since requires a duration argument (e.g. 24h, 7d)" >&2
        exit 1
      fi
      SINCE_FILTER="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: stats.sh [--fleet] [--json] [--since <N>h|<N>d] [log_files...]"
      echo "  --fleet, --all          Discover and aggregate logs across fleet log or git worktrees"
      echo "  --json                  Output aggregate statistics in JSON format"
      echo "  --since <N>h|<N>d       Filter records within the last N hours or days"
      exit 0
      ;;
    *)
      LOG_FILES+=("$1")
      shift
      ;;
  esac
done

# If fleet mode requested, prefer central fleet log if it exists, else discover across worktrees/siblings
if [[ "$FLEET_MODE" == true ]]; then
  fleet_log="${DELEGATE_FLEET_LOG:-${HOME:-}/.delegate-coder/fleet.jsonl}"
  if [[ -f "$fleet_log" && -s "$fleet_log" ]]; then
    LOG_FILES+=("$fleet_log")
  else
    discovered=()
    # 1. Current directory / git root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$git_root" ]]; then
      # Discover git worktrees
      while IFS= read -r wt_line; do
        wt_path="$(printf '%s' "$wt_line" | awk '{print $1}')"
        if [[ -f "$wt_path/.claude/delegate-coder.log" ]]; then
          discovered+=("$wt_path/.claude/delegate-coder.log")
        fi
      done < <(git -C "$git_root" worktree list 2>/dev/null || true)

      # Check parent directory siblings for sibling repos or worktrees (depth 3)
      parent_dir="$(dirname "$git_root")"
      if [[ -d "$parent_dir" ]]; then
        while IFS= read -r sibling_log; do
          [[ -n "$sibling_log" ]] && discovered+=("$sibling_log")
        done < <(find "$parent_dir" -maxdepth 3 -type f -name "delegate-coder.log" -path "*/.claude/*" 2>/dev/null || true)
      fi
    else
      # Outside git: check current dir and subdirs
      while IFS= read -r local_log; do
        [[ -n "$local_log" ]] && discovered+=("$local_log")
      done < <(find . -maxdepth 3 -type f -name "delegate-coder.log" -path "*/.claude/*" 2>/dev/null || true)
    fi

    # Deduplicate discovered paths
    if [[ ${#discovered[@]} -gt 0 ]]; then
      while IFS= read -r unique_file; do
        [[ -n "$unique_file" ]] && LOG_FILES+=("$unique_file")
      done < <(printf '%s\n' "${discovered[@]}" | sort -u)
    fi
  fi
fi

# Default fallback if no files specified
if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
  LOG_FILES=(".claude/delegate-coder.log")
fi

# Filter existing files
EXISTING_LOGS=()
for f in "${LOG_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    EXISTING_LOGS+=("$f")
  fi
done

if [[ ${#EXISTING_LOGS[@]} -eq 0 ]]; then
  if [[ "$JSON_MODE" == true ]]; then
    echo '{"total_delegations":0,"completions_logged":0,"logical_tasks":0,"execution_attempts":0,"pass_count":0,"fail_count":0,"pass_rate_pct":0.0,"agents":{},"modes":{},"statuses":{},"tokens":{"total_prompt_tokens":0,"total_completion_tokens":0,"total_tokens":0},"files":[]}'
  else
    echo "No audit log found at: ${LOG_FILES[*]}"
    echo "The log is created automatically when delegate.sh runs."
  fi
  exit 0
fi

# Ensure Python 3 or jq is available
if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
  echo "stats.sh: python3 or jq is required for parsing audit logs." >&2
  exit 1
fi

# Prefer Python engine for robust multi-file stream aggregation, task deduplication, and schema validation
if command -v python3 >/dev/null 2>&1; then
  python3 - "$JSON_MODE" "$SINCE_FILTER" "${EXISTING_LOGS[@]}" <<'PY'
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta

json_mode = sys.argv[1].lower() == "true"
since_str = sys.argv[2].strip()
log_files = sys.argv[3:]

cutoff_dt = None
if since_str:
    val_str = since_str[:-1]
    unit = since_str[-1].lower()
    try:
        val = float(val_str)
        if unit == "h":
            cutoff_dt = datetime.now(timezone.utc) - timedelta(hours=val)
        elif unit == "d":
            cutoff_dt = datetime.now(timezone.utc) - timedelta(days=val)
        elif unit == "m":
            cutoff_dt = datetime.now(timezone.utc) - timedelta(minutes=val)
        else:
            sys.stderr.write(f"stats.sh: unsupported --since unit in '{since_str}' (use 'h' or 'd')\n")
            sys.exit(1)
    except ValueError:
        sys.stderr.write(f"stats.sh: invalid --since duration '{since_str}'\n")
        sys.exit(1)

def parse_iso_ts(ts_str):
    if not ts_str or not isinstance(ts_str, str):
        return None
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except Exception:
        return None

start_records = []
end_records = []
legacy_count = 0

for file_path in log_files:
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line_str = line.strip()
                if not line_str:
                    continue
                if not line_str.startswith("{"):
                    legacy_count += 1
                    continue
                try:
                    record = json.loads(line_str)
                except Exception:
                    continue
                if cutoff_dt is not None:
                    rec_ts = parse_iso_ts(record.get("ts"))
                    if rec_ts is not None and rec_ts < cutoff_dt:
                        continue
                event = record.get("event")
                if event == "start":
                    start_records.append(record)
                elif event == "end":
                    end_records.append(record)
    except Exception:
        continue

total_start = len(start_records)
total_end = len(end_records)

# Logical tasks vs execution attempts
# Group runs by task_id if available; fallback to run_id or distinct start/end
tasks = defaultdict(list)
for r in end_records:
    tid = r.get("task_id") or r.get("run_id") or f"untracked-{len(tasks)}"
    tasks[tid].append(r)

# If no end records but start records exist
if not end_records and start_records:
    for r in start_records:
        tid = r.get("task_id") or r.get("run_id") or f"untracked-start-{len(tasks)}"
        tasks[tid].append(r)

logical_tasks_count = len(tasks)
execution_attempts_count = total_end

# Aggregate metrics
agent_mode_stats = defaultdict(lambda: {
    "count": 0,
    "success": 0,
    "failed": 0,
    "total_duration": 0,
    "statuses": defaultdict(int),
    "prompt_tokens": 0,
    "completion_tokens": 0
})

status_counts = defaultdict(int)
total_prompt_tokens = 0
total_completion_tokens = 0
total_success = 0
total_failed = 0

for r in end_records:
    agent = r.get("agent") or "unknown"
    mode = r.get("mode") or "unknown"
    key = (agent, mode)
    stats = agent_mode_stats[key]
    stats["count"] += 1

    status = r.get("status")
    exit_code = r.get("exit_code")

    # If status is not set, derive from exit_code
    if not status:
        status = "PASS" if exit_code == 0 else "FAIL"

    stats["statuses"][status] += 1
    status_counts[status] += 1

    is_pass = (status in ("PASS", "NOOP")) or (exit_code == 0 and status not in ("TEST_FAIL", "TIMEOUT", "PREFLIGHT_FAIL", "WORKER_START_FAIL", "DEPENDENCY_GUARD_FAIL", "RESTORE_FAIL", "ERROR"))
    if is_pass:
        stats["success"] += 1
        total_success += 1
    else:
        stats["failed"] += 1
        total_failed += 1

    dur = r.get("duration_s")
    if isinstance(dur, (int, float)):
        stats["total_duration"] += dur

    # Token accounting (Ollama metrics)
    pt = r.get("prompt_eval_count")
    ct = r.get("eval_count")
    if isinstance(pt, int):
        stats["prompt_tokens"] += pt
        total_prompt_tokens += pt
    if isinstance(ct, int):
        stats["completion_tokens"] += ct
        total_completion_tokens += ct

pass_rate = (total_success / total_end * 100.0) if total_end > 0 else 0.0

if json_mode:
    output = {
        "files": log_files,
        "since": since_str if since_str else None,
        "total_delegations": total_start,
        "completions_logged": total_end,
        "logical_tasks": logical_tasks_count,
        "execution_attempts": execution_attempts_count,
        "legacy_entries": legacy_count,
        "pass_count": total_success,
        "fail_count": total_failed,
        "pass_rate_pct": round(pass_rate, 1),
        "status_breakdown": dict(status_counts),
        "tokens": {
            "total_prompt_tokens": total_prompt_tokens,
            "total_completion_tokens": total_completion_tokens,
            "total_tokens": total_prompt_tokens + total_completion_tokens
        },
        "breakdown": []
    }
    for (agent, mode), s in sorted(agent_mode_stats.items()):
        avg_dur = round(s["total_duration"] / s["count"], 1) if s["count"] > 0 else 0.0
        output["breakdown"].append({
            "agent": agent,
            "mode": mode,
            "count": s["count"],
            "success": s["success"],
            "failed": s["failed"],
            "avg_duration_s": avg_dur,
            "statuses": dict(s["statuses"]),
            "prompt_tokens": s["prompt_tokens"],
            "completion_tokens": s["completion_tokens"]
        })
    print(json.dumps(output, indent=2))
    sys.exit(0)

# Human-readable output
title_suffix = f" [since {since_str}]" if since_str else ""
if len(log_files) == 1:
    print(f"delegate-coder activity log ({log_files[0]}){title_suffix}")
else:
    print(f"delegate-coder fleet activity log ({len(log_files)} files){title_suffix}")
print("=======================================")
print("")
print(f"Total delegations:  {total_start}")
print(f"Completions logged: {total_end}")
if logical_tasks_count > 0:
    print(f"Logical tasks:      {logical_tasks_count} (Attempts: {execution_attempts_count})")
if total_end > 0:
    print(f"Pass rate:          {pass_rate:.1f}% ({total_success} passed, {total_failed} failed)")

if legacy_count > 0:
    print(f"Legacy entries:     {legacy_count} (pre-v2 plaintext format)")
print("")

if total_end > 0:
    print(f"{'Agent':<10} {'Mode':<6} {'Count':>6} {'Success':>8} {'Failed':>8} {'Avg Duration':>14}")
    print(f"{'-----':<10} {'----':<6} {'-----':>6} {'-------':>8} {'------':>8} {'------------':>14}")

    for (agent, mode), s in sorted(agent_mode_stats.items()):
        avg_dur_str = f"{int(round(s['total_duration'] / s['count']))}s" if s["count"] > 0 else "n/a"
        print(f"{agent:<10} {mode:<6} {s['count']:>6} {s['success']:>8} {s['failed']:>8} {avg_dur_str:>14}")

    if status_counts:
        print("")
        print("Status breakdown:")
        for st, c in sorted(status_counts.items(), key=lambda x: -x[1]):
            print(f"  - {st:<22} {c}")

    if total_prompt_tokens > 0 or total_completion_tokens > 0:
        total_tokens = total_prompt_tokens + total_completion_tokens
        print("")
        print("Local token usage:")
        print(f"  - Prompt tokens:     {total_prompt_tokens:,}")
        print(f"  - Completion tokens: {total_completion_tokens:,}")
        print(f"  - Total tokens:      {total_tokens:,}")
elif total_start > 0:
    print("(Only start events found — incomplete runs or legacy logs)")
    print("")
    print(f"{'Agent':<10} {'Mode':<6} {'Count':>6}")
    print(f"{'-----':<10} {'----':<6} {'-----':>6}")
    start_counts = defaultdict(int)
    for r in start_records:
        start_counts[(r.get("agent") or "unknown", r.get("mode") or "unknown")] += 1
    for (agent, mode), count in sorted(start_counts.items(), key=lambda x: -x[1]):
        print(f"{agent:<10} {mode:<6} {count:>6}")

print("")
print("Note: The execution phase logs duration and exit_code for all agents.")
PY
  exit 0
fi

# JQ Fallback if Python 3 is absent
FIRST_LOG="${EXISTING_LOGS[0]}"
total_start=$(jq -r 'select(.event=="start") | .event' "$FIRST_LOG" 2>/dev/null | wc -l | tr -d ' ')
total_end=$(jq -r 'select(.event=="end") | .event' "$FIRST_LOG" 2>/dev/null | wc -l | tr -d ' ')
echo "delegate-coder activity log ($FIRST_LOG)"
echo "======================================="
echo ""
echo "Total delegations:  $total_start"
echo "Completions logged: $total_end"
echo ""
if [[ "$total_end" -gt 0 ]]; then
  printf "%-10s %-6s %6s %8s %8s %14s\n" "Agent" "Mode" "Count" "Success" "Failed" "Avg Duration"
  printf "%-10s %-6s %6s %8s %8s %14s\n" "-----" "----" "-----" "-------" "------" "------------"
  jq -r 'select(.event=="end") | "\(.agent) \(.mode)"' "$FIRST_LOG" 2>/dev/null \
    | sort -u | while read -r agent mode; do
      count=$(jq -r "select(.event==\"end\" and .agent==\"$agent\" and .mode==\"$mode\") | .event" "$FIRST_LOG" | wc -l | tr -d ' ')
      success=$(jq -r "select(.event==\"end\" and .agent==\"$agent\" and .mode==\"$mode\" and .exit_code==0) | .event" "$FIRST_LOG" 2>/dev/null | wc -l | tr -d ' ')
      failed=$((count - success))
      avg_dur=$(jq -r "select(.event==\"end\" and .agent==\"$agent\" and .mode==\"$mode\") | .duration_s" "$FIRST_LOG" 2>/dev/null \
        | awk '{sum+=$1; n++} END {if(n>0) printf "%.0fs", sum/n; else print "n/a"}')
      printf "%-10s %-6s %6s %8s %8s %14s\n" "$agent" "$mode" "$count" "$success" "$failed" "$avg_dur"
    done
fi
echo ""
echo "Note: The execution phase logs duration and exit_code for all agents."
