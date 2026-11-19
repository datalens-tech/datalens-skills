import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import grade_routing
from grade_routing import grade, load_cases, prepare


class RoutingGraderTests(unittest.TestCase):
    def setUp(self):
        self.cases = [
            {"id": "positive", "should_trigger": True, "should_load_sdk": True},
            {"id": "negative", "should_trigger": False, "should_load_sdk": False},
        ]

    def decisions(self, positive=True, negative=False):
        return [
            {"id": "positive", "should_trigger": positive,
             "should_load_sdk": True, "reason": "Decision A"},
            {"id": "negative", "should_trigger": negative,
             "should_load_sdk": False, "reason": "Decision B"},
        ]

    def test_full_match(self):
        result = grade(self.cases, self.decisions())
        self.assertEqual((result["passed"], result["tp"], result["tn"]), (2, 1, 1))

    def test_false_positives_and_negatives_are_failures(self):
        result = grade(self.cases, self.decisions(False, True))
        self.assertEqual((result["passed"], result["fp"], result["fn"]), (0, 1, 1))

    def test_missing_or_extra_predictions_are_rejected(self):
        for decisions in [self.decisions()[:1], self.decisions() + [
            {"id": "extra", "should_trigger": False,
             "should_load_sdk": False, "reason": "Unknown case"}
        ]]:
            with self.subTest(decisions=decisions), self.assertRaises(ValueError):
                grade(self.cases, decisions)

    def test_duplicate_predictions_are_rejected(self):
        with self.assertRaises(ValueError):
            grade(self.cases, self.decisions() + self.decisions()[:1])

    def test_truthy_strings_are_rejected(self):
        with self.assertRaises(ValueError):
            grade(self.cases, self.decisions("false", False))

    def test_empty_reasons_are_rejected(self):
        decisions = self.decisions()
        decisions[0]["reason"] = ""
        with self.assertRaises(ValueError):
            grade(self.cases, decisions)

    def test_case_set_has_valid_scope_coverage(self):
        self.assertTrue(load_cases())

    def test_exclusive_selection_fails_joint_sdk_case(self):
        decisions = self.decisions()
        decisions[0]["should_load_sdk"] = False
        result = grade(self.cases, decisions)
        self.assertEqual((result["tp"], result["tn"], result["passed"]), (1, 1, 1))
        self.assertEqual(result["sdk"]["fn"], 1)

    def test_sdk_only_bi_case_is_supported(self):
        cases = [{"id": "bi", "should_trigger": False, "should_load_sdk": True}]
        decisions = [{"id": "bi", "should_trigger": False,
                      "should_load_sdk": True, "reason": "BI automation"}]
        self.assertEqual(grade(cases, decisions)["passed"], 1)
        decisions[0]["should_trigger"] = True
        self.assertEqual(grade(cases, decisions)["fp"], 1)

    def test_unrequested_sdk_is_a_false_positive(self):
        decisions = self.decisions()
        decisions[1]["should_load_sdk"] = True
        result = grade(self.cases, decisions)
        self.assertEqual((result["passed"], result["sdk"]["fp"]), (1, 1))

    def test_missing_or_non_boolean_sdk_decisions_are_rejected(self):
        for value in (None, "false", 1):
            decisions = self.decisions()
            decisions[0]["should_load_sdk"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                grade(self.cases, decisions)
        decisions = self.decisions()
        del decisions[0]["should_load_sdk"]
        with self.assertRaises(ValueError):
            grade(self.cases, decisions)

    def test_sdk_expectations_are_optional_for_legacy_cases(self):
        cases = [{"id": "positive", "should_trigger": True}]
        result = grade(cases, self.decisions()[:1])
        self.assertEqual((result["passed"], result["sdk"]["total"]), (1, 0))

    def test_prepare_retains_context_without_expected_labels(self):
        cases = load_cases()
        for stage in ("catalog", "router"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as tmp:
                manifest = prepare(stage, Path(tmp))
                target = Path(tmp) / f"{stage}-input.json"
                payload = json.loads(target.read_text())
                self.assertEqual(len(payload["requests"]), len(cases))
                for original, request in zip(cases, payload["requests"]):
                    self.assertEqual(request["id"], original["id"])
                    self.assertEqual(request["query"], original["query"])
                    self.assertEqual(request.get("context"), original.get("context"))
                    self.assertLessEqual(set(request), {"id", "query", "context"})
                self.assertEqual(manifest["input_sha256"],
                                 hashlib.sha256(target.read_bytes()).hexdigest())
                for source, digest in manifest["source_sha256"].items():
                    self.assertEqual(digest, hashlib.sha256(
                        (grade_routing.ROOT / source).read_bytes()).hexdigest())

    def test_case_set_covers_new_boundaries(self):
        cases = load_cases()
        self.assertTrue(any(c["should_trigger"] and c.get("context") for c in cases))
        self.assertTrue(any(c["should_trigger"] and any(
            "\u0400" <= char <= "\u04ff" for char in c["query"]
        ) for c in cases))
        for component in ("trino", "airflow"):
            self.assertTrue(any(
                not c["should_trigger"] and c["scope"] == "bi"
                and component in (c.get("context", "") + c["query"]).lower()
                for c in cases
            ))
        for platform in (True, False):
            self.assertTrue(any(c["should_trigger"] == platform
                                and c.get("should_load_sdk") is True for c in cases))

    def test_prepare_supports_import_from_relative_path(self):
        relative = Path(grade_routing.__file__).resolve().relative_to(Path.cwd())
        spec = importlib.util.spec_from_file_location("relative_grader", str(relative))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            manifest = module.prepare("router", Path(tmp))
        self.assertIn("evals/datalens-platform/grade_routing.py", manifest["source_sha256"])

    def test_invalid_context_and_sdk_expectation_are_rejected(self):
        for field, value in (("context", ""), ("context", []),
                             ("should_load_sdk", "true")):
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as tmp:
                cases = load_cases()
                cases[0][field] = value
                path = Path(tmp) / "cases.json"
                path.write_text(json.dumps(cases))
                with patch.object(grade_routing, "CASES", path), self.assertRaises(ValueError):
                    load_cases()

    def test_cli_fails_when_only_joint_sdk_selection_is_wrong(self):
        # Synthetic decisions exercise the grader; these are not model eval results.
        cases = load_cases()
        decisions = [dict(id=c["id"], should_trigger=c["should_trigger"],
                          should_load_sdk=c.get("should_load_sdk", False),
                          reason="Unit-test fixture") for c in cases]
        joint = next(c for c in cases if c["should_trigger"] and c.get("should_load_sdk"))
        next(d for d in decisions if d["id"] == joint["id"])["should_load_sdk"] = False
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "synthetic-decisions.json"
            path.write_text(json.dumps(decisions))
            result = subprocess.run(
                [sys.executable, grade_routing.__file__, "--predictions", str(path)],
                text=True, capture_output=True,
            )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["sdk"]["fn"], 1)


if __name__ == "__main__":
    unittest.main()
