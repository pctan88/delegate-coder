#!/usr/bin/env bash
# report.sh — generate fleet observability report across delegate runs.
# Groups by task_id, shows per-worker pass rates, failure breakdown, and flags unmatched events.
# Usage:
#   report.sh [--since <N>h|<N>d] [--json] [log_files...]
set -u

JSON_MODE=false
SINCE_FILTER=""
LOG_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=true
      shift
      ;;
    --since)
      if [[ $# -lt 2 ]]; then
        echo "report.sh: --since requires a duration argument (e.g. 24h, 7d)" >&2
        exit 1
      fi
      SINCE_FILTER="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: report.sh [--since <N>h|<N>d] [--json] [log_files...]"
      echo "  --since <N>h|<N>d       Filter records within the last N hours or days"
      echo "  --json                  Output report in structured JSON format"
      exit 0
      ;;
    *)
      LOG_FILES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
  fleet_log="${DELEGATE_FLEET_LOG:-${HOME:-}/.delegate-coder/fleet.jsonl}"
  if [[ -f "$fleet_log" && -s "$fleet_log" ]]; then
    LOG_FILES+=("$fleet_log")
  else
    # Check local repo log
    if [[ -f ".claude/delegate-coder.log" ]]; then
      LOG_FILES+=(".claude/delegate-coder.log")
    fi
  fi
fi

EXISTING_LOGS=()
for f in "${LOG_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    EXISTING_LOGS+=("$f")
  fi
done

if [[ ${#EXISTING_LOGS[@]} -eq 0 ]]; then
  if [[ "$JSON_MODE" == true ]]; then
    echo '{"total_tasks":0,"total_runs":0,"unmatched_starts":0,"unmatched_ends":0,"workers":{},"tasks":[]}'
  else
    echo "No audit log found. Specify a log file or ensure ~/.delegate-coder/fleet.jsonl exists."
  fi
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "report.sh: python3 is required to generate the delegate report." >&2
  exit 1
fi

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
            sys.stderr.write(f"report.sh: unsupported --since unit in '{since_str}' (use 'h' or 'd')\n")
            sys.exit(1)
    except ValueError:
        sys.stderr.write(f"report.sh: invalid --since duration '{since_str}'\n")
        sys.exit(1)

def parse_iso_ts(ts_str):
    if not ts_str or not isinstance(ts_str, str):
        return None
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except Exception:
        return None

records = []
for file_path in log_files:
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line_str = line.strip()
                if not line_str or not line_str.startswith("{"):
                    continue
                try:
                    record = json.loads(line_str)
                except Exception:
                    continue
                if cutoff_dt is not None:
                    rec_ts = parse_iso_ts(record.get("ts"))
                    if rec_ts is not None and rec_ts < cutoff_dt:
                        continue
                records.append(record)
    except Exception:
        continue

# Correlate starts and ends by run_id
runs = {}
unmatched_starts = []
unmatched_ends = []

for r in records:
    run_id = r.get("run_id")
    event = r.get("event")
    if not run_id:
        run_id = f"anon-{len(runs)}"
        r["run_id"] = run_id

    if run_id not in runs:
        runs[run_id] = {"run_id": run_id, "start": None, "end": None}

    if event == "start":
        if runs[run_id]["start"] is None:
            runs[run_id]["start"] = r
    elif event == "end":
        if runs[run_id]["end"] is None:
            runs[run_id]["end"] = r

for run_id, pair in runs.items():
    if pair["start"] and not pair["end"]:
        unmatched_starts.append(pair["start"])
    elif pair["end"] and not pair["start"]:
        unmatched_ends.append(pair["end"])

# Group by task_id
tasks = defaultdict(list)
for run_id, pair in runs.items():
    rec = pair["end"] or pair["start"]
    tid = rec.get("task_id") if rec else None
    if not tid:
        tid = run_id
    tasks[tid].append(pair)

# Compute per-worker statistics
workers = defaultdict(lambda: {
    "total_attempts": 0,
    "pass_count": 0,
    "fail_count": 0,
    "total_duration_s": 0.0,
    "status_breakdown": defaultdict(int),
    "modes": defaultdict(int)
})

total_completed_runs = 0
total_passed_runs = 0

for run_id, pair in runs.items():
    end_rec = pair["end"]
    if not end_rec:
        continue
    total_completed_runs += 1
    agent = end_rec.get("agent") or "unknown"
    w = workers[agent]
    w["total_attempts"] += 1
    mode = end_rec.get("mode") or "unknown"
    w["modes"][mode] += 1
    status = end_rec.get("status")
    exit_code = end_rec.get("exit_code")
    if not status:
        status = "PASS" if exit_code == 0 else "FAIL"
    w["status_breakdown"][status] += 1

    dur = end_rec.get("duration_s")
    if isinstance(dur, (int, float)):
        w["total_duration_s"] += dur

    is_pass = (status in ("PASS", "NOOP")) or (exit_code == 0 and status not in ("TEST_FAIL", "TIMEOUT", "PREFLIGHT_FAIL", "WORKER_START_FAIL", "DEPENDENCY_GUARD_FAIL", "RESTORE_FAIL", "ERROR"))
    if is_pass:
        w["pass_count"] += 1
        total_passed_runs += 1
    else:
        w["fail_count"] += 1

task_summaries = []
for tid, task_runs in sorted(tasks.items()):
    attempts_count = len(task_runs)
    resolved_pass = False
    task_agent = None
    task_repo = None
    task_branch = None
    task_statuses = []
    for pair in task_runs:
        e = pair["end"] or pair["start"]
        if e:
            if not task_agent: task_agent = e.get("agent")
            if not task_repo: task_repo = e.get("repo")
            if not task_branch: task_branch = e.get("branch")
        if pair["end"]:
            st = pair["end"].get("status") or ("PASS" if pair["end"].get("exit_code") == 0 else "FAIL")
            task_statuses.append(st)
            if st in ("PASS", "NOOP"):
                resolved_pass = True
        elif pair["start"]:
            task_statuses.append("IN_PROGRESS")

    task_summaries.append({
        "task_id": tid,
        "repo": task_repo,
        "branch": task_branch,
        "agent": task_agent,
        "attempts": attempts_count,
        "resolved_pass": resolved_pass,
        "statuses": task_statuses
    })

if json_mode:
    out = {
        "files": log_files,
        "since": since_str if since_str else None,
        "total_tasks": len(tasks),
        "total_runs": len(runs),
        "completed_runs": total_completed_runs,
        "unmatched_starts": len(unmatched_starts),
        "unmatched_ends": len(unmatched_ends),
        "overall_pass_rate_pct": round((total_passed_runs / total_completed_runs * 100.0), 1) if total_completed_runs > 0 else 0.0,
        "workers": {},
        "tasks": task_summaries
    }
    for agent, w in sorted(workers.items()):
        pr = round((w["pass_count"] / w["total_attempts"] * 100.0), 1) if w["total_attempts"] > 0 else 0.0
        avg_dur = round(w["total_duration_s"] / w["total_attempts"], 1) if w["total_attempts"] > 0 else 0.0
        out["workers"][agent] = {
            "total_attempts": w["total_attempts"],
            "pass_count": w["pass_count"],
            "fail_count": w["fail_count"],
            "pass_rate_pct": pr,
            "avg_duration_s": avg_dur,
            "modes": dict(w["modes"]),
            "status_breakdown": dict(w["status_breakdown"])
        }
    print(json.dumps(out, indent=2))
    sys.exit(0)

# Human-Readable Executive Summary
title_suffix = f" [since {since_str}]" if since_str else ""
print(f"delegate-report fleet executive summary{title_suffix}")
print("========================================")
print("")
print(f"Total Logical Tasks:    {len(tasks)}")
print(f"Total Runs (Attempts):  {len(runs)} (Completed: {total_completed_runs})")
if total_completed_runs > 0:
    pass_pct = (total_passed_runs / total_completed_runs) * 100.0
    print(f"Overall Run Pass Rate:  {pass_pct:.1f}% ({total_passed_runs} passed, {total_completed_runs - total_passed_runs} failed)")

if unmatched_starts or unmatched_ends:
    print("")
    print("⚠️  Unmatched Events Detected:")
    if unmatched_starts:
        print(f"  - Unmatched Starts (Incomplete / Crashed / In-Progress): {len(unmatched_starts)}")
    if unmatched_ends:
        print(f"  - Unmatched Ends (Missing Start Record): {len(unmatched_ends)}")

print("")
print("Worker Pass Rates & Performance:")
print(f"{'Worker':<14} {'Attempts':>9} {'Pass':>7} {'Fail':>7} {'Pass Rate':>11} {'Avg Dur':>9}")
print(f"{'------':<14} {'--------':>9} {'----':>7} {'----':>7} {'---------':>11} {'-------':>9}")
for agent, w in sorted(workers.items()):
    pr_str = f"{(w['pass_count'] / w['total_attempts'] * 100.0):.1f}%" if w["total_attempts"] > 0 else "0.0%"
    avg_d = f"{int(round(w['total_duration_s'] / w['total_attempts']))}s" if w["total_attempts"] > 0 else "n/a"
    print(f"{agent:<14} {w['total_attempts']:>9} {w['pass_count']:>7} {w['fail_count']:>7} {pr_str:>11} {avg_d:>9}")

print("")
print("Worker Failure-Phase Breakdown:")
has_failures = False
for agent, w in sorted(workers.items()):
    failures = {st: c for st, c in w["status_breakdown"].items() if st not in ("PASS", "NOOP")}
    if failures:
        has_failures = True
        print(f"  {agent}:")
        for st, c in sorted(failures.items(), key=lambda x: -x[1]):
            print(f"    - {st:<24} {c}")
if not has_failures:
    print("  (No failures recorded)")

if task_summaries:
    print("")
    print("Recent Logical Tasks:")
    for t in task_summaries[-10:]:
        status_seq = " -> ".join(t["statuses"])
        outcome = "✅ PASS" if t["resolved_pass"] else "❌ FAIL"
        agent_info = f"[{t['agent']}]" if t['agent'] else ""
        repo_info = f"({t['repo']})" if t['repo'] else ""
        print(f"  - {t['task_id'][:8]} {agent_info} {repo_info}: {outcome} ({t['attempts']} attempts) [{status_seq}]")

print("")
PY
