---
name: delegate scope
description: Sets the allowed scope (all, read_only, exec_only) for the delegate-coder skill.
---

# Set Delegate Coder Scope

The user will provide a scope value (all, read_only, exec_only, off).
Set `"scope": "<value>"` in `.claude/delegate-coder.json` using the `jq` command line tool or `python3`. If the file doesn't exist, create it with the value. Inform the user that the scope has been updated.
