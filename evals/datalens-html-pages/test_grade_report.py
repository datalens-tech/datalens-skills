import json
import tempfile
import unittest
from pathlib import Path

import grade_report


class FrameGuardGradingTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.page = Path(directory.name) / "report.html"

    def grade_html(self, body):
        self.page.write_text('<!DOCTYPE html><meta charset="utf-8">' + body, encoding="utf-8")
        return grade_report.grade(self.page)

    def test_automatic_assertions_match_grader(self):
        behavior = json.loads(Path(__file__).with_name("behavior.json").read_text(encoding="utf-8"))
        assertions = [assertion for case in behavior["evals"] for assertion in case["assertions"]]
        automatic = {assertion["id"] for assertion in assertions if assertion["auto"]}
        self.assertEqual(automatic, set(grade_report.grade(grade_report.TEMPLATE)))
        unframed = next(assertion for assertion in assertions if assertion["id"] == "links-work-unframed")
        self.assertFalse(unframed["auto"])

    def test_advisory_false_positives_do_not_fail_linter_check(self):
        cases = {
            "button-and-keydown": '''
                <button onclick="parent.postMessage({code:'OPEN_URL',data:{url:'https://example.com'}},'*')">Open</button>
                <script>document.addEventListener('keydown', e => e.preventDefault());</script>''',
            "query-gated-listener": '''
                <script>if(new URLSearchParams(location.search).has('theme')) {
                  document.addEventListener('click', e => {
                    e.preventDefault(); parent.postMessage({code:'OPEN_URL'}, '*');
                  });
                }</script>''',
        }
        for name, body in cases.items():
            with self.subTest(name=name):
                checks = self.grade_html(body)
                findings = grade_report.validate_page.lint_bytes(self.page.read_bytes())
                self.assertEqual([("note", "unguarded-open-url")],
                                 [(f.severity, f.code) for f in findings])
                self.assertTrue(checks["passes-linter"][0])
                self.assertNotIn("links-work-unframed", checks)

    def test_comment_and_form_still_report_the_blocked_form(self):
        checks = self.grade_html('<!-- OPEN_URL --><form onsubmit="event.preventDefault()"></form>')
        self.assertFalse(checks["passes-linter"][0])
        self.assertEqual("1 linter finding(s): blocked-tag", checks["passes-linter"][1])
        self.assertNotIn("links-work-unframed", checks)

    def test_frame_comparison_does_not_prove_control_flow(self):
        interception = "document.addEventListener('click', e => {e.preventDefault(); parent.postMessage({code:'OPEN_URL'}, '*');});"
        cases = {
            "inverted-guard": "if(window.parent === window) {" + interception + "}",
            "unrelated-comparison": "const framed = window.top !== window; " + interception,
        }
        for name, script in cases.items():
            with self.subTest(name=name):
                checks = self.grade_html("<script>" + script + "</script>")
                self.assertEqual([], grade_report.validate_page.lint_bytes(self.page.read_bytes()))
                self.assertNotIn("links-work-unframed", checks)


if __name__ == "__main__":
    unittest.main()
