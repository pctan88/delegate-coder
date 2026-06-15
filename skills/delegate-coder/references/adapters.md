# Worker Agent Adapters

Per-agent CLI invocations for the two modes. CLI flags change between versions — if a command fails, run `<agent> --help` to verify, then update `.claude/delegate-coder.json` with a `command_override` (see setup.md).

In all examples, `$TASK` is the full task spec as a single quoted string.

---

## MiMo Code (`mimo`)

- **exec:** `mimo run "$TASK" --format default`
- **read (true read-only — write/edit/patch/bash disabled):** `mimo run "$TASK" --agent plan --format default`
- **review (workflow skills incl. compose:review):** `mimo run "$TASK" --agent compose --format default`
- **Sessions:** `--continue`/`-c` resumes last session; `--session <id>` resumes by ID. `--fork` branches a session.
- **Auto-approval:** prefer granular allow/deny rules in `mimocode.json` permissions over `--dangerously-skip-permissions`. See setup.md.
- **JSON output for parsing:** `--format json` (raw event stream — verbose; default format is usually enough).

## Aider (`aider`)

- **exec:** `aider --message "$TASK" --yes`
- **read:** Aider has no read-only agent mode; closest is `aider --message "$TASK" --dry-run --yes` (shows proposed changes without applying). For pure analysis questions, exec mode is acceptable since analysis prompts don't request edits.
- **Notes:** Aider auto-commits by default — convenient with the branch-isolation workflow (each worker step becomes a commit). Add `--no-auto-commits` if the orchestrator wants to control commits.
- **Model selection:** `--model <name>`; requires the user's API key for the chosen provider.

## OpenAI Codex CLI (`codex`)

- **exec:** `codex exec "$TASK" --full-auto`
- **read:** `codex exec "$TASK" --sandbox read-only`
- **Sessions:** `codex exec resume --last "<follow-up>"` continues the previous non-interactive session.
- **Notes:** sandbox modes (`read-only`, `workspace-write`) are a strong safety primitive — prefer `workspace-write` over fully disabling sandboxing.

## Gemini CLI (`gemini`)

- **exec:** `gemini -p "$TASK" --yolo`  (`--yolo` auto-approves all actions; see setup.md before enabling)
- **read:** `gemini -p "$TASK"` without `--yolo` — in non-interactive mode, actions needing approval are not executed, so analysis-only prompts run fine.
- **Notes:** `-p`/`--prompt` is non-interactive mode. Free tier available with a Google account.

## Qwen Code (`qwen`)

Fork of Gemini CLI; same shape:
- **exec:** `qwen -p "$TASK" --yolo`
- **read:** `qwen -p "$TASK"`

## OpenCode (`opencode`)

- **exec:** `opencode run "$TASK"`
- **read:** no dedicated read-only flag; analysis-only prompts are low-risk, or restrict via opencode's permission config.
- **Sessions:** `opencode run --continue` / `--session <id>` (verify with `opencode run --help`).

---

## Adding a different agent

Any CLI agent works if it has a non-interactive/headless mode that accepts a prompt and exits. Find that invocation in the agent's docs, then add a `command_override` in `.claude/delegate-coder.json` (format in setup.md). Requirements:

1. Takes the task as an argument or on stdin
2. Runs without interactive prompts (auto-approve flag or permission config)
3. Prints results to stdout and exits

If the agent only has an interactive TUI, it cannot be orchestrated reliably — pick a different worker.
