#!/usr/bin/env python3
"""Report additive local-Qwen benchmark JSONL without touching the frozen v1 data."""
from collections import defaultdict
import json
import pathlib
import statistics
import sys

METRICS = (
    "prompt_eval_duration",
    "eval_duration",
    "total_duration",
    "wall_seconds",
)


def load(path):
    source = pathlib.Path(path)
    files = [source] if source.is_file() else sorted(source.glob("*.jsonl"))
    rows = []
    for file in files:
        for line_number, line in enumerate(file.read_text().splitlines(), 1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict) or not isinstance(value.get("condition"), str):
                raise ValueError(f"{file}:{line_number}: condition is required")
            rows.append(value)
    return rows


def summarize(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["condition"]].append(row)
    result = {}
    for condition, values in grouped.items():
        def avg(key):
            numbers = [float(item[key]) for item in values if item.get(key) is not None]
            return statistics.mean(numbers) if numbers else None
        result[condition] = {
            "n": len(values),
            "success_rate": statistics.mean(bool(item.get("success")) for item in values),
            "retry_rate": statistics.mean((int(item.get("retries", item.get("retry_count", 0))) > 0) for item in values),
            **{key: avg(key) for key in METRICS},
        }
    return result


def render(rows):
    summary = summarize(rows)
    lines = ["Condition  n  Success  Retry  Prompt-eval(ns)  Generation(ns)  Ollama-total(ns)  E2E(s)"]
    lines.append("-" * 86)
    for condition in sorted(summary):
        item = summary[condition]
        fmt = lambda value: "n/a" if value is None else f"{value:.1f}"
        lines.append(
            f"{condition:<10} {item['n']:<2} {item['success_rate'] * 100:>6.0f}%"
            f" {item['retry_rate'] * 100:>5.0f}% {fmt(item['prompt_eval_duration']):>16}"
            f" {fmt(item['eval_duration']):>16} {fmt(item['total_duration']):>17}"
            f" {fmt(item['wall_seconds']):>7}"
        )
    return "\n".join(lines)


def main(argv=None):
    argv = argv or sys.argv[1:]
    if not argv:
        raise SystemExit("usage: local_contract_report.py JSONL_OR_DIRECTORY")
    rows = load(argv[0])
    if not rows:
        raise SystemExit("no benchmark rows found")
    print(render(rows))


if __name__ == "__main__":
    main()
