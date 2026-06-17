<!--
  ⚠️ MAINTENANCE NOTE — THIS LIST DRIFTS.
  Providers rename, retire, and re-price models frequently. The names below are
  examples that were current at authoring time, NOT a guaranteed-valid menu.
  When updating setup, treat these as suggestions and ALWAYS keep the two escape
  hatches in the setup flow:
    - "use the agent's default" (writes no `model` key — agent picks)
    - "enter a custom model string" (user types whatever the provider supports)
  Verify exact IDs with `<agent> --help` or the provider's model docs before relying on one.
-->

# Worker model options (per agent)

Cost varies a lot by model, so let the user choose at setup time. For each agent,
offer the short list below (each with its cost/speed hint), **plus** these two
options every time:

- **Use the agent's default** — omit the `model` key in `.claude/delegate-coder.json`; the agent picks.
- **Enter a custom model string** — for anything not listed, or newer than this file.

The chosen value is written to the `model` key and passed by `delegate.sh`
per-agent (`--model` for mimo/aider/codex/opencode, `-m` for gemini/qwen).

| Agent | Cheap + fast | Capable + pricier | Notes |
|---|---|---|---|
| **gemini** | `gemini-2.5-flash` | `gemini-2.5-pro` | Free tier available with a Google account; flash is plenty for most delegation. |
| **qwen** | `qwen-coder-turbo` | `qwen-coder-plus` | Coder-tuned variants; turbo is the budget pick. |
| **codex** | `o4-mini` | `gpt-5-codex` | OpenAI; mini-class models are far cheaper per token. Verify IDs with `codex --help`. |
| **aider** | `o4-mini` / `deepseek` | `claude-sonnet-4-5` / `gpt-5` | Any provider via `--model`; needs that provider's API key. Pick a cheap reasoning model for routine work. |
| **opencode** | provider's small model (e.g. `openai/o4-mini`) | provider's large model (e.g. `anthropic/claude-sonnet-4-5`) | Format is `provider/model`; can also point at a **local/self-hosted** model — then there is no per-token cost and no code leaves the machine. |
| **mimo** | (bundled default) | — | MiMo ships a bundled model; usually leave as default. |

## How to present this at setup

After the agent is chosen, show only the row for that agent: the two named
options with their hints, then "use the agent's default" and "enter a custom
model string." Write the result to `model` (or omit it for default).
