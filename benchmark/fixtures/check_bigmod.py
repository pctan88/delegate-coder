"""Verify a regenerated bigmod file: target function changed, helpers intact.

Usage: check_bigmod.py <module_name> <expected_json>
Exits 0 only if compute_summary returns the median AND every metric_NN helper
still returns exactly what it returned before the edit.
"""
import importlib
import json
import pathlib
import sys


def main():
    module_name, expected_path = sys.argv[1], sys.argv[2]
    expected = json.loads(pathlib.Path(expected_path).read_text())
    sys.path.insert(0, str(pathlib.Path(expected_path).parent))
    module = importlib.import_module(module_name)

    sample = expected["sample"]
    got = module.compute_summary(list(sample))
    want = expected["compute_summary_median"]
    if got != want:
        print(f"FAIL compute_summary: got {got!r}, want median {want!r}")
        return 1

    drifted = []
    for name, want_value in sorted(expected["helpers"].items()):
        function = getattr(module, name, None)
        if function is None:
            drifted.append(f"{name}: MISSING")
            continue
        try:
            got_value = function(list(sample))
        except Exception as exc:
            drifted.append(f"{name}: raised {exc!r}")
            continue
        if got_value != want_value:
            drifted.append(f"{name}: got {got_value!r}, want {want_value!r}")

    if drifted:
        print(f"FAIL fidelity: {len(drifted)}/{len(expected['helpers'])} helpers drifted")
        for line in drifted[:10]:
            print("  " + line)
        return 1

    print(f"OK ({len(expected['helpers'])} helpers intact, compute_summary=median)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
