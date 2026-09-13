"""validate_dependency_manifest.py — dependency version safety guard for package.json contracts.

contract-router.sh imports this module (via sys.path injection) to guard
against two failure modes observed in local-worker (qwen3-coder:30b) output
when a Task Contract targets a Node/npm package manifest:

  1. A version string that is not a recognizable semver (a hallucinated or
     malformed version number).
  2. A silent downgrade of an existing dependency's major/minor/patch version
     — the worker moves a package the wrong direction instead of upgrading it
     (observed: keycloak-angular downgraded instead of moved to the
     Angular-22-compatible major during a real migration contract).

Only the manifests in MANIFEST_NAMES trigger this guard. Version forms we
cannot safely compare (workspace:, git/http URLs, `latest`, `*`, file:/link:
paths) are skipped rather than rejected, to avoid false positives on
legitimate patterns.

Usage from a bash heredoc (mirrors validate_context_files.py):
    import sys, os
    sys.path.insert(0, os.environ["SCRIPT_LIB"])
    from validate_dependency_manifest import check
    check(manifest_name, original_text, candidate_text, allow_downgrade, label="contract-router")

Raises SystemExit with every finding on the first scan that turns up a
violation. Returns None on success.
"""
import json
import re
import sys

MANIFEST_NAMES = frozenset(["package.json"])

_SECTIONS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")
_RANGE_PREFIX = re.compile(r"^(\^|~|>=|<=|>|<|=)+")
_SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$")
_UNVALIDATABLE = re.compile(
    r"^(workspace:|npm:|file:|link:|git\+|git:|https?://|\*$|latest$|next$|\d+(?:\.\d+)?$|\d+(?:\.\d+)?\.[xX*]$|\d+\.[xX*]$|[xX*]$)"
)


def _parse(raw):
    """Return a (major, minor, patch) tuple, the string "invalid", or None (skip)."""
    if not isinstance(raw, str) or not raw.strip():
        return "invalid"
    stripped = _RANGE_PREFIX.sub("", raw.strip())
    if _UNVALIDATABLE.match(stripped):
        return None
    match = _SEMVER.match(stripped)
    if not match:
        return "invalid"
    return tuple(int(part) for part in match.groups())


def check(manifest_name, original_text, candidate_text, allow_downgrade=None, label="dependency guard"):
    """Compare *original_text* and *candidate_text* (raw manifest file contents).

    *allow_downgrade* is `True` (allow every downgrade in this contract) or a
    list of package names explicitly permitted to move backward. Raises
    SystemExit with every finding on the first violation; returns None on
    success (including when *manifest_name* is not a guarded manifest).
    """
    if manifest_name not in MANIFEST_NAMES:
        return None

    try:
        old = json.loads(original_text) if original_text.strip() else {}
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{label}: existing {manifest_name} is not valid JSON: {exc.msg}")
    try:
        new = json.loads(candidate_text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{label}: generated {manifest_name} is not valid JSON: {exc.msg}")

    if not isinstance(old, dict):
        old = {}
    if not isinstance(new, dict):
        raise SystemExit(f"{label}: generated {manifest_name} must be a JSON object")

    allow_all = allow_downgrade is True
    allow_names = set(allow_downgrade) if isinstance(allow_downgrade, list) else set()

    findings = []
    for section in _SECTIONS:
        old_deps = old.get(section) if isinstance(old.get(section), dict) else {}
        new_deps = new.get(section) if isinstance(new.get(section), dict) else {}
        for name, new_version in new_deps.items():
            parsed_new = _parse(new_version)
            if parsed_new == "invalid":
                findings.append(
                    f"{section}.{name}: not a recognizable version (got {new_version!r})"
                )
                continue
            if parsed_new is None:
                continue  # unvalidatable form (workspace:, git url, range keyword, etc.)
            old_version = old_deps.get(name)
            if not isinstance(old_version, str):
                continue  # newly added dependency, nothing to compare against
            parsed_old = _parse(old_version)
            if parsed_old is None or parsed_old == "invalid":
                continue  # can't compare against an unvalidatable/invalid baseline
            if parsed_new < parsed_old and not (allow_all or name in allow_names):
                findings.append(
                    f"{section}.{name}: downgrade from {old_version} to {new_version} "
                    f'(add "allow_downgrade": ["{name}"] to the contract if intentional)'
                )

    if findings:
        message = "\n".join(f"  - {item}" for item in findings)
        raise SystemExit(f"{label}: dependency manifest guard failed:\n{message}")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(f"usage: {sys.argv[0]} <manifest_name> <original_file> <candidate_file> [allow_downgrade_json]", file=sys.stderr)
        sys.exit(2)
    manifest_name, original_path, candidate_path = sys.argv[1:4]
    allow_arg = json.loads(sys.argv[4]) if len(sys.argv) > 4 else []
    with open(original_path, encoding="utf-8") as handle:
        original_text = handle.read()
    with open(candidate_path, encoding="utf-8") as handle:
        candidate_text = handle.read()
    check(manifest_name, original_text, candidate_text, allow_arg, label="validate_dependency_manifest")
