---
name: delegate on
description: Enables the delegate-coder skill for this project.
---

# Enable Delegate Coder

Select the active config: prefer `.delegate-coder/config.json`; use an
existing `.claude/delegate-coder.json` only when the user explicitly keeps the
legacy Claude setup. Set `"enabled": true` there using `jq` or `python3`. If
no config exists, create the neutral path with `{"enabled": true}`. Inform the
user which path was updated.
