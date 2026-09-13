---
name: delegate report
description: Generates an executive fleet summary and worker health report across delegate runs.
---

# View Delegate Coder Fleet Report

Run the report script to display an executive summary grouped by logical task, with per-worker pass rates, failure breakdown, and unmatched event detection:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/report.sh "$@"
```

Options:
- `--since <N>h|<N>d`: Filter records within the last N hours or days (e.g. `--since 48h`, `--since 7d`).
- `--json`: Output aggregate task and worker health metrics in structured JSON.
- `[log_files...]`: Optionally specify explicit audit log files (defaults to `${DELEGATE_FLEET_LOG:-$HOME/.delegate-coder/fleet.jsonl}` or local repository log).
