#!/usr/bin/env python3
"""Additive probe for behaviour the contract harness cannot measure.

Two modes:
  freeform  - no JSON-schema `format`, so a thinking model actually reasons.
              Compares think=off vs think=on vs the current worker.
  scaling   - contract-style (schema-constrained) whole-file regeneration of
              progressively larger files, to find where fidelity breaks down.

Writes only into --out. Never mutates the repo: every rep runs in a throwaway
`git archive HEAD` sandbox.
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HOST = "http://127.0.0.1:11434"
SYSTEM_FREEFORM = (
    "You are a precise coding assistant. Apply the requested change to the file, "
    "then output the ENTIRE updated file as one fenced code block and nothing else. "
    "Preserve all existing content that does not need to change."
)
SYSTEM_CONTRACT = (
    "You are a precise coding compiler. Read the file provided, apply the requested "
    "changes, and return only a valid JSON object with one string field named "
    "updated_file containing the ENTIRE updated file. Do not return markdown, code "
    "fences, commentary, diffs, or additional fields. Preserve all existing content "
    "not required to change."
)
SCHEMA = {
    "type": "object",
    "properties": {"updated_file": {"type": "string"}},
    "required": ["updated_file"],
    "additionalProperties": False,
}

TASKS = {}


def load_tasks(repo):
    """Reuse the shell task definitions so both drivers stay in sync."""
    script = repo / "benchmark" / "model_matrix_tasks.sh"
    for name in ("T1_simple", "T2_algorithmic", "T3_refactor"):
        dump = subprocess.run(
            ["bash", "-c", f'source "{script}"; task_{name}; '
                           f'printf "%s\\x00%s\\x00%s\\x00%s" '
                           f'"$LABEL" "$TARGET_FILE" "$INSTRUCTIONS" "$TEST_COMMAND"'],
            capture_output=True, text=True, check=True).stdout
        label, target, instructions, test_command = dump.split("\x00")
        TASKS[label] = {"target": target, "instructions": instructions, "test": test_command}
    # Large-file fidelity tasks, contract-style only.
    for size in ("med", "large", "xl"):
        TASKS[f"S-bigmod-{size}"] = {
            "target": f"benchmark/fixtures/bigmod_{size}.py",
            "instructions": (
                "Change compute_summary(values) so it returns the median of values "
                "instead of the mean. Keep the empty-input behaviour (return 0). "
                "Every other function in the file must be reproduced byte-for-byte "
                "unchanged."
            ),
            "test": f"python3 benchmark/fixtures/check_bigmod.py bigmod_{size} "
                    f"benchmark/fixtures/bigmod_{size}_expected.json",
        }


def sandbox(repo, dest):
    dest.mkdir(parents=True, exist_ok=True)
    archive = subprocess.run(["git", "-C", str(repo), "archive", "HEAD"],
                             capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", str(dest)], input=archive, check=True)


def call(payload, timeout):
    request = urllib.request.Request(
        f"{HOST}/api/generate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def extract_code(text):
    # Any info string may follow the opening fence (models sometimes echo prompt
    # wording there), so accept the whole rest of that line.
    blocks = re.findall(r"^```[^\n]*\n(.*?)^```", text, re.S | re.M)
    if blocks:
        return max(blocks, key=len)
    stripped = text.strip()
    if stripped.startswith("```"):
        body = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        return body.rsplit("```", 1)[0] if body.rstrip().endswith("```") else body
    return text


def run_rep(repo, task_name, task, model, think, mode, num_ctx, think_headroom, timeout):
    with tempfile.TemporaryDirectory(prefix="freeform-probe.") as work:
        root = pathlib.Path(work) / "repo"
        sandbox(repo, root)
        target = root / task["target"]
        source = target.read_text()

        user = (f"Target file: {task['target']}\n\nRequested change:\n{task['instructions']}"
                f"\n\nCurrent full file contents:\n{source}\n")
        # JSON-escaped whole-file output inflates well past len/3 tokens, so the
        # schema-constrained path needs a markedly larger budget than free-form.
        if mode == "scaling":
            budget = max(256, len(source.encode()) // 2) + 1024
        else:
            budget = max(256, (len(source.encode()) + 2) // 3) + 512
        if think:
            budget += think_headroom

        payload = {
            "model": model,
            "system": SYSTEM_CONTRACT if mode == "scaling" else SYSTEM_FREEFORM,
            "prompt": user,
            "stream": False,
            "options": {"num_ctx": num_ctx, "temperature": 0, "num_predict": budget},
            "keep_alive": "30m",
        }
        if mode == "scaling":
            payload["format"] = SCHEMA
        if think is not None:
            payload["think"] = think

        record = {"task": task_name, "model": model, "think": think, "mode": mode,
                  "num_predict": budget}
        start = time.time()
        try:
            response = call(payload, timeout)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            record.update(status="REQUEST_ERROR", detail=str(exc)[:200],
                          wall_seconds=round(time.time() - start, 2))
            return record
        record["wall_seconds"] = round(time.time() - start, 2)

        for key in ("done_reason", "eval_count", "prompt_eval_count"):
            record[key] = response.get(key)
        thinking = response.get("thinking") or ""
        raw = response.get("response") or ""
        record["thinking_chars"] = len(thinking)
        record["response_chars"] = len(raw)

        if response.get("done_reason") == "length":
            record["status"] = "TRUNCATED"
            return record
        if not raw:
            record["status"] = "EMPTY_RESPONSE"
            return record

        if mode == "scaling":
            try:
                parsed = json.loads(raw)
                updated = parsed["updated_file"]
            except Exception as exc:
                record.update(status="PARSE_FAIL", detail=str(exc)[:200])
                return record
        else:
            updated = extract_code(raw)

        target.write_text(updated.rstrip("\r\n") + "\n")
        try:
            compile(target.read_text(), str(target), "exec")
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
    parser.add_argument("--mode", choices=["freeform", "scaling"], required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--tasks", nargs="+", required=True)
    parser.add_argument("--configs", nargs="+", required=True,
                        help='model[:think] where think is on|off|unset')
    parser.add_argument("--num-ctx", type=int, default=32768)
    parser.add_argument("--think-headroom", type=int, default=4096)
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
        for task_name in args.tasks:
            task = TASKS[task_name]
            for rep in range(1, args.reps + 1):
                record = run_rep(repo, task_name, task, model, think, args.mode,
                                 args.num_ctx, args.think_headroom, args.timeout)
                record["rep"] = rep
                with out.open("a") as stream:
                    stream.write(json.dumps(record) + "\n")
                print(f"{task_name:18s} {model:16s} think={str(think):5s} "
                      f"rep{rep} {record['status']:14s} {record['wall_seconds']:6.1f}s "
                      f"eval={record.get('eval_count')} think_chars={record.get('thinking_chars')}",
                      flush=True)
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
