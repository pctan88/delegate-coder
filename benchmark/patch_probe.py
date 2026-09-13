#!/usr/bin/env python3
"""Can a local worker emit reliable exact-match edits instead of whole files?

Whole-file contract mode pays a ~99% re-transcription tax: bigmod_large emitted
3954 output tokens to express ~23 tokens of change, and hits a hard ~45 KB
ceiling at num_ctx 32768. Targeted edits would remove both problems — IF the
model can reproduce anchor text byte-for-byte. Local models are widely
unreliable at this, so it has to be measured, not assumed.

Two formats, because they fail differently:
  json   - schema-constrained {"edits":[{"search":..,"replace":..}]}. Guarantees
           well-formed output, but the anchor must survive JSON escaping.
  blocks - Aider-style <<<<<<< SEARCH / ======= / >>>>>>> REPLACE fences. No
           escaping to get wrong, but no format guarantee either.

Applies edits strictly: an anchor must occur exactly once. Ambiguous and
not-found are recorded separately so the failure mode is legible.

Writes only into --out. Every rep runs in a throwaway git-archive sandbox.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from freeform_probe import TASKS, call, load_tasks, sandbox  # noqa: E402

EDIT_SCHEMA = {
    "type": "object",
    "properties": {
        "edits": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"search": {"type": "string"}, "replace": {"type": "string"}},
                "required": ["search", "replace"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["edits"],
    "additionalProperties": False,
}

SYSTEM_JSON = (
    "You are a precise code editor. You will be given a file and a requested change. "
    "Return ONLY a JSON object with an \"edits\" array. Each edit has \"search\" and "
    "\"replace\". The \"search\" value MUST be text copied byte-for-byte from the file, "
    "including exact indentation, and MUST appear exactly once in the file. Keep each "
    "search block as small as possible while staying unique. Never return the whole "
    "file. To insert new code, search for the unique existing line or block it should "
    "attach to and include that text in the replacement."
)

SYSTEM_BLOCKS = (
    "You are a precise code editor. You will be given a file and a requested change. "
    "Reply with one or more edit blocks in exactly this form:\n"
    "<<<<<<< SEARCH\n"
    "(text copied byte-for-byte from the file, exact indentation, occurring exactly once)\n"
    "=======\n"
    "(the replacement text)\n"
    ">>>>>>> REPLACE\n"
    "Keep each SEARCH section as small as possible while staying unique. Never return "
    "the whole file. To insert new code, anchor on the unique existing line or block it "
    "should attach to and repeat that text in the REPLACE section. Output nothing "
    "except edit blocks."
)

BLOCK_RE = re.compile(
    r"<{5,9}\s*SEARCH\s*\n(.*?)\n?={5,9}\s*\n(.*?)\n?>{5,9}\s*REPLACE", re.S
)


def parse_blocks(text):
    return [{"search": m.group(1), "replace": m.group(2)} for m in BLOCK_RE.finditer(text)]


def apply_edits(source, edits):
    """Apply strictly. Returns (new_text, diagnostics).

    Matching is plain substring, as real patch appliers do, and an anchor must
    occur exactly once. This is deliberately the generous reading: it accepts
    legitimate mid-line anchors, so it measures the model's ceiling rather than
    penalising a valid style. The cost is that an under-indented anchor can
    match inside a longer run of whitespace and apply with broken indentation --
    that class of damage is caught downstream by the syntax check and by the
    task checkers, which verify every function's actual behaviour.
    """
    text = source
    diag = {"proposed": len(edits), "applied": 0, "not_found": 0, "ambiguous": 0,
            "empty_search": 0, "first_failure": None}
    if not edits:
        return None, diag
    for edit in edits:
        search, replace = edit.get("search", ""), edit.get("replace", "")
        if not search:
            diag["empty_search"] += 1
            diag["first_failure"] = diag["first_failure"] or "empty search"
            continue
        count = text.count(search)
        if count == 0:
            diag["not_found"] += 1
            if diag["first_failure"] is None:
                diag["first_failure"] = f"not found: {search[:90]!r}"
            continue
        if count > 1:
            diag["ambiguous"] += 1
            if diag["first_failure"] is None:
                diag["first_failure"] = f"{count}x ambiguous: {search[:90]!r}"
            continue
        text = text.replace(search, replace, 1)
        diag["applied"] += 1
    if diag["applied"] == 0:
        return None, diag
    return text, diag


def run_rep(repo, task_name, task, model, fmt, think, num_ctx, timeout):
    import tempfile
    with tempfile.TemporaryDirectory(prefix="patch-probe.") as work:
        root = pathlib.Path(work) / "repo"
        sandbox(repo, root)
        target = root / task["target"]
        source = target.read_text()

        user = (f"Target file: {task['target']}\n\nRequested change:\n{task['instructions']}"
                f"\n\nCurrent full file contents:\n{source}\n")
        # Deliberately bounded: enough for real edits, not enough to smuggle the
        # whole file through a giant SEARCH block. Truncation here is a finding.
        budget = max(1024, len(source.encode()) // 4)

        payload = {
            "model": model,
            "system": SYSTEM_JSON if fmt == "json" else SYSTEM_BLOCKS,
            "prompt": user,
            "stream": False,
            "options": {"num_ctx": num_ctx, "temperature": 0, "num_predict": budget},
            "keep_alive": "30m",
        }
        if fmt == "json":
            payload["format"] = EDIT_SCHEMA
        if think is not None:
            payload["think"] = think

        record = {"task": task_name, "model": model, "format": fmt, "think": think,
                  "num_predict": budget, "source_bytes": len(source.encode())}
        start = time.time()
        try:
            response = call(payload, timeout)
        except Exception as exc:
            record.update(status="REQUEST_ERROR", detail=str(exc)[:200],
                          wall_seconds=round(time.time() - start, 2))
            return record
        record["wall_seconds"] = round(time.time() - start, 2)
        for key in ("done_reason", "eval_count", "prompt_eval_count"):
            record[key] = response.get(key)
        raw = response.get("response") or ""
        record["response_chars"] = len(raw)

        if response.get("done_reason") == "length":
            record["status"] = "TRUNCATED"
            return record
        if not raw.strip():
            record["status"] = "EMPTY_RESPONSE"
            return record

        if fmt == "json":
            try:
                edits = json.loads(raw)["edits"]
            except Exception as exc:
                record.update(status="PARSE_FAIL", detail=str(exc)[:200])
                return record
        else:
            edits = parse_blocks(raw)
            if not edits:
                record.update(status="NO_BLOCKS", detail=raw.strip()[:160])
                return record

        updated, diag = apply_edits(source, edits)
        record.update({f"edits_{k}": v for k, v in diag.items() if k != "first_failure"})
        if diag["first_failure"]:
            record["detail"] = diag["first_failure"]
        if updated is None:
            record["status"] = "APPLY_FAIL"
            return record

        target.write_text(updated)
        try:
            compile(updated, str(target), "exec")
        except SyntaxError as exc:
            record.update(status="SYNTAX_FAIL", detail=f"line {exc.lineno}: {exc.msg}")
            return record

        proc = subprocess.run(["bash", "-c", task["test"]], cwd=root,
                              capture_output=True, text=True, timeout=300)
        record["status"] = "PASS" if proc.returncode == 0 else "TEST_FAIL"
        if proc.returncode != 0:
            record["detail"] = (proc.stdout + proc.stderr).strip().split("\n")[0][:200]
        return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--tasks", nargs="+", required=True)
    parser.add_argument("--formats", nargs="+", default=["json", "blocks"])
    parser.add_argument("--configs", nargs="+", required=True,
                        help="model[|think] where think is on|off|unset")
    parser.add_argument("--num-ctx", type=int, default=32768)
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()

    repo = pathlib.Path(__file__).resolve().parent.parent
    load_tasks(repo)
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    for spec in args.configs:
        model, _, think_word = spec.partition("|")
        think = {"on": True, "true": True, "off": False, "false": False,
                 "": None, "unset": None}[think_word]
        for fmt in args.formats:
            for task_name in args.tasks:
                for rep in range(1, args.reps + 1):
                    record = run_rep(repo, task_name, TASKS[task_name], model, fmt,
                                     think, args.num_ctx, args.timeout)
                    record["rep"] = rep
                    with out.open("a") as stream:
                        stream.write(json.dumps(record) + "\n")
                    print(f"{task_name:16s} {model:16s} {fmt:6s} rep{rep} "
                          f"{record['status']:14s} {record['wall_seconds']:6.1f}s "
                          f"eval={str(record.get('eval_count')):>5s} "
                          f"edits={record.get('edits_applied', 0)}/{record.get('edits_proposed', 0)}"
                          + (f"  {record['detail'][:70]}" if record.get("detail") else ""),
                          flush=True)
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
