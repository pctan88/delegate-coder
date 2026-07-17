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

CONFIG=".delegate-coder/config.json"
LEGACY_CONFIG=".claude/delegate-coder.json"
if [[ ! -f "$CONFIG" && -f "$LEGACY_CONFIG" ]]; then
  CONFIG="$LEGACY_CONFIG"
fi
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
override_read=""
override_exec=""

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

  # Extract overrides if present
  if [[ -f "$CONFIG" ]]; then
    if command -v jq >/dev/null 2>&1; then
      override_read="$(jq -r '.command_override.read // empty' "$CONFIG" 2>/dev/null)"
      override_exec="$(jq -r '.command_override.exec // empty' "$CONFIG" 2>/dev/null)"
    elif command -v python3 >/dev/null 2>&1; then
      override_read="$(python3 -c "import json; print(json.load(open('$CONFIG')).get('command_override', {}).get('read', ''))" 2>/dev/null)"
      override_exec="$(python3 -c "import json; print(json.load(open('$CONFIG')).get('command_override', {}).get('exec', ''))" 2>/dev/null)"
    else
      # fallback crude regex
      override_read="$(grep -o '"read"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" 2>/dev/null | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')"
      override_exec="$(grep -o '"exec"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" 2>/dev/null | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')"
    fi
  fi

  if [[ -n "$config_test_cmd" ]]; then
    ok "test_command: $config_test_cmd"; echo ""
  else
    warn "no test_command configured"; echo ""
  fi
}

# ── per-agent checks ──
check_agent() {
  local agent="$1"

  # Check if this agent is the configured one AND has overrides
  local has_override=false
  if [[ "$agent" == "${DELEGATE_AGENT:-$config_agent}" ]] && \
     [[ -n "$override_read" || -n "$override_exec" ]]; then
    has_override=true
  fi

  if $has_override; then
    printf "%-12s" "$agent:"

    local override_desc=""
    local overrides_valid=true

    if [[ -n "$override_read" ]]; then
      local first_token
      read -r first_token _ <<< "$override_read"
      if command -v "$first_token" >/dev/null 2>&1; then
        override_desc="read: '$override_read'"
      else
        override_desc="read: '$override_read' (missing '$first_token')"
        overrides_valid=false
      fi
    fi

    if [[ -n "$override_exec" ]]; then
      local first_token
      read -r first_token _ <<< "$override_exec"
      local exec_desc
      if command -v "$first_token" >/dev/null 2>&1; then
        exec_desc="exec: '$override_exec'"
      else
        exec_desc="exec: '$override_exec' (missing '$first_token')"
        overrides_valid=false
      fi

      if [[ -n "$override_desc" ]]; then
        override_desc="$override_desc, $exec_desc"
      else
        override_desc="$exec_desc"
      fi
    fi

    if $overrides_valid; then
      ok "$override_desc"
      printf "  "
      ok "authenticated"
      echo ""
      return 0
    else
      fail "$override_desc"
      echo ""
      return 1
    fi
  fi

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
  target="${DELEGATE_AGENT:-$config_agent}"
  if [[ -n "$target" ]]; then
    # check if target is already in KNOWN_AGENTS
    in_known=false
    for a in "${KNOWN_AGENTS[@]}"; do
      [[ "$a" == "$target" ]] && in_known=true
    done
    if ! $in_known; then
      agents_to_check+=("$target")
    fi
  fi
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
