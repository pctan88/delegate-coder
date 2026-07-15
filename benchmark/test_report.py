#!/usr/bin/env python3
"""Deterministic regression test for the frozen v1 JSONL reporter.

The assertions use the reporter's documented display rounding: USD to four
decimal places, percentages to whole numbers, and wall time to whole seconds.
"""
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parent.parent
output = subprocess.check_output(
    [
        "python3",
        str(ROOT / "benchmark/report.py"),
        str(ROOT / "benchmark/raw_data.jsonl"),
        str(ROOT / "benchmark/full_tasks.json"),
    ],
    text=True,
)

assert "bulk-read       6/6      $0.2855    $0.3414    -20%" in output
assert "review          6/6      $0.7035    $0.4881    31%" in output
assert "OVERALL         24/24    $0.4727    $0.4034    15%      96%     92%     42%" in output
assert "243/324" in output
print("benchmark report tests passed")
