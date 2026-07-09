#!/usr/bin/env python3
"""Grade a generated DataLens HTML page against the mechanical behavior assertions.

`behavior.json` in this directory describes what a good generated page should do. The
assertions marked `"auto": true` there are the ones this script checks — each check id below
matches an assertion id. The `"auto": false` assertions (does the chart actually render, is the
RU/EN copy coherent, …) still need human or LLM judgement.

The safety rules (CSP allowlist, blocked APIs, size/encoding, <a download>) are NOT re-checked
here: this imports the skill's own linter, `validate_page.py`, and derives those checks from its
findings, so the grader can never drift from what DataLens actually enforces. Only the
behavior-specific bits (reads ?theme/?lang, exports via postMessage, responsive) are grepped.

Note: `grade()` runs every check; a given behavior.json case only asserts a subset, so read the
failures against that case's `auto` assertions rather than the overall exit code. `--self-test`
is the exception — the shipped template must satisfy *every* check.

Usage:
    grade_report.py PAGE.html [PAGE.html ...]   # grade generated page(s)
    grade_report.py --self-test                 # grade the shipped template (must pass everything)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL_SCRIPTS = ROOT / "skills" / "datalens-html-pages" / "scripts"
TEMPLATE = ROOT / "skills" / "datalens-html-pages" / "assets" / "report.template.html"

sys.path.insert(0, str(SKILL_SCRIPTS))
import validate_page  # noqa: E402  — the skill's linter is the single source of truth


def _has(pattern: str, text: str) -> bool:
    return re.search(pattern, text) is not None


def grade(path: Path) -> dict[str, tuple[bool, str]]:
    raw = path.read_bytes()
    text = raw.decode("utf-8", "replace")
    head = raw[:1024].lower()

    findings = validate_page.lint_bytes(raw)
    codes = {f.code for f in findings}
    # `--strict` fails on errors and warnings; advisory 'note' findings never block.
    blocking = [f for f in findings if f.severity in ("error", "warning")]

    checks: dict[str, tuple[bool, str]] = {}
    checks["self-contained"] = (
        (b"<!doctype html" in head or b"<html" in head) and "charset" not in codes,
        "HTML document with a <meta charset> in the first bytes",
    )
    checks["passes-linter"] = (
        not blocking,
        "validate_page.py --strict is clean" if not blocking
        else f"{len(blocking)} linter finding(s): " + ", ".join(sorted(f.code for f in blocking)),
    )
    checks["no-network"] = (
        "blocked-network" not in codes,
        "no fetch / XHR / WebSocket / EventSource / sendBeacon",
    )
    checks["no-storage"] = (
        "blocked-storage" not in codes,
        "no localStorage / sessionStorage / indexedDB / cookie / Cache API",
    )
    checks["export-postmessage"] = (
        _has(r"parent\s*\.\s*postMessage", text) and "blocked-download" not in codes,
        "export uses parent.postMessage and there is no <a download>",
    )
    checks["theme-from-query"] = (
        _has(r"get\(\s*['\"]theme['\"]", text),
        "reads a ?theme query parameter",
    )
    checks["lang-from-query"] = (
        _has(r"get\(\s*['\"]lang['\"]", text),
        "reads a ?lang query parameter",
    )
    checks["responsive"] = (
        _has(r"""name=['"]viewport['"]""", text),
        "declares a <meta name=viewport>",
    )
    return checks


def report(path: Path, checks: dict[str, tuple[bool, str]]) -> int:
    print(f"\n{path}")
    failed = 0
    for cid, (passed, evidence) in checks.items():
        mark = "PASS" if passed else "FAIL"
        if not passed:
            failed += 1
        print(f"  [{mark}] {cid}: {evidence}")
    return failed


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        print("usage: grade_report.py [PAGE.html ... | --self-test]", file=sys.stderr)
        return 2

    if "--self-test" in args:
        # The shipped template is the exemplar: it must satisfy every mechanical check.
        checks = grade(TEMPLATE)
        failed = report(TEMPLATE, checks)
        print(f"\nself-test: {'PASS' if failed == 0 else f'FAIL ({failed} check(s))'}")
        return 1 if failed else 0

    status = 0
    for a in args:
        p = Path(a)
        if not p.is_file():
            print(f"{a}: not a file", file=sys.stderr)
            status = 1
            continue
        if report(p, grade(p)):
            status = 1
    print("\nNote: not every check applies to every prompt — read the failures against the "
          "`auto` assertions listed for that case in behavior.json.")
    return status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
