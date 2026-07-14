#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("local_contract_report", HERE / "local_contract_report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class LocalContractReportTests(unittest.TestCase):
    def test_arbitrary_conditions_and_rates(self):
        rows = [
            {"condition": "direct", "success": True, "retries": 0, "prompt_eval_duration": 10, "eval_duration": 20, "total_duration": 30, "wall_seconds": 1},
            {"condition": "direct", "success": False, "retries": 1, "prompt_eval_duration": 30, "eval_duration": 40, "total_duration": 70, "wall_seconds": 2},
            {"condition": "contract", "success": True, "retries": 0, "prompt_eval_duration": 50, "eval_duration": 60, "total_duration": 110, "wall_seconds": 3},
        ]
        summary = REPORT.summarize(rows)
        self.assertEqual(summary["direct"]["n"], 2)
        self.assertEqual(summary["direct"]["success_rate"], 0.5)
        self.assertEqual(summary["direct"]["retry_rate"], 0.5)
        output = REPORT.render(rows)
        self.assertIn("direct", output)
        self.assertIn("contract", output)

    def test_fixture_jsonl_is_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "fixture.jsonl"
            path.write_text("\n".join(json.dumps({"condition": condition, "success": True, "retries": 0}) for condition in ("C", "A", "B")))
            rows = REPORT.load(path)
            self.assertEqual(REPORT.render(rows).splitlines()[2].split()[0], "A")
            self.assertEqual(REPORT.render(rows), REPORT.render(REPORT.load(path)))


if __name__ == "__main__":
    unittest.main()
