"""validate_context_files.py — shared context-file security validation.

Both delegate.sh and contract-router.sh import this module (via sys.path
injection) so that security rules live in exactly one place.  A future rule
change—blocked dir, secret keyword, size cap—needs to be made here only.

Usage from a bash heredoc:
    python3 - "$ROOT_DIR" "$CF1" "$CF2" \
      "$(python3 -c 'import sys; sys.path.insert(0,"."); import ...')"

Or import directly:
    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).parent))
    from validate_context_files import validate
    validate(context_files, root_dir, label="delegate")

Raises SystemExit with a human-readable message on the first violation.
Returns total size in bytes on success.
"""
import pathlib
import sys
from pathlib import PurePosixPath

_BLOCKED_DIRS = frozenset([".aws", ".ssh", ".kube", ".docker", ".git"])
_SECRET_NAMES = frozenset([".npmrc", ".netrc", ".git-credentials"])
_SECRET_KEYWORDS = [
    "credential", "private_key", "secret", "password",
    "passwd", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
]
_SECRET_EXTENSIONS = frozenset([
    ".pem", ".key", ".pkcs12", ".pfx", ".p12", ".gpg", ".pgp", ".vault",
])

_MAX_FILE_BYTES = 65536    # 64 KB per file
_MAX_TOTAL_BYTES = 262144  # 256 KB cumulative


def validate(context_files, root_dir, label="context file"):
    """Validate *context_files* (list[str]) against *root_dir* (str|Path).

    *label* is used in error messages to identify the calling site.
    Raises SystemExit on the first violation; returns total bytes on success.
    """
    root = pathlib.Path(root_dir).resolve()
    total_size = 0

    for cf in context_files:
        if not isinstance(cf, str) or not cf:
            raise SystemExit(f"{label}: context_files items must be non-empty strings")

        cf_pure = PurePosixPath(cf)

        # --- traversal / absolute / home-relative ---
        if cf_pure.is_absolute() or cf.startswith("~/") or ".." in cf_pure.parts:
            raise SystemExit(
                f"{label}: context file resolves outside the repository: {cf}"
            )

        # --- blocked sensitive directories (case-insensitive) ---
        for part in cf_pure.parts:
            if part.lower() in _BLOCKED_DIRS:
                raise SystemExit(
                    f"{label}: context file path contains a blocked sensitive"
                    f" directory: {cf}"
                )

        # --- secret-like filenames ---
        cf_name = cf_pure.name.lower()
        if (
            cf_name.startswith(".env")
            or cf_name in _SECRET_NAMES
            or any(kw in cf_name for kw in _SECRET_KEYWORDS)
            or any(cf_name.endswith(ext) for ext in _SECRET_EXTENSIONS)
        ):
            raise SystemExit(
                f"{label}: context file contains sensitive/secret data: {cf}"
            )

        cf_path = root / pathlib.Path(cf)
        if not cf_path.exists():
            raise SystemExit(f"{label}: context file does not exist: {cf}")

        # --- resolved path must stay inside root ---
        root_real = root.resolve()
        cf_path_real = cf_path.resolve(strict=True)
        if root_real not in cf_path_real.parents and cf_path_real != root_real:
            raise SystemExit(
                f"{label}: context file resolves outside the repository: {cf}"
            )

        # --- symlink anywhere in the path component chain (including the leaf) ---
        current = root
        for part in pathlib.Path(cf).parts:
            current = current / part
            if current.is_symlink():
                raise SystemExit(
                    f"{label}: context file path contains a symlink: {cf}"
                )

        if not cf_path.is_file():
            raise SystemExit(f"{label}: context file must be a regular file: {cf}")

        # --- size caps ---
        file_size = cf_path.stat().st_size
        if file_size > _MAX_FILE_BYTES:
            raise SystemExit(f"{label}: context file size exceeds 64KB: {cf}")
        total_size += file_size
        if total_size > _MAX_TOTAL_BYTES:
            raise SystemExit(f"{label}: total context files size exceeds 256KB")

    return total_size


if __name__ == "__main__":
    # Standalone: python3 validate_context_files.py <root_dir> [file ...]
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <root_dir> [context_file ...]", file=sys.stderr)
        sys.exit(2)
    validate(sys.argv[2:], sys.argv[1], label="validate_context_files")
