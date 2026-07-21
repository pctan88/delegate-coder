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
            {"condition": "direct", "success": True, "retries": 0, "prompt_eval_duration": 10, "eval_duration": 20, "total_duration": 30, "wall_seconds": 1, "status": "PASS"},
            {"condition": "direct", "success": False, "retries": 1, "prompt_eval_duration": 30, "eval_duration": 40, "total_duration": 70, "wall_seconds": 2, "status": "FAIL"},
            {"condition": "contract", "success": True, "retries": 0, "prompt_eval_duration": 50, "eval_duration": 60, "total_duration": 110, "wall_seconds": 3, "status": "PASS"},
        ]
        summary = REPORT.summarize(rows)
        self.assertIn("unlabeled", summary)
        self.assertEqual(summary["unlabeled"]["direct"]["n"], 2)
        self.assertEqual(summary["unlabeled"]["direct"]["success_rate"], 0.5)
        self.assertEqual(summary["unlabeled"]["direct"]["retry_rate"], 0.5)
        self.assertEqual(summary["unlabeled"]["direct"]["status_counts"], {"PASS": 1, "FAIL": 1})
        output = REPORT.render(rows)
        self.assertIn("Label: unlabeled", output)
        self.assertIn("direct", output)
        self.assertIn("contract", output)
        self.assertIn("FAIL: 1, PASS: 1", output)

    def test_per_task_label_grouping_and_status_breakdown(self):
        rows = [
            {"label": "shape-a-mirror", "condition": "contract", "success": True, "status": "PASS"},
            {"label": "shape-a-mirror", "condition": "contract", "success": True, "status": "PASS"},
            {"label": "shape-c-regex", "condition": "contract", "success": False, "status": "PREFLIGHT_FAIL"},
            {"label": "shape-c-regex", "condition": "contract", "success": False, "status": "PREFLIGHT_FAIL"},
        ]
        summary = REPORT.summarize(rows)
        self.assertEqual(summary["shape-a-mirror"]["contract"]["status_counts"], {"PASS": 2})
        self.assertEqual(summary["shape-c-regex"]["contract"]["status_counts"], {"PREFLIGHT_FAIL": 2})
        output = REPORT.render(rows)
        self.assertIn("Label: shape-a-mirror", output)
        self.assertIn("Label: shape-c-regex", output)
        self.assertIn("PREFLIGHT_FAIL: 2", output)

    def test_fixture_jsonl_is_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "fixture.jsonl"
            path.write_text("\n".join(json.dumps({"label": "test-label", "condition": condition, "success": True, "retries": 0, "status": "PASS"}) for condition in ("C", "A", "B")))
            rows = REPORT.load(path)
            lines = REPORT.render(rows).splitlines()
            self.assertIn("Label: test-label", lines[0])
            self.assertEqual(lines[3].split()[0], "A")
            self.assertEqual(REPORT.render(rows), REPORT.render(REPORT.load(path)))


if __name__ == "__main__":
    unittest.main()
