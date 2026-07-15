---
name: delegate-coder-codex-onboarding
description: First-use setup for Delegate Coder in Codex. Use when Delegate Coder is installed in Codex and the project has no neutral .delegate-coder/config.json, especially when local Qwen or Ollama is available. Detect the worker and test command, explain the backend choices, ask for confirmation, and create the project config only after the user agrees.
---

# Delegate Coder Codex onboarding

This is the Codex replacement for Claude Code's `/delegate-setup` command. It
is a conversational setup flow: never silently choose a worker, enable
auto-approval, or write a project file.

## 1. Check existing configuration

From the project root, check these paths in order:

1. `.delegate-coder/config.json` — the shared neutral config used by Codex and
   Claude.
2. `.claude/delegate-coder.json` — the legacy Claude config.

If the neutral file exists, validate its JSON and use it. Do not overwrite it.
If only the legacy file exists, explain that it remains supported and use it;
offer migration to the neutral path only as a separate, explicit action.

## 2. Detect available choices

Run the read-only checks below (do not install software or change files):

```bash
command -v qwen || true
command -v ollama || true
ollama list 2>/dev/null || true
bash plugins/delegate-coder/skills/delegate-coder/scripts/detect-test.sh
```

Report exactly what was found. A `qwen` executable means Qwen Code CLI and may
use a hosted provider. An Ollama model means the local contract backend; it is
the local-only choice. Do not claim that `qwen` is local merely because its
name contains Qwen.

## 3. Present the choices and ask before writing

Offer the detected options (and a custom model entry when detection is empty):

- **Qwen Code CLI** — normal `read`/`exec` delegation through the `qwen`
  executable. Code may leave the machine according to that CLI's provider.
- **Local Ollama/Qwen contract** — opt-in single-file JSON Task Contracts sent
  to the selected Ollama model. This stays local only when `OLLAMA_HOST` is the
  default loopback endpoint; it does not replace normal planning, architecture,
  security review, or final acceptance.

Also show the detected test command, if any, and ask the user to confirm the
worker, model, backend, and test command. A refusal or an ambiguous answer must
leave the repository unchanged.

## 4. Write only after explicit confirmation

After confirmation, create `.delegate-coder/` and atomically create (never
silently replace) `.delegate-coder/config.json` with mode `0600`. Preserve
existing files if a concurrent setup created one. Use the following shapes.

For Qwen Code CLI:

```json
{
  "agent": "qwen",
  "model": "<confirmed model, omit when using the CLI default>",
  "test_command": "<confirmed command>",
  "implementation_backend": "agent"
}
```

For local Ollama/Qwen:

```json
{
  "test_command": "<confirmed command>",
  "implementation_backend": "contract",
  "contract": {
    "model": "<confirmed Ollama model>",
    "num_ctx": 32768,
    "keep_alive": "30m",
    "curl_timeout": 600,
    "test_timeout": 300
  }
}
```

Omit unknown optional values rather than writing empty guesses. Tell the user
the exact path and contents written. The runtime prefers this neutral config
and falls back to `.claude/delegate-coder.json` for existing Claude projects.

## 5. Smoke-test safely

For the agent backend, perform a harmless `read` task first. For contract mode,
do not send a write contract until the user supplies a bounded single-file task
with an objective test and the worktree is clean. In both cases, the
orchestrator must inspect the diff and run the project test command before
accepting any worker result.
