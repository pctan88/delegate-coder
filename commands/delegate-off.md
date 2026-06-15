---
name: delegate off
description: Disables the delegate-coder skill for this project.
---

# Disable Delegate Coder

Set `"enabled": false` in `.claude/delegate-coder.json` using the `jq` command line tool or `python3`. If the file doesn't exist, create it with `{"enabled": false}`. Inform the user that the skill is now disabled.
