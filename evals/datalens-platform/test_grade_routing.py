import unittest

from grade_routing import grade, load_cases


class RoutingGraderTests(unittest.TestCase):
    def setUp(self):
        self.cases = [
            {"id": "positive", "should_trigger": True},
            {"id": "negative", "should_trigger": False},
        ]

    def decisions(self, positive=True, negative=False):
        return [
            {"id": "positive", "should_trigger": positive, "reason": "Decision A"},
            {"id": "negative", "should_trigger": negative, "reason": "Decision B"},
        ]

    def test_full_match(self):
        result = grade(self.cases, self.decisions())
        self.assertEqual((result["passed"], result["tp"], result["tn"]), (2, 1, 1))

    def test_false_positives_and_negatives_are_failures(self):
        result = grade(self.cases, self.decisions(False, True))
        self.assertEqual((result["passed"], result["fp"], result["fn"]), (0, 1, 1))

    def test_missing_or_extra_predictions_are_rejected(self):
        for decisions in [self.decisions()[:1], self.decisions() + [
            {"id": "extra", "should_trigger": False, "reason": "Unknown case"}
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


if __name__ == "__main__":
    unittest.main()
