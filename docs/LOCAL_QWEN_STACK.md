# Local Qwen stack — structure, usage, and the traps

Reference for humans and agents working on this machine. Written 2026-08-22 after
a full day lost to two of the traps below.

> **Correction to `~/Cowork/AI/SETUP.md`:** that file says to fix env vars by
> editing the Cellar `.plist` template. **That does not work on this Homebrew
> version** — see Trap 2. Prefer this document where the two disagree.

---

## 1. Where things live

| Thing | Path |
|---|---|
| Models (`OLLAMA_MODELS`) | `/Users/pctan/Cowork/AI/models` |
| Fallback if env is lost | `~/.ollama/models` — **empty, and that is the bug signature** |
| API | `http://127.0.0.1:11434` |
| Homebrew binary | `/opt/homebrew/opt/ollama/bin/ollama` |
| Desktop app binary | `/Applications/Ollama.app/Contents/Resources/ollama` |

Required environment (all three are custom; Homebrew supplies neither the first
nor the last two):

```
OLLAMA_MODELS=/Users/pctan/Cowork/AI/models
OLLAMA_CONTEXT_LENGTH=65536
OLLAMA_KEEP_ALIVE=1h
```

## 2. Models — 4 distinct, 6 tags, 55 GB

Manifests declare 82.7 GB; disk is 55 GB because the aliases share blobs.

| Tag | Size | Arch | Capabilities | Role |
|---|---|---|---|---|
| `qwen3-coder:30b` | 18.6 G | `qwen3moe` (sparse MoE, 30.5 B) | completion, tools | **the delegate worker** |
| `qwen3.8:27b` | 17.7 G | `qwen35` (dense, 27.3 B) | completion, tools, **vision**, **thinking** | vision work only |
| `qwen3.6:27b` | 17.4 G | dense | — | previous generation |
| `qwen3:8b` | 5.2 G | — | completion | small/fast |
| `claude-sonnet-4-5:latest` | 18.6 G | — | — | **alias of `qwen3-coder:30b`** |
| `claude-haiku-4-5:latest` | 5.2 G | — | — | **alias of `qwen3:8b`** |

The two `claude-*` tags are **not** Anthropic models. They share identical config
digests with their qwen counterparts (`24a94682582c`, `05a61d37b084`) and exist so
Cowork-on-3P tier mapping resolves. A request for "sonnet" against this endpoint
silently gets local qwen3-coder, with no signal that it is not the real model.

Throughput measured on this machine: **coder30b ~91 tok/s**, **qwen3.8 ~47 tok/s**.
MoE vs dense explains the gap — coder30b activates a fraction of its parameters
per token.

## 3. Which model for which job

| Task | Route to | Why |
|---|---|---|
| Contract-mode implementation & refactor | `qwen3-coder:30b` | Equal correctness to qwen3.8, 2.2–3.5x faster |
| Anything with images or screenshots | `qwen3.8:27b` | Only local option — coder30b has no vision |
| Free-form reasoning, no output schema | `qwen3.8:27b` + `think:true` | Only place thinking does anything (see Trap 3) |
| Final or security-sensitive review | Sonnet subagent (real, via cloud) | Neither local model evaluated for severity judgement |

Benchmark evidence: `benchmark/MODEL_MATRIX.md`. 44/44 runs passed for both models
across three task tiers, so the routing is decided by speed and capability, not
accuracy.

## 4. How to use it

Health check first — it diagnoses every trap below in one shot:

```bash
bash benchmark/check_ollama_env.sh
```

Direct API call:

```bash
curl -s http://127.0.0.1:11434/api/generate \
  -d '{"model":"qwen3-coder:30b","prompt":"hi","stream":false}'
```

Interactive Claude Code fully on local qwen: `claude-local` (defined in
`~/.zprofile`). Avoid one-shot `-p` calls — roughly 60 s cold prefill.

Delegation from Claude Code: the `delegate-coder` skill routes through
`plugins/delegate-coder/skills/delegate-coder/scripts/delegate.sh contract`.

Confirm the context setting actually took effect — this is the fastest tell that
the env survived:

```bash
ollama ps    # CONTEXT column must read 65536 once a model is loaded
```

---

## 5. The traps

### Trap 1 — Two servers race for port 11434

`Ollama.app` and the Homebrew service both bind 11434. **Whichever starts first
wins**, and the desktop app *ignores the Homebrew LaunchAgent entirely*, using the
GUI session environment instead. With no `OLLAMA_MODELS` there it serves from the
empty `~/.ollama`.

Symptom: `ollama list` empty, every request 404 `model not found`, while 55 GB of
models sit on disk. It looks exactly like data loss and is not.

Diagnose:

```bash
lsof -nP -iTCP:11434 -sTCP:LISTEN
```

