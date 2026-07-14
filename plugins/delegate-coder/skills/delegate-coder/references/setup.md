# Setup

## Config file

Project-level config lives at `.claude/delegate-coder.json`:

```json
{
  "agent": "mimo",
  "model": "",
  "command_override": {
    "exec": "",
    "read": ""
  },
  "test_command": "npm test",
  "max_files_before_full_diff_review": 5
}
```

- `agent` — which worker to use: `mimo`, `aider`, `codex`, `gemini`, `qwen`, `opencode`, or `custom`.
- `model` — optional. The worker model to use; `delegate.sh` passes it per-agent (`--model`, or `-m` for gemini/qwen). Omit (or leave empty) to use the agent's own default. Common per-agent options and their cost/speed trade-offs are in [models.md](models.md) — that list drifts, so any model string the provider accepts is valid here.
- `command_override` — optional. Full shell command per mode; use `{task}` as the placeholder for the task spec. When set, it replaces the built-in adapter (required when `agent` is `custom`). Example: `"exec": "mytool go --prompt '{task}' --auto"`.
- `test_command` — optional. The project's verification command; the orchestrator runs this after every exec delegation. `/delegate-setup` auto-detects it via `scripts/detect-test.sh` (npm/pytest/go/cargo/make) and asks you to confirm. Omit if the project has no test suite.
- `max_files_before_full_diff_review` — changesets touching more files than this get a full `git diff` review by the orchestrator instead of just `--stat`.

The `DELEGATE_AGENT` environment variable overrides the `agent` field when set.

## Contract mode

Contract mode does not use `agent` or `model` from this configuration. It is invoked explicitly with `bash scripts/delegate.sh contract` and requires a local Ollama server with `qwen3-coder:30b` available, unless `DELEGATE_MODEL` selects another local model. Pass a JSON object containing `target_file`, `instructions`, and `test_command`, pipe it on stdin, or pass an array for sequential contracts. The target must be an in-repository non-symlink regular file or a new file in an existing directory. The router returns a target-only diff and final test log, makes at most one self-correction attempt after a failed test, reports unchanged output as `NOOP`, and rejects context-truncated responses. `DELEGATE_NUM_CTX`, `DELEGATE_KEEP_ALIVE`, `DELEGATE_CURL_TIMEOUT`, and `DELEGATE_TEST_TIMEOUT` tune the local limits.

## Safe permissions (important)

Worker agents in headless mode need auto-approval to run unattended, but blanket auto-approval (`--dangerously-skip-permissions`, `--yolo`, disabled sandboxing) lets a confused worker run anything. Prefer, in order:

1. **The agent's own permission config.** MiMo: allow/deny rules in `mimocode.json`. Codex: `--sandbox workspace-write`. OpenCode: permission config. Deny at minimum: `rm -rf`, `git push`, `sudo`, package publishing, network calls to unknown hosts.
2. **Git branch isolation** (the skill workflow already does this) — every change is reviewable and revertible.
3. **Blanket auto-approve flags only as a last resort**, and only in repos where the branch + diff-review workflow is being followed.

Never combine blanket auto-approval with skipping the verification step.

## Codebase privacy note

Worker agents that run against a **hosted provider** send your code to that provider's servers — MiMo (Xiaomi), Gemini (Google), Codex (OpenAI), Qwen (Alibaba), and Aider or OpenCode when pointed at a hosted model. `/delegate-setup` prints a one-time warning for these. Fine for personal/open-source projects; for employer code, confirm the policy allows it, or configure the worker with an approved API provider instead.

This does **not** apply to a purely local / self-hosted worker (e.g. OpenCode or Aider against a model running on your machine) — no code leaves the device, so no warning is shown.

## First-time project setup checklist

1. Detect installed agents: `bash scripts/detect.sh`
2. Ask the user which to use; show the privacy warning if it sends code off-machine; pick a `model` from [models.md](models.md) (or default/custom)
3. Auto-detect the test command (`bash scripts/detect-test.sh`), confirm with the user, and write `.claude/delegate-coder.json` with `agent`, `model`, and `test_command`
4. Configure the worker's permission rules per the section above
5. Run a small smoke test: delegate a trivial read task ("summarize the structure of this repo") and confirm output comes back
