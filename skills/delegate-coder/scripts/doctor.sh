#!/usr/bin/env bash
# doctor.sh — health-check for the delegate-coder skill.
# Usage: doctor.sh [--all]
#   Default: check the configured agent only.
#   --all:   check every known agent.
set -u

# ── PATH setup (same as delegate.sh) ──
EXTRA_PATHS="${DELEGATE_PATH_EXTRA:-}"
COMMON_DIRS="$HOME/.mimocode/bin:$HOME/.local/bin:$HOME/.cargo/bin"
export PATH="$EXTRA_PATHS:$COMMON_DIRS:$PATH"

CONFIG=".claude/delegate-coder.json"
KNOWN_AGENTS=(mimo aider codex gemini qwen opencode)
CHECK_ALL=false
[[ "${1:-}" == "--all" ]] && CHECK_ALL=true

# ── portable timeout ──
_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@" 2>/dev/null
  fi
}

# ── helpers ──
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf "${GREEN}✓ %s${NC}" "$1"; }
fail() { printf "${RED}✗ %s${NC}" "$1"; }
warn() { printf "${YELLOW}⚠ %s${NC}" "$1"; }

json_get() { # json_get <key> <file> — crude extractor, avoids jq dependency
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null \
    | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# ── config checks ──
config_valid=false
config_agent=""
config_test_cmd=""

check_config() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "Config: $CONFIG not found (will use env/auto-detect)"
    return
  fi
  # validate JSON
  if command -v jq >/dev/null 2>&1; then
    if jq . "$CONFIG" >/dev/null 2>&1; then
      config_valid=true
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 -c "import json; json.load(open('$CONFIG'))" 2>/dev/null; then
      config_valid=true
    fi
  else
    # no validator available, assume valid if file exists
    config_valid=true
  fi

  if $config_valid; then
    ok "config valid JSON"; echo ""
  else
    fail "config is NOT valid JSON"; echo ""
  fi

  config_agent="$(json_get agent "$CONFIG")"
  config_test_cmd="$(json_get test_command "$CONFIG")"

  if [[ -n "$config_test_cmd" ]]; then
    ok "test_command: $config_test_cmd"; echo ""
  else
    warn "no test_command configured"; echo ""
  fi
}

# ── per-agent checks ──
check_agent() {
  local agent="$1"

  printf "%-12s" "$agent:"

  # 1. Installed?
  if ! command -v "$agent" >/dev/null 2>&1; then
    fail "not installed"
    echo ""
    return 1
  fi

  local version
  version="$(_timeout 5 "$agent" --version 2>/dev/null | head -n1)"
  [[ -z "$version" ]] && version="installed"
  ok "$version"
  printf "  "

  # 2. Authenticated? — probe credentials per agent
  local auth_ok=false
  case "$agent" in
    mimo)
      # mimo stores auth in its local data; if DB exists, it's been set up
      if [[ -f "$HOME/.local/share/mimocode/mimocode.db" ]] || \
         [[ -d "$HOME/.mimocode" ]]; then
        auth_ok=true
      fi
      ;;
    aider)
      if [[ -n "${OPENAI_API_KEY:-}" ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]] || \
         [[ -f "$HOME/.aider.conf.yml" ]]; then
        auth_ok=true
      fi
      ;;
    codex)
      if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        auth_ok=true
      fi
      ;;
    gemini)
      if [[ -n "${GOOGLE_API_KEY:-}" ]] || \
         [[ -d "$HOME/.config/gemini" ]] || \
         [[ -f "$HOME/.gemini/settings.json" ]]; then
        auth_ok=true
      fi
      ;;
    qwen)
      if [[ -n "${DASHSCOPE_API_KEY:-}" ]] || \
         [[ -d "$HOME/.config/qwen" ]]; then
        auth_ok=true
      fi
      ;;
    opencode)
      if [[ -n "${OPENAI_API_KEY:-}" ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]] || \
         [[ -f "$HOME/.local/share/opencode/auth.json" ]] || \
         [[ -f "$HOME/.config/opencode/config.json" ]]; then
        auth_ok=true
      fi
      ;;
  esac

  if $auth_ok; then
    ok "authenticated"
  else
    warn "needs auth"
  fi

  echo ""
  return 0
}

# ── main ──
echo "delegate-coder doctor"
echo "====================="
echo ""

check_config

echo ""

# Determine which agents to check
if $CHECK_ALL; then
  agents_to_check=("${KNOWN_AGENTS[@]}")
else
  # configured agent only
  target="${DELEGATE_AGENT:-$config_agent}"
  if [[ -z "$target" ]]; then
    echo "No agent configured. Use --all to check all known agents,"
    echo "or set DELEGATE_AGENT / agent in $CONFIG."
    exit 1
  fi
  agents_to_check=("$target")
fi

configured_ready=false
for agent in "${agents_to_check[@]}"; do
  if check_agent "$agent"; then
    target="${DELEGATE_AGENT:-$config_agent}"
    [[ "$agent" == "$target" ]] && configured_ready=true
  fi
done

echo ""
if $configured_ready; then
  ok "configured agent '${DELEGATE_AGENT:-$config_agent}' is ready"
  echo ""
  exit 0
else
  target="${DELEGATE_AGENT:-$config_agent}"
  if [[ -n "$target" ]]; then
    fail "configured agent '$target' is NOT ready"
    echo ""
  fi
  exit 1
fi
