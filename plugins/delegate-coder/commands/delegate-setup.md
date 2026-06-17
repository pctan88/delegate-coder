---
name: delegate setup
description: Guided first-time setup for the delegate-coder skill.
---

# Delegate Coder Setup Flow

1. Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/detect.sh` to see installed agents.
2. Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/doctor.sh --all` to check their authentication status.
3. Show the user the available agents and ask which one they want to configure. Call this `<agent>`.

4. **Privacy notice (only when the worker sends code off-machine).** If `<agent>`
   transmits code to an external provider, print this once:

   > ⚠️ This worker sends your code to **<provider>**'s servers. For employer or
   > confidential code, confirm your organization's policy allows this before delegating.

   Provider per agent: `mimo`→Xiaomi, `gemini`→Google, `codex`→OpenAI, `qwen`→Alibaba,
   `aider`→whichever model provider it's pointed at.
   **Skip the notice entirely** for a purely local / self-hosted worker — e.g.
   `opencode` (or `aider`) configured against a model running on this machine, where
   no code leaves the device. Don't cry wolf; only warn when code actually leaves.

5. **Pick the model.** Read `${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/references/models.md`
   and show the user the row for `<agent>`: the named cheap-vs-capable options with
   their cost/speed hints, **plus** always:
   - **use the agent's default** — omit the `model` key (the agent picks), and
   - **enter a custom model string** — for anything newer or not listed.

   (The model list drifts; the default and custom options are the safety net.)

6. **Detect the test command.** Run
   `bash ${CLAUDE_PLUGIN_ROOT}/skills/delegate-coder/scripts/detect-test.sh` in the project root.
   - If it prints a command, propose it: "Detected `<cmd>` — use this, or enter another?" Let the user confirm or override.
   - If it prints nothing (unrecognized or ambiguous), ask the user for their test command.
   - It's fine to finish with **no** test command if the project has none — just omit the key.

7. Write the choices to `.claude/delegate-coder.json` (include `model` only if one was chosen; include `test_command` only if known):
```json
{
  "agent": "<chosen_agent>",
  "model": "<chosen_model_or_omit>",
  "test_command": "<detected_or_chosen_or_omit>",
  "enabled": true
}
```
8. Inform the user that setup is complete and they can now delegate tasks.
