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
  "max_files_before_full_diff_review": 5,
  "implementation_backend": "agent",
  "contract": {
    "model": "qwen3-coder:30b",
    "num_ctx": 32768,
    "keep_alive": "30m",
    "curl_timeout": 600,
    "test_timeout": 300
  }
}
```

- `agent` — which worker to use: `mimo`, `aider`, `codex`, `gemini`, `qwen`, `opencode`, or `custom`.
- `model` — optional. The worker model to use; `delegate.sh` passes it per-agent (`--model`, or `-m` for gemini/qwen). Omit (or leave empty) to use the agent's own default. Common per-agent options and their cost/speed trade-offs are in [models.md](models.md) — that list drifts, so any model string the provider accepts is valid here.
- `command_override` — optional. Full shell command per mode; use `{task}` as the placeholder for the task spec. When set, it replaces the built-in adapter (required when `agent` is `custom`). Example: `"exec": "mytool go --prompt '{task}' --auto"`.
- `test_command` — optional. The project's verification command; the orchestrator runs this after every exec delegation. `/delegate-setup` auto-detects it via `scripts/detect-test.sh` (npm/pytest/go/cargo/make) and asks you to confirm. Omit if the project has no test suite.
- `max_files_before_full_diff_review` — changesets touching more files than this get a full `git diff` review by the orchestrator instead of just `--stat`.
- `implementation_backend` — optional `agent` (default, preserving existing `read`/`exec`) or opt-in `contract` for eligible bounded implementation tasks. Contract mode never silently falls back to a hosted provider.
- `contract` — local Ollama settings. All numeric limits must be strictly positive. The router requires a Git worktree, a clean target/worktree, an isolated feature/delegate branch, and a bounded objective test. Contract setup adds an idempotent `/.claude/` rule to `.git/info/exclude`, so `.claude/delegate-coder.log` remains available to `/delegate stats` without appearing as a consumer worktree change.

The `DELEGATE_AGENT` environment variable overrides the `agent` field when set.

## Contract mode

Contract mode is an opt-in local Ollama backend for Claude/Codex-style heavy orchestrators. Invoke it explicitly with `bash plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh contract` or select `"implementation_backend": "contract"` for JSON `exec` contracts. It requires a local Ollama server with `qwen3-coder:30b` available, unless `DELEGATE_MODEL` selects another local model. Pass one object or a JSON array for sequential contracts. The router creates or uses an isolated feature/delegate branch before the first write, rejects a dirty worktree or target, validates strict structured output, writes transactionally, and restores failed candidates. It returns a pre-contract target-only diff, metrics, and final test log, makes at most one self-correction attempt after a failed test, reports unchanged output as `NOOP`, and rejects context-truncated responses. `DELEGATE_NUM_CTX`, `DELEGATE_KEEP_ALIVE`, `DELEGATE_CURL_TIMEOUT`, and `DELEGATE_TEST_TIMEOUT` override the configured local limits.

Every contract must include external interfaces, signatures, invariants, dependency ordering, forbidden changes, and the exact objective test command. The orchestrator must review the cumulative diff and run the full repository verification after all sequential contracts pass. A failed child restores its target and any tracked or untracked outside-target mutations made during that child; earlier accepted children remain on the isolated branch. Exploration, architecture, authentication/security, malformed-input boundaries, ambiguous edits, and repository-wide reasoning stay on the normal agent/native path.

## Safe permissions (important)

Worker agents in headless mode need auto-approval to run unattended, but blanket auto-approval (`--dangerously-skip-permissions`, `--yolo`, disabled sandboxing) lets a confused worker run anything. Prefer, in order:

1. **The agent's own permission config.** MiMo: allow/deny rules in `mimocode.json`. Codex: `--sandbox workspace-write`. OpenCode: permission config. Deny at minimum: `rm -rf`, `git push`, `sudo`, package publishing, network calls to unknown hosts.
2. **Git branch isolation** (the skill workflow already does this) — every change is reviewable and revertible.
3. **Blanket auto-approve flags only as a last resort**, and only in repos where the branch + diff-review workflow is being followed.

Never combine blanket auto-approval with skipping the verification step.

## Codebase privacy note

Worker agents that run against a **hosted provider** send your code to that provider's servers — MiMo (Xiaomi), Gemini (Google), Codex (OpenAI), Qwen (Alibaba), and Aider or OpenCode when pointed at a hosted model. `/delegate-setup` prints a one-time warning for these. Fine for personal/open-source projects; for employer code, confirm the policy allows it, or configure the worker with an approved API provider instead.

This does **not** apply to a purely local / self-hosted worker (e.g. Ollama contract mode, OpenCode, or Aider against a model running on your machine) — no code leaves the device, so no warning is shown. For an explicitly remote `OLLAMA_HOST`, normal proxy behavior is retained and the user should treat the endpoint as a code-sharing boundary.

## First-time project setup checklist

1. Detect installed agents: `bash scripts/detect.sh`
2. Ask the user which to use; show the privacy warning if it sends code off-machine; pick a `model` from [models.md](models.md) (or default/custom)
3. Ask whether implementation should use the default `agent` backend or opt in to local `contract`; auto-detect the test command (`bash scripts/detect-test.sh`), confirm with the user, and write `.claude/delegate-coder.json` with `agent`, `model`, `test_command`, `implementation_backend`, and (when selected) the `contract` settings.
4. Configure the worker's permission rules per the section above
5. Run a small smoke test: delegate a trivial read task ("summarize the structure of this repo") and confirm output comes back
