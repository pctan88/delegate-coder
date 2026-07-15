#!/usr/bin/env bash
# detect-test.sh — infer the project's test command from on-disk markers.
# Prints ONE inferred command to stdout, or nothing if undetermined.
# Detection only PRE-FILLS a suggestion; the setup flow must confirm/override.
#
# Priority order is deliberate (most common / least ambiguous first). A repo
# with markers for several ecosystems resolves to the first match here.
set -u

DIR="${1:-.}"
cd "$DIR" 2>/dev/null || exit 0

# 1. Node — package.json with a real "test" script. Skip npm's default
# placeholder, whose distinctive phrase is "no test specified".
if [[ -f package.json ]] && grep -Eq '"test"[[:space:]]*:' package.json; then
  if ! grep -q 'no test specified' package.json; then
    echo "npm test"
    exit 0
  fi
fi

# 2. Python — pytest config, a pyproject mentioning pytest, or a tests/ dir.
if [[ -f pytest.ini ]] \
   || { [[ -f pyproject.toml ]] && grep -q pytest pyproject.toml 2>/dev/null; } \
   || [[ -d tests ]]; then
  # Phase 1: Smart Test Verification
  if command -v pytest >/dev/null 2>&1; then
    echo "python3 -m pytest -q"
  else
    echo "python3 -m unittest discover"
  fi
  exit 0
fi

# 3. Go
if [[ -f go.mod ]]; then
  echo "go test ./..."
  exit 0
fi

# 4. Rust
if [[ -f Cargo.toml ]]; then
  echo "cargo test"
  exit 0
fi

# 5. Makefile with a `test:` target
if [[ -f Makefile ]] && grep -Eq '^test:' Makefile; then
  echo "make test"
  exit 0
fi

# Nothing recognized — print nothing; the caller asks the user.
exit 0
