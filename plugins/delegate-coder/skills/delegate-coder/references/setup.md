# Setup

## Config file

Project-level config preferably lives at `.delegate-coder/config.json` and is
shared by Claude Code and Codex. Existing projects using
`.claude/delegate-coder.json` remain supported as a fallback:

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
- `command_override` — optional. Full shell command per mode; use `{task}` as the placeholder for the task spec. When set, it replaces the built-in adapter (required when `agent` is `custom`). Example: `"exec": "mytool go --prompt {task} --auto"`. Do not wrap `{task}` in quotes (single or double) in your configuration; the placeholder is automatically replaced with `"$DELEGATE_TASK"` (the literal string) and expanded as a safe environment variable at run time to prevent quote corruption and shell injection. Note that the escalation rule (stop after 2 identical failures) is enforced by the orchestrating agent per `SKILL.md` instructions, not by the scripts themselves.
- `test_command` — optional. The project's verification command; the orchestrator runs this after every exec delegation. `/delegate-setup` auto-detects it via `scripts/detect-test.sh` (npm/pytest/go/cargo/make) and asks you to confirm. Omit if the project has no test suite.
- `max_files_before_full_diff_review` — changesets touching more files than this get a full `git diff` review by the orchestrator instead of just `--stat`.
- `implementation_backend` — optional `agent` (default, preserving existing `read`/`exec`) or opt-in `contract` for eligible bounded implementation tasks. Contract mode never silently falls back to a hosted provider.
- `contract` — local Ollama settings. All numeric limits must be strictly positive. The router requires a Git worktree, a clean target/worktree, an isolated feature/delegate branch, and a bounded objective test. Contract setup adds only `/.claude/delegate-coder.log` to `.git/info/exclude` and migrates the exact marked delegate-coder legacy stanza if present. An unmarked/user-owned broad `/.claude/` rule is preserved and causes safe preflight failure, so the audit log remains available to `/delegate stats` without hiding tracked or other `.claude/*` changes.

The `DELEGATE_AGENT` environment variable overrides the `agent` field when set.
Codex's `$delegate-coder-codex-onboarding` skill detects workers and writes the
neutral path only after confirmation. Claude's `/delegate-setup` command may
continue to write the legacy path for compatibility.

## Contract mode

Contract mode is an opt-in local Ollama backend for Claude/Codex-style heavy orchestrators. Invoke it explicitly with `bash plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh contract` or select `"implementation_backend": "contract"` for JSON `exec` contracts. It requires a local Ollama server with `qwen3-coder:30b` available, unless `DELEGATE_MODEL` selects another local model. Pass one object or a JSON array for sequential contracts. The router creates or uses an isolated feature/delegate branch before the first write, rejects a dirty worktree or target, validates strict structured output, writes transactionally, and restores failed candidates. It returns a pre-contract target-only diff, metrics, and final test log, makes at most one self-correction attempt after a failed test, reports unchanged output as `NOOP` (saving the candidate output to `${TMPDIR:-/tmp}/delegate-coder-candidate.XXXXXX` for operator inspection), and rejects context-truncated responses. `DELEGATE_NUM_CTX`, `DELEGATE_KEEP_ALIVE`, `DELEGATE_CURL_TIMEOUT`, and `DELEGATE_TEST_TIMEOUT` override the configured local limits.

Every contract must include external interfaces, signatures, invariants, dependency ordering, forbidden changes, and the exact objective test command. The orchestrator must review the cumulative diff and run the full repository verification after all sequential contracts pass; the worker's self-reported "I ran the tests" is never trusted; orchestrator/independent verification is mandatory. A failed child restores its target, Git-visible tracked/nonignored outside-target mutations, and index entries made during that child; a successful changed child also restores its pre-child index and leaves the accepted target unstaged; ignored dependency/cache/build trees are not snapshotted. Earlier accepted children remain on the isolated branch. `test_command` is trusted and must not mutate Git references or make commits. Exploration, architecture, authentication/security, malformed-input boundaries, ambiguous edits, and repository-wide reasoning stay on the normal agent/native path.

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
3. Ask whether implementation should use the default `agent` backend or opt in to local `contract`; auto-detect the test command (`bash scripts/detect-test.sh`), confirm with the user, and write `.delegate-coder/config.json` with `agent`, `model`, `test_command`, `implementation_backend`, and (when selected) the `contract` settings. Existing Claude setups may retain `.claude/delegate-coder.json`.
4. Configure the worker's permission rules per the section above
5. Run a small smoke test: delegate a trivial read task ("summarize the structure of this repo") and confirm output comes back