Fix: pick **one** server and remove the other. If keeping the app, give it the env
via `launchctl setenv OLLAMA_MODELS /Users/pctan/Cowork/AI/models` and restart it.
Two servers coexisting means your models' visibility depends on boot order.

### Trap 2 — `brew services` drops the custom env on every restart

Modern Homebrew generates the LaunchAgent from the **formula's `service do` block**
(`/opt/homebrew/opt/ollama/.brew/ollama.rb`), which hardcodes only
`OLLAMA_FLASH_ATTENTION` and `OLLAMA_KV_CACHE_TYPE`. The Cellar `.plist` template
is **legacy and unused** — editing it changes nothing.

So this is not an after-upgrade problem: **any** `brew services start|restart|stop`
regenerates the plist and silently drops all three custom vars.

Durable fix — edit the LaunchAgent and reload with `launchctl`, then never touch
`brew services` again:

```bash
/usr/libexec/PlistBuddy \
  -c "Add :EnvironmentVariables:OLLAMA_MODELS string /Users/pctan/Cowork/AI/models" \
  -c "Add :EnvironmentVariables:OLLAMA_CONTEXT_LENGTH string 65536" \
  -c "Add :EnvironmentVariables:OLLAMA_KEEP_ALIVE string 1h" \
  -c "Save" ~/Library/LaunchAgents/homebrew.mxcl.ollama.plist
```

```bash
launchctl bootout gui/$(id -u)/homebrew.mxcl.ollama; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/homebrew.mxcl.ollama.plist
```

`launchctl setenv OLLAMA_MODELS …` also works and covers GUI apps, but is lost on
reboot.

### Trap 3 — Thinking is inert under a JSON schema

With Ollama's `format` schema set, `think:true` and `think:false` produce
**byte-identical** output (verified: 570 tokens, 2014 chars). The grammar
constrains the whole generation, so no reasoning happens — thinking only changes
which field the answer lands in.

Worse: with thinking on (qwen3.8's default) the answer goes to `thinking` and
`response` comes back **empty**, so a caller parsing `response` fails with a
confusing JSON error that points nowhere near the cause.

Consequence: **schema-constrained paths cannot benefit from reasoning.** Always
send `"think": false` for them. If you want reasoning, drop `format` entirely.

### Trap 4 — Output budget must assume ~2.58 bytes per token

Whole-file JSON-escaped output measures **~2.58 bytes/token**, consistently across
1.4 KB / 3.9 KB / 10.3 KB / 16.4 KB targets. Estimating at `bytes/3` under-budgets
by ~14% and truncates (`done_reason=length`) on anything above ~11 KB. Both the
router and the harness now use `bytes/2.4`.

Note that raising a `num_predict` cap can never change a run that already fit under
it, so increasing a budget is safe for previously recorded measurements.

### Trap 5 — Bare `python` is a broken pyenv shim

`command -v python` succeeds (it resolves to `~/.pyenv/shims/python`) but running it
**exits 127**, because pyenv global is `system` and system provides only `python3`.

Any script that probes with `command -v python` then executes `python` gets a
silent 127, commonly misreported as whatever the command was meant to check. This
made `contract-router.sh` report `PREFLIGHT_FAIL — syntax check failed` on
*syntactically valid* output for every model. Prefer `python3`, and probe an
interpreter for real usability (`"$c" -c 'pass'`) rather than trusting `command -v`.

---

## 6. Performance: prefer targeted edits over whole-file rewrite

Whole-file mode re-transcribes the entire file for every change — 99.4% of emitted
tokens on a 10 KB target were unchanged code. Fenced SEARCH/REPLACE edits scored
**18/18** where schema-constrained JSON edits scored 13/18 (the anchor has to
survive JSON escaping).

| Source | Whole-file | Patch | Speedup |
|---|---|---|---|
| 3.9 KB | 20.2s / 1528 tok | 2.4s / 124 tok | 8.4x |
| 10.3 KB | 68.0s / 3954 tok | 1.8s / 124 tok | 37.6x |
| 16.4 KB | 111s / 6546 tok | 2.0s / 124 tok | **55x** |

Patch output is **constant** (124 tokens at every size) while whole-file grows
linearly. Crossover is ~2 KB. The exception is a diffuse multi-part refactor, where
the edits approach the size of the file and whole-file wins.

Not yet wired into `contract-router.sh` — `benchmark/patch_probe.py` is a probe.

## 7. Standing constraints

- 36 GB RAM: never pull a model above 24 GB, and **only one 17–18 GB model fits at
  a time** — run benchmarks sequentially or they thrash.
- Keep `num_ctx` at 64 K. 128 K risks OOM.
- Both 27 B/30 B models advertise a 262 K native window; the local ceiling is the
  64 K configured here.
