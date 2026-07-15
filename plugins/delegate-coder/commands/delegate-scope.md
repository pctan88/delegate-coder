---
name: delegate scope
description: Sets the allowed scope (all, read_only, exec_only) for the delegate-coder skill.
---

# Set Delegate Coder Scope

The user will provide a scope value (all, read_only, exec_only, off).
Select the active config: prefer `.delegate-coder/config.json`; use an
existing `.claude/delegate-coder.json` only when the user explicitly keeps the
legacy Claude setup. Set `"scope": "<value>"` there using `jq` or `python3`.
If no config exists, create the neutral path with the value. Inform the user
which path was updated.
