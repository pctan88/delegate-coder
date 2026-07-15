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
marketplace_path = root / ".agents" / "plugins" / "marketplace.json"

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["name"] == "delegate-coder"
assert re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", manifest["version"])
assert isinstance(manifest["description"], str) and manifest["description"].strip()
assert manifest["author"]["name"] == "Tan"
assert manifest["skills"] == "./skills/"
assert "hooks" not in manifest
assert (plugin_root / "skills" / "delegate-coder" / "SKILL.md").is_file()

interface = manifest["interface"]
for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
    assert isinstance(interface[field], str) and interface[field].strip(), field
assert isinstance(interface["capabilities"], list) and interface["capabilities"]
assert isinstance(interface["defaultPrompt"], list) and 1 <= len(interface["defaultPrompt"]) <= 3

marketplace = json.loads(marketplace_path.read_text(encoding="utf-8"))
assert marketplace["name"] == "tan-tools"
entries = [entry for entry in marketplace["plugins"] if entry.get("name") == "delegate-coder"]
assert len(entries) == 1
entry = entries[0]
assert entry["source"] == {"source": "local", "path": "./plugins/delegate-coder"}
assert entry["policy"] == {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}
assert entry["category"] == "Productivity"

print("Codex package validation passed")
PY
