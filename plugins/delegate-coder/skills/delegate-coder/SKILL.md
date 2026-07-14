---
name: delegate-coder
description: Use for ANY implementation, refactoring, bulk codebase reading/analysis, or code review task. If this skill is installed in a project, the user has chosen to delegate execution-heavy work by default — do not do bulk reading or routine implementation yourself. Orchestrate a second CLI coding agent (MiMo, Aider, Codex, Gemini, etc.) as a worker to save usage. Also trigger if the user asks to delegate coding work, mentions saving tokens/usage, or references "mimo", "aider", "codex", "gemini cli", "worker agent", or "sub-agent model".
---

# Delegate Coder

You are the **orchestrator**. A second CLI coding agent installed on this machine is your **worker**. Your job is to spend your own tokens on decisions — architecture, specs, judging diffs — and spend the worker's (cheaper/free) tokens on execution and bulk reading. Don't read whole codebases or write routine code yourself when a worker is configured.

## Step 1: Identify the worker agent

Check, in order:
1. `DELEGATE_AGENT` environment variable (e.g. `mimo`, `aider`, `codex`, `gemini`, `opencode`, `qwen`)
2. `.claude/delegate-coder.json` in the project root (`{"agent": "mimo"}`)
3. Auto-detect: `bash scripts/detect.sh` lists installed worker agents

If none is configured and one is detected, confirm with the user before first use. If several are detected, ask which to use, then offer to save the choice to `.claude/delegate-coder.json`.

### Scope guard

Before delegating, check `.claude/delegate-coder.json` for `enabled` and `scope`:
- If `enabled` is `false`: do NOT delegate. Do the work yourself.
- If `scope` is `"read_only"`: only delegate `read` mode tasks. Do `exec` yourself.
- If `scope` is `"exec_only"`: only delegate `exec` mode tasks. Do `read` yourself.
- If `scope` is `"off"`: same as `enabled: false`.
- If `enabled` is absent or `true`, and `scope` is absent or `"all"`: delegate as normal (current behavior).

## Step 2: Choose the task mode

| Task type | Mode | Trust level |
|---|---|---|
| Read / understand / summarize codebase | `read` | Full trust only when its adapter enforces read-only or dry-run behavior. Gemini, Qwen, and OpenCode do not enforce a zero-write guarantee, so use orchestration review and isolation. |
| Code review of a diff or module | `read` | Trusted only with an enforcing read-only or dry-run adapter; Gemini, Qwen, and OpenCode require orchestration review and isolation. |
| Implement / refactor / fix | `exec` | Verify with git + tests (Step 4) |

Anything ambiguous, architecture-defining, or security-sensitive: do it yourself instead of delegating.

## Step 3: Write the spec and delegate

Worker agents execute well but interpret poorly. Your spec must include: exact scope (file paths), expected behavior, constraints (style, libraries, what NOT to touch), and how to verify (test command). Vague handoffs waste both your tokens and the worker's cycles.

For `exec` tasks, first isolate the work:

```bash
git checkout -b delegate/<short-task-name>
```

Then delegate:

```bash
bash scripts/delegate.sh <read|exec> "<full task spec>"
```

The script maps the mode to the right CLI invocation for the configured agent. If it fails for your agent (flags change between versions), read `references/adapters.md`, verify with `<agent> --help`, and run the command directly.

**Context discipline:** if the worker's output is long, condense it to the decisions-relevant facts before continuing. Never paste raw multi-hundred-line worker output into your reasoning more than once.

## Step 4: Verify exec results cheaply

Verify with deterministic checks, not by re-reading code:

```bash
git diff --stat            # scope sanity: did it touch only what the spec allowed?
<project test command>     # tests/lint/typecheck — zero orchestrator tokens
```

Read the full `git diff` only when: the changeset is large (>5 files), it touches core/shared modules, tests fail, or the worker's own summary expresses uncertainty. Diffs can't lie; summaries can.

## Step 5: Escalation rule

If the worker fails the same task **twice**, stop delegating it. Either rewrite the spec to be more explicit (a spec problem) or implement it yourself (a capability problem). Never enter a third retry — retry loops silently destroy the token savings this skill exists for.

### Contract mode

For a bounded local single-file edit, use the contract router instead of a chat-agent mode. Decompose multi-file work into one contract per file and run those contracts sequentially; do not send an exploratory multi-file task to the full-file worker.

```bash
bash scripts/delegate.sh contract '<json contract>'
# or: printf '%s' '<json contract>' | bash scripts/delegate.sh contract
```

The contract must contain string fields named `target_file`, `instructions`, and `test_command`. A top-level array of these objects is also accepted for sequential batches. The router validates that the target is an in-repository regular file or a new file whose parent already exists, prepares the local Ollama process environment, asks `qwen3-coder:30b` (or `DELEGATE_MODEL`) for a complete replacement through `/api/generate`, and runs the supplied test command with bounded timeouts. It makes one correction generation after a failed test, never more than one. Context truncation is rejected, unchanged output is reported as `NOOP`, and the report includes retries, target-only diff(s), and final test log(s) on stdout; operational progress is sent to stderr. This mode requires a local Ollama server. The existing `read` and `exec` adapters are unchanged.

## Session continuity

For multi-step tasks, reuse the worker's session instead of re-feeding context. Agents that support it (see `references/adapters.md`): MiMo (`--session <id>` / `-c`), Codex (`resume`), others vary. Capture the session ID from the first run's output when available.

## Reference files

- `references/adapters.md` — per-agent commands, read-only modes, session flags, permission settings. Read it when the delegate script fails, when setting up a new agent, or when you need agent-specific features.
- `references/setup.md` — first-time setup: config file format, safe permission configuration (avoid blanket auto-approve), and how the user can add a custom agent. Read when configuring a project for the first time.
- `references/models.md` — per-agent model options with cost/speed hints, used by `/delegate-setup` to let the user pick a `model`. The list drifts, so it always offers a custom-entry fallback.
