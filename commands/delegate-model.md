---
name: delegate model
description: Sets the worker agent and underlying model for the delegate-coder skill.
---

# Set Delegate Coder Model

The user will provide an agent name (e.g. mimo, aider) and optionally a model name (e.g. claude-3-5-sonnet).
Set `"agent": "<agent>"` and `"model": "<model>"` in `.claude/delegate-coder.json` using the `jq` command line tool or `python3`. If the file doesn't exist, create it. Inform the user that the agent and model have been updated.
