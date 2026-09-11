---
name: delegate stats
description: Shows activity and usage statistics for the delegate-coder skill.
---

# View Delegate Coder Stats

Run the stats script and display its output to the user:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/stats.sh "$@"
```

Options:
- `--fleet`, `--all`: Discover and aggregate activity across all git worktrees and sibling repositories.
- `--json`: Output full metrics in structured JSON for dashboard or tooling consumption.
