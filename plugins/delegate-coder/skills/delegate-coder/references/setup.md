# Setup

## Config file

Project-level config lives at `.claude/delegate-coder.json`:

```json
{
  "agent": "mimo",
  "command_override": {
    "exec": "",
    "read": ""
  },
  "test_command": "npm test",
  "max_files_before_full_diff_review": 5
}
```

- `agent` — which worker to use: `mimo`, `aider`, `codex`, `gemini`, `qwen`, `opencode`, or `custom`.
- `command_override` — optional. Full shell command per mode; use `{task}` as the placeholder for the task spec. When set, it replaces the built-in adapter (required when `agent` is `custom`). Example: `"exec": "mytool go --prompt '{task}' --auto"`.
- `test_command` — the project's verification command; the orchestrator runs this after every exec delegation.
- `max_files_before_full_diff_review` — changesets touching more files than this get a full `git diff` review by the orchestrator instead of just `--stat`.

The `DELEGATE_AGENT` environment variable overrides the `agent` field when set.

## Safe permissions (important)

Worker agents in headless mode need auto-approval to run unattended, but blanket auto-approval (`--dangerously-skip-permissions`, `--yolo`, disabled sandboxing) lets a confused worker run anything. Prefer, in order:

1. **The agent's own permission config.** MiMo: allow/deny rules in `mimocode.json`. Codex: `--sandbox workspace-write`. OpenCode: permission config. Deny at minimum: `rm -rf`, `git push`, `sudo`, package publishing, network calls to unknown hosts.
2. **Git branch isolation** (the skill workflow already does this) — every change is reviewable and revertible.
3. **Blanket auto-approve flags only as a last resort**, and only in repos where the branch + diff-review workflow is being followed.

Never combine blanket auto-approval with skipping the verification step.

## Codebase privacy note

Free-tier worker agents (MiMo's bundled model, Gemini free tier) send code to their provider's servers. Fine for personal/open-source projects; for employer code, confirm the policy allows it, or configure the worker with an approved API provider instead.

## First-time project setup checklist

1. Detect installed agents: `bash scripts/detect.sh`
2. Ask the user which to use (and which model/provider, if the agent supports several)
3. Write `.claude/delegate-coder.json` with `agent` and `test_command`
4. Configure the worker's permission rules per the section above
5. Run a small smoke test: delegate a trivial read task ("summarize the structure of this repo") and confirm output comes back
