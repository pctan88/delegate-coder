---
name: delegate model
description: Sets the worker agent and underlying model for the delegate-coder skill.
---

# Set Delegate Coder Model

The user will provide an agent name (e.g. mimo, aider) and optionally a model name (e.g. claude-3-5-sonnet).
Select the active config: prefer `.delegate-coder/config.json`; use an
existing `.claude/delegate-coder.json` only when the user explicitly keeps the
legacy Claude setup. Set `"agent": "<agent>"` and `"model": "<model>"` there
using `jq` or `python3`. If no config exists, create the neutral path. Inform
the user which path was updated.
