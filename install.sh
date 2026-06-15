#!/usr/bin/env bash
# install.sh — install the delegate-coder skill for Claude Code.
# Usage: install.sh [--target <dir>]   (default: ~/.claude/skills)
set -euo pipefail
TARGET="$HOME/.claude/skills"
[ "${1:-}" = "--target" ] && TARGET="$2"
REPO="https://github.com/pctan88/delegate-coder"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Installing delegate-coder skill to $TARGET ..."
git clone --depth 1 "$REPO" "$TMP/repo" 2>/dev/null || { echo "git clone failed — check the repo URL"; exit 1; }
mkdir -p "$TARGET"
rm -rf "$TARGET/delegate-coder"
cp -r "$TMP/repo/skills/delegate-coder" "$TARGET/delegate-coder"
chmod +x "$TARGET/delegate-coder/scripts/"*.sh
echo "Installed. Open Claude Code and try: \"use the delegate worker to summarize this repo\""
