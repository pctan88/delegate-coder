#!/usr/bin/env bash
# codex-package.test.sh — validate the Codex manifest and repo marketplace.
# Uses only Python's standard library; no network, model, or Codex install is required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

python3 - <<'PY'
import json
import os
import re
from pathlib import Path

root = Path(os.environ["REPO_ROOT"])
plugin_root = root / "plugins" / "delegate-coder"
manifest_path = plugin_root / ".codex-plugin" / "plugin.json"
claude_manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
marketplace_path = root / ".agents" / "plugins" / "marketplace.json"
claude_marketplace_path = root / ".claude-plugin" / "marketplace.json"

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["name"] == "delegate-coder"
assert re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", manifest["version"])
claude_manifest = json.loads(claude_manifest_path.read_text(encoding="utf-8"))
assert claude_manifest["version"] == manifest["version"]
assert isinstance(manifest["description"], str) and manifest["description"].strip()
assert manifest["author"]["name"] == "Tan"
assert manifest["skills"] == "./skills/"
assert "hooks" not in manifest
assert (plugin_root / "skills" / "delegate-coder" / "SKILL.md").is_file()
onboarding = plugin_root / "skills" / "delegate-coder-codex-onboarding" / "SKILL.md"
assert onboarding.is_file()
onboarding_text = onboarding.read_text(encoding="utf-8")
for marker in (".delegate-coder/config.json", "qwen", "ollama", "ask", "confirmation"):
    assert marker in onboarding_text.lower(), marker

for command_name in ("delegate-setup.md", "delegate-model.md", "delegate-on.md", "delegate-off.md", "delegate-scope.md"):
    command_text = (plugin_root / "commands" / command_name).read_text(encoding="utf-8")
    assert ".delegate-coder/config.json" in command_text, command_name
    # A legacy path may be documented only as an explicit fallback, never as
    # the unconditional destination used by the old Claude-only commands.
    if ".claude/delegate-coder.json" in command_text:
        assert "existing" in command_text and "legacy" in command_text, command_name

interface = manifest["interface"]
for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
    assert isinstance(interface[field], str) and interface[field].strip(), field
assert isinstance(interface["capabilities"], list) and interface["capabilities"]
assert isinstance(interface["defaultPrompt"], list) and 1 <= len(interface["defaultPrompt"]) <= 3

marketplace = json.loads(marketplace_path.read_text(encoding="utf-8"))
claude_marketplace = json.loads(claude_marketplace_path.read_text(encoding="utf-8"))
assert marketplace["name"] == "tan-tools"
entries = [entry for entry in marketplace["plugins"] if entry.get("name") == "delegate-coder"]
assert len(entries) == 1
entry = entries[0]
assert entry["source"] == {"source": "local", "path": "./plugins/delegate-coder"}
assert entry["policy"] == {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}
assert entry["category"] == "Productivity"
claude_entries = [entry for entry in claude_marketplace["plugins"] if entry.get("name") == "delegate-coder"]
assert len(claude_entries) == 1
assert claude_entries[0]["version"] == manifest["version"]

print("Codex package validation passed")
PY
