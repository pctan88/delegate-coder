#!/usr/bin/env bash
# detect.sh — list worker coding agents installed on this machine.
# When an agent is missing, prints install & auth hints.
set -u
# Enhance PATH with common installation directories for worker agents
EXTRA_PATHS="${DELEGATE_PATH_EXTRA:-}"
COMMON_DIRS="$HOME/.mimocode/bin:$HOME/.local/bin:$HOME/.cargo/bin"
export PATH="$EXTRA_PATHS:$COMMON_DIRS:$PATH"

# Portable timeout: use 'timeout' if available, else use perl one-liner
_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@" 2>/dev/null
  fi
}

# Install + auth hints per agent (printed only when missing)
hint() {
  local agent="$1"
  case "$agent" in
    mimo)
      echo "  Install:  curl -fsSL https://mimo.xiaomi.com/install | bash"
      echo "  Auth:     mimo auth"
      ;;
    aider)
      echo "  Install:  pipx install aider-chat  (or: pip install aider-chat)"
      echo "  Auth:     export OPENAI_API_KEY=sk-...  (or ANTHROPIC_API_KEY)"
      ;;
    codex)
      echo "  Install:  npm install -g @openai/codex"
      echo "  Auth:     export OPENAI_API_KEY=sk-..."
      ;;
    gemini)
      echo "  Install:  npm install -g @google/gemini-cli"
      echo "  Auth:     run 'gemini' — auth is interactive on first launch  (or set GOOGLE_API_KEY)"
      ;;
    qwen)
      echo "  Install:  curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash"
      echo "  Auth:     qwen auth"
      ;;
    opencode)
      echo "  Install:  curl -fsSL https://opencode.ai/install | bash"
      echo "  Auth:     opencode auth login  (or export OPENAI_API_KEY=sk-...)"
      ;;
  esac
}

FOUND=0
for c in mimo aider codex gemini qwen opencode; do
  if command -v "$c" >/dev/null 2>&1; then
    v="$(_timeout 5 "$c" --version 2>/dev/null | head -n1)"
    echo "FOUND: $c ${v:+($v)}"
    FOUND=1
  else
    echo "NOT FOUND: $c"
    hint "$c"
    echo ""
  fi
done
[[ "$FOUND" -eq 0 ]] && echo "No known worker agents found on PATH. See hints above to install one."
exit 0
