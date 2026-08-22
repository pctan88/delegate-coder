#!/usr/bin/env bash
# Guard against the Homebrew plist gotcha that silently breaks the local stack.
#
# `brew services` regenerates ~/Library/LaunchAgents/homebrew.mxcl.ollama.plist
# from the Cellar template on every restart, and a freshly upgraded template
# ships WITHOUT the custom env vars. The server then falls back to ~/.ollama,
# finds no models, and every request returns a bare 404 "model not found" — with
# nothing pointing at the real cause. Seen for real on 2026-08-21.
#
# Exit 0 = healthy. Exit 1 = misconfigured (details on stdout).
# Read-only: reports, never edits.
set -uo pipefail

MODELS_EXPECTED="${OLLAMA_MODELS_EXPECTED:-/Users/pctan/Cowork/AI/models}"
CTX_EXPECTED="${OLLAMA_CONTEXT_EXPECTED:-65536}"
KEEPALIVE_EXPECTED="${OLLAMA_KEEPALIVE_EXPECTED:-1h}"
HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
LABEL=homebrew.mxcl.ollama
problems=0

note() { printf '  %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; problems=$((problems + 1)); }
good() { printf '  ✓ %s\n' "$1"; }

echo "Ollama environment check"

# 1. The live launchd environment is what actually governs the server.
echo "loaded service env:"
if ! env_dump="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"; then
  bad "service $LABEL is not loaded (start it: brew services start ollama)"
else
  loaded="$(printf '%s' "$env_dump" | sed -n '/environment = {/,/}/p')"
  check_var() {
    local key="$1" want="$2" got
    got="$(printf '%s' "$loaded" | sed -n "s/.*$key => \(.*\)/\1/p" | head -n1)"
    if [[ -z "$got" ]]; then
      bad "$key is MISSING from the loaded service env (expected $want)"
    elif [[ "$got" != "$want" ]]; then
      bad "$key is '$got', expected '$want'"
    else
      good "$key = $got"
    fi
  }
  check_var OLLAMA_MODELS "$MODELS_EXPECTED"
  check_var OLLAMA_CONTEXT_LENGTH "$CTX_EXPECTED"
  check_var OLLAMA_KEEP_ALIVE "$KEEPALIVE_EXPECTED"
fi

# 2. The Cellar template decides what survives the next `brew services restart`.
echo "cellar template (survives brew services restart):"
template="$(ls -t /opt/homebrew/Cellar/ollama/*/homebrew.mxcl.ollama.plist 2>/dev/null | head -n1)"
if [[ -z "$template" ]]; then
  note "- no template found; skipping (non-Homebrew install?)"
else
  note "- $template"
  missing=()
  for key in OLLAMA_MODELS OLLAMA_CONTEXT_LENGTH OLLAMA_KEEP_ALIVE; do
    grep -q "$key" "$template" || missing+=("$key")
  done
  if ((${#missing[@]})); then
    bad "template is missing: ${missing[*]}"
    note "  -> the running service may be fine now, but the next"
    note "     'brew services restart ollama' will silently drop these."
    note "  Fix (per AI/SETUP.md, edit the TEMPLATE not the LaunchAgent):"
    note "     /usr/libexec/PlistBuddy \\"
    note "       -c \"Add :EnvironmentVariables:OLLAMA_MODELS string $MODELS_EXPECTED\" \\"
    note "       -c \"Add :EnvironmentVariables:OLLAMA_CONTEXT_LENGTH string $CTX_EXPECTED\" \\"
    note "       -c \"Add :EnvironmentVariables:OLLAMA_KEEP_ALIVE string $KEEPALIVE_EXPECTED\" \\"
    note "       -c Save '$template'"
  else
    good "all three custom keys present"
  fi
fi

# 3. Does the server actually serve the models we expect?
echo "server:"
if ! tags="$(curl -fsS --noproxy '*' --max-time 10 "$HOST/api/tags" 2>/dev/null)"; then
  bad "no response from $HOST"
else
  count="$(printf '%s' "$tags" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("models") or []))' 2>/dev/null || echo 0)"
  if [[ "$count" == "0" ]]; then
    bad "server reports 0 models — it is almost certainly reading the wrong OLLAMA_MODELS"
    if [[ -d "$MODELS_EXPECTED/manifests" ]]; then
      on_disk="$(find "$MODELS_EXPECTED/manifests" -type f 2>/dev/null | wc -l | tr -d ' ')"
      note "  $on_disk model manifests DO exist at $MODELS_EXPECTED"
      note "  Nothing is lost — this is a config fault, not data loss."
    fi
  else
    good "$count models visible"
  fi
fi

echo
if ((problems)); then
  echo "FAIL: $problems problem(s). The local worker will not work until fixed."
  exit 1
fi
echo "OK: local Ollama stack is configured as expected."
