#!/usr/bin/env bash
# stats.sh — summarize the delegate-coder audit log.
# Usage: stats.sh [path/to/.claude/delegate-coder.log]
set -u

LOGFILE="${1:-.claude/delegate-coder.log}"

if [[ ! -f "$LOGFILE" ]]; then
  echo "No audit log found at: $LOGFILE"
  echo "The log is created automatically when delegate.sh runs."
  exit 0
fi

# Check for jq (required for JSON parsing)
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for stats. Install: brew install jq / apt install jq" >&2
  exit 1
fi

echo "delegate-coder activity log ($LOGFILE)"
echo "======================================="
echo ""

# Count total events
total_start=$(jq -r 'select(.event=="start") | .event' "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
total_end=$(jq -r 'select(.event=="end") | .event' "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
echo "Total delegations:  $total_start"
echo "Completions logged: $total_end"

# Handle legacy plaintext lines (from pre-v2 log format)
legacy=$(grep -cv '^{' "$LOGFILE" 2>/dev/null || echo "0")
legacy=$(echo "$legacy" | tr -d '[:space:]')
if [[ "$legacy" -gt 0 ]]; then
  echo "Legacy entries:     $legacy (pre-v2 plaintext format)"
fi
echo ""

# Per-agent/mode breakdown from end events (which have duration + exit_code)
if [[ "$total_end" -gt 0 ]]; then
  printf "%-10s %-6s %6s %8s %8s %14s\n" "Agent" "Mode" "Count" "Success" "Failed" "Avg Duration"
  printf "%-10s %-6s %6s %8s %8s %14s\n" "-----" "----" "-----" "-------" "------" "------------"

  # Extract unique agent+mode combos
  jq -r 'select(.event=="end") | "\(.agent) \(.mode)"' "$LOGFILE" 2>/dev/null \
    | sort -u | while read -r agent mode; do
      count=$(jq -r "select(.event==\"end\" and .agent==\"$agent\" and .mode==\"$mode\") | .event" "$LOGFILE" | wc -l | tr -d ' ')
      success=$(jq -r "select(.event==\"end\" and .agent==\"$agent\" and .mode==\"$mode\" and .exit_code==0) | .event" "$LOGFILE" 2>/dev/null | wc -l | tr -d ' ')
      failed=$((count - success))
      avg_dur=$(jq -r "select(.event==\"end\" and .agent==\"$agent\" and .mode==\"$mode\") | .duration_s" "$LOGFILE" 2>/dev/null \
        | awk '{sum+=$1; n++} END {if(n>0) printf "%.0fs", sum/n; else print "n/a"}')
      printf "%-10s %-6s %6s %8s %8s %14s\n" "$agent" "$mode" "$count" "$success" "$failed" "$avg_dur"
    done
elif [[ "$total_start" -gt 0 ]]; then
  echo "(Only start events found — incomplete runs or legacy logs)"
  echo ""
  printf "%-10s %-6s %6s\n" "Agent" "Mode" "Count"
  printf "%-10s %-6s %6s\n" "-----" "----" "-----"
  jq -r 'select(.event=="start") | "\(.agent) \(.mode)"' "$LOGFILE" 2>/dev/null \
    | sort | uniq -c | sort -rn | while read -r count agent mode; do
      printf "%-10s %-6s %6s\n" "$agent" "$mode" "$count"
    done
fi

echo ""
echo "Note: The execution phase logs duration and exit_code for all agents."
