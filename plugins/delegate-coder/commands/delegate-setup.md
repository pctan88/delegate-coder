---
name: delegate setup
description: Guided first-time setup for the delegate-coder skill.
---

# Delegate Coder Setup Flow

1. Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/detect.sh` to see installed agents.
2. Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/doctor.sh --all` to check their authentication status.
3. Show the user the available agents and ask which one they want to configure.
4. Ask what command they use to run their test suite (e.g., `npm test`, `pytest`).
5. Write the choices to `.claude/delegate-coder.json`:
```json
{
  "agent": "<chosen_agent>",
  "test_command": "<chosen_test_command>",
  "enabled": true
}
```
6. Inform the user that setup is complete and they can now delegate tasks.
