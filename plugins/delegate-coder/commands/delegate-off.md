---
name: delegate off
description: Disables the delegate-coder skill for this project.
---

# Disable Delegate Coder

Select the active config: prefer `.delegate-coder/config.json`; use an
existing `.claude/delegate-coder.json` only when the user explicitly keeps the
legacy Claude setup. Set `"enabled": false` there using `jq` or `python3`. If
no config exists, create the neutral path with `{"enabled": false}`. Inform
the user which path was updated.
