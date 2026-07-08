#!/usr/bin/env python3
"""Lint a standalone HTML page against the DataLens "HTML pages" runtime.

DataLens renders uploaded HTML pages (typically AI-generated reports) inside a
**sandboxed iframe** (`sandbox="allow-scripts"`, no `allow-same-origin`, opaque origin)
served from a short-TTL presigned URL, with a strict **Content-Security-Policy injected as
a `<meta>` tag at upload**. Scripts run, but only from an allowlist of CDNs, and most
browser APIs (storage, network, workers, popups, downloads, parent navigation) are blocked
by the sandbox + CSP.

This linter catches, before upload, the things that will silently fail at render:
resources from hosts the CSP will block, blocked APIs that throw, blocked tags, and the
upload-time encoding/size rules. It mirrors the constraints in the HTML-pages ADR (see
references/csp-and-sandbox.md and references/authoring-constraints.md).

Usage:
    validate_page.py FILE [FILE ...]   # lint files ('-' = stdin)
    validate_page.py --strict ...      # treat warnings as failures (used by CI on the template)
    validate_page.py --self-test       # run the built-in test battery

Exit code 0 = clean (no errors; no warnings under --strict), 1 = otherwise. Standard
library only.
"""

from __future__ import annotations

import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

# --- CSP allowlist (from the injected policy in the ADR) ---------------------------------

SCRIPT_HOSTS = {"cdn.jsdelivr.net", "cdnjs.cloudflare.com", "cdn.tailwindcss.com", "yastatic.net"}
STYLE_HOSTS = SCRIPT_HOSTS | {"fonts.googleapis.com"}
FONT_HOSTS = {"cdn.jsdelivr.net", "cdnjs.cloudflare.com", "fonts.gstatic.com"}
LINK_HOSTS = STYLE_HOSTS | FONT_HOSTS  # stylesheets, preconnect, preload, icons
IMG_HOSTS = {"yastatic.net"}           # plus data: / blob:
IMG_SCHEMES = {"data", "blob"}
MEDIA_SCHEMES = {"data", "blob"}       # media-src data: blob:

# Common libraries hosted off-allowlist → suggest the mirror that IS allowed.
REWRITE_HINTS = {
    "unpkg.com": "mirror via cdn.jsdelivr.net (e.g. jsdelivr.net/npm/<pkg>)",
    "cdn.plot.ly": "load plotly from cdn.jsdelivr.net or cdnjs.cloudflare.com",
    "plot.ly": "load plotly from cdn.jsdelivr.net or cdnjs.cloudflare.com",
    "d3js.org": "load d3 from cdn.jsdelivr.net or cdnjs.cloudflare.com",
    "code.jquery.com": "load jQuery from cdn.jsdelivr.net or cdnjs.cloudflare.com",
    "ajax.googleapis.com": "load the library from cdn.jsdelivr.net or cdnjs.cloudflare.com",
}

# Tags the CSP/sandbox make non-functional (frame-src/object-src/base-uri 'none', form-action 'none').
BLOCKED_TAGS = {
    "iframe": "nested frames are blocked (frame-src 'none')",
    "object": "objects are blocked (object-src 'none')",
    "embed": "embeds are blocked (object-src 'none')",
    "base": "<base> is blocked (base-uri 'none')",
    "form": "form submission is blocked (form-action 'none')",
}

# JS/API usage that throws or is blocked at runtime. All warnings. `parent.postMessage`
# is deliberately NOT here — it is the sanctioned export channel.
API_PATTERNS = [
    (re.compile(r"\b(localStorage|sessionStorage|indexedDB)\b"),
     "blocked-storage", "storage API is blocked (throws in this sandbox); keep state in memory"),
    (re.compile(r"document\s*\.\s*cookie"),
     "blocked-storage", "document.cookie is blocked in this sandbox"),
    (re.compile(r"\bcaches\s*\."),
     "blocked-storage", "Cache API is blocked in this sandbox"),
    (re.compile(r"\bfetch\s*\("),
     "blocked-network", "fetch() is blocked (connect-src 'none'); inline the data instead"),
    (re.compile(r"\bXMLHttpRequest\b"),
     "blocked-network", "XMLHttpRequest is blocked (connect-src 'none')"),
    (re.compile(r"\b(WebSocket|EventSource)\b"),
     "blocked-network", "live connections are blocked (connect-src 'none')"),
    (re.compile(r"sendBeacon"),
     "blocked-network", "navigator.sendBeacon is blocked (connect-src 'none')"),
    (re.compile(r"\bnew\s+(?:Shared)?Worker\s*\("),
     "blocked-worker", "workers are blocked (worker-src 'none')"),
    (re.compile(r"serviceWorker"),
     "blocked-worker", "service workers are blocked in this sandbox"),
    (re.compile(r"\b(?:alert|confirm|prompt)\s*\("),
     "blocked-dialog", "dialogs (alert/confirm/prompt) are blocked in this sandbox"),
    (re.compile(r"\bwindow\s*\.\s*open\s*\("),
     "blocked-popup", "window.open / popups are blocked in this sandbox"),
    (re.compile(r"\b(?:parent|top)\s*\.\s*location\b"),
     "blocked-parent-nav", "the frame cannot navigate its parent"),
    (re.compile(r"getUserMedia|navigator\s*\.\s*geolocation|requestFullscreen"),
     "blocked-capability", "camera / geolocation / fullscreen are blocked in this sandbox"),
]

# Size limits (bytes) from the ADR: 5–10 MB enforced at upload.
SOFT_SIZE = 5 * 1024 * 1024
HARD_SIZE = 10 * 1024 * 1024
CHARSET_WINDOW = 1024  # charset must appear within the first 1024 bytes


class Finding:
    def __init__(self, severity, code, line, message):
        self.severity = severity  # 'error' | 'warning'
        self.code = code
        self.line = line
        self.message = message

    def format(self, source):
        loc = f"{source}:{self.line}" if self.line else source
        return f"{loc}: {self.severity}: {self.code}: {self.message}"


def url_scheme_host(value):
    """Return (scheme, host) for a URL-ish attribute value. scheme is 'relative' when there is
    no explicit scheme, 'data'/'blob' for those pseudo-schemes, or a real scheme ('https', …).
    A protocol-relative URL (//host/…) resolves to the page's https origin, so it is reported
    as an https load against `host` rather than treated as a scheme-less relative path."""
    v = (value or "").strip()
    low = v.lower()
    if low.startswith("data:"):
        return ("data", None)
    if low.startswith("blob:"):
        return ("blob", None)
    if low.startswith("//"):
        return ("https", (urlsplit(v).hostname or "").lower())
    if low.startswith(("#", "/", "./", "../")) or (":" not in low.split("/")[0]):
        return ("relative", None)
    parts = urlsplit(v)
    return (parts.scheme.lower(), (parts.hostname or "").lower())


class PageLinter(HTMLParser):
    # CSS url()/@import can pull resources too; check their hosts against the union of the
    # directives CSS can trigger (style/font/img). data:/blob: and #fragments are skipped.
    CSS_URL_HOSTS = STYLE_HOSTS | FONT_HOSTS | IMG_HOSTS
    _CSS_URL = re.compile(r"url\(\s*['\"]?([^'\")]+)['\"]?\s*\)", re.I)
    _CSS_IMPORT = re.compile(r"@import\s+['\"]([^'\"]+)['\"]", re.I)

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.findings = []
        self.in_style = 0

    def _add(self, severity, code, message):
        line, _ = self.getpos()
        self.findings.append(Finding(severity, code, line, message))

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        attr = {k.lower(): v for k, v in attrs}

        if tag in BLOCKED_TAGS:
            self._add("warning", "blocked-tag", f"<{tag}>: {BLOCKED_TAGS[tag]}")
            return

        if tag == "a" and "download" in attr:
            self._add("warning", "blocked-download",
                      "downloads are blocked; deliver files via the parent.postMessage export protocol")

        if tag == "script" and attr.get("src"):
            self._check_host("script", attr["src"], SCRIPT_HOSTS)
        elif tag == "link" and attr.get("href"):
            self._check_host("link", attr["href"], LINK_HOSTS)
        elif tag == "img" and attr.get("src"):
            self._check_host("img", attr["src"], IMG_HOSTS, schemes=IMG_SCHEMES)
        elif tag in ("audio", "video", "source") and attr.get("src"):
            self._check_host(tag, attr["src"], set(), schemes=MEDIA_SCHEMES)

        if tag == "style":
            self.in_style += 1

        # srcset (img / picture <source>) is "url [descriptor]" candidates joined by commas.
        if tag in ("img", "source") and attr.get("srcset"):
            for candidate in attr["srcset"].split(","):
                token = candidate.strip().split(" ")[0].strip()
                if token:
                    self._check_host(tag, token, IMG_HOSTS, schemes=IMG_SCHEMES)

        # Inline style="" can reference resources via url(...).
        if attr.get("style"):
            self._check_css(attr["style"])

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag.lower() == "style" and self.in_style:
            self.in_style -= 1

    def handle_data(self, data):
        if self.in_style:
            self._check_css(data)

    def _check_css(self, css):
        refs = [m.group(1) for m in self._CSS_URL.finditer(css)]
        refs += [m.group(1) for m in self._CSS_IMPORT.finditer(css)]
        for ref in refs:
            r = ref.strip()
            low = r.lower()
            if not r or low.startswith(("#", "data:", "blob:")):
                continue  # same-doc fragment or inline data — not a host fetch
            _, host = url_scheme_host(r)
            if host and host not in self.CSS_URL_HOSTS:
                hint = REWRITE_HINTS.get(host)
                self._add("warning", "csp-css",
                          f"CSS loads from {host}, which the CSP blocks"
                          + (f" — {hint}" if hint else ""))

    def _check_host(self, kind, value, allowed_hosts, schemes=frozenset()):
        scheme, host = url_scheme_host(value)
        if scheme in ("data", "blob"):
            # data:/blob: are allowed only where the directive permits them (img/media), never
            # for script-src / style-src — those list https CDNs only.
            if scheme not in schemes:
                self._add("warning", "csp-scheme",
                          f"<{kind}> uses a {scheme}: URL, which the CSP {kind}-src does not allow")
            return
        if scheme == "relative" or host is None:
            self._add("warning", "csp-host",
                      f"<{kind}> uses a non-allowlisted resource ({value!r}); "
                      f"the CSP only permits specific CDNs")
            return
        if host in allowed_hosts:
            return
        if host in REWRITE_HINTS:
            self._add("warning", "csp-rewrite",
                      f"<{kind}> loads from {host}, which the CSP blocks — {REWRITE_HINTS[host]}")
        else:
            allowed = ", ".join(sorted(allowed_hosts)) or "data:/blob: only"
            self._add("warning", "csp-host",
                      f"<{kind}> loads from {host}, which the CSP blocks (allowed: {allowed})")


def scan_apis(text):
    findings = []
    for pattern, code, message in API_PATTERNS:
        for m in pattern.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            findings.append(Finding("warning", code, line, message))
            break  # one finding per pattern is enough signal
    return findings


def lint_bytes(raw):
    findings = []

    # Size (ADR: 5–10 MB enforced at upload).
    size = len(raw)
    if size > HARD_SIZE:
        findings.append(Finding("error", "size", 0,
                                f"{size} bytes exceeds the 10 MB hard limit"))
    elif size > SOFT_SIZE:
        findings.append(Finding("warning", "size", 0,
                                f"{size} bytes is over the 5 MB soft limit (10 MB hard cap)"))

    # Charset must be declared within the first 1024 bytes (encoding prescan window).
    if b"charset" not in raw[:CHARSET_WINDOW].lower():
        findings.append(Finding("warning", "charset", 0,
                                "declare <meta charset=\"utf-8\"> within the first 1024 bytes"))

    # Content must be valid UTF-8; detect but never repair.
    try:
        text = raw.decode("utf-8")
        strict_ok = True
    except UnicodeDecodeError as err:
        findings.append(Finding("error", "encoding", 0, f"not valid UTF-8: {err}"))
        text = raw.decode("utf-8", "replace")
        strict_ok = False

    if strict_ok:
        bad = text.count("�")
        if bad and bad / max(len(text), 1) > 0.0005:
            findings.append(Finding("warning", "mojibake", 0,
                                    f"high U+FFFD density ({bad} chars) — likely an encoding mismatch"))

    # Wrapping markdown code fences prematurely close <head>; strip them before upload.
    if text.lstrip().startswith("```"):
        findings.append(Finding("error", "code-fence", 1,
                                "strip the wrapping markdown code fence (``` ) — it breaks HTML parsing"))

    linter = PageLinter()
    linter.feed(text)
    linter.close()
    findings.extend(linter.findings)
    findings.extend(scan_apis(text))
    return findings


def lint_source(source, raw, strict):
    findings = lint_bytes(raw)
    findings.sort(key=lambda f: (f.line, 0 if f.severity == "error" else 1))
    for f in findings:
        print(f.format(source))
    errors = sum(1 for f in findings if f.severity == "error")
    warnings = sum(1 for f in findings if f.severity == "warning")
    if findings:
        print(f"{source}: {errors} error(s), {warnings} warning(s)")
    if errors or (strict and warnings):
        return 1
    return 0


# --- Self-test battery ------------------------------------------------------------------

_GOOD = b"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js"></script>
<link rel="preconnect" href="https://fonts.gstatic.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">
</head><body>
<div id="app"></div>
<script>
  const theme = new URLSearchParams(location.search).get('theme') || 'light';
  document.getElementById('app').textContent = 'theme: ' + theme;
  function exportCsv(data){ parent.postMessage({type:'export', name:'r.csv', mime:'text/csv', data}, '*'); }
</script>
</body></html>
"""

_BAD_CASES = [
    (b'```html\n<!DOCTYPE html><meta charset=utf-8><body>x</body>', "code-fence", "error"),
    (b'<!DOCTYPE html><meta charset=utf-8><script src="https://unpkg.com/x"></script>', "csp-rewrite", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><script src="https://evil.example/x.js"></script>', "csp-host", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><iframe src="https://x"></iframe>', "blocked-tag", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><form action="/x"></form>', "blocked-tag", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><script>localStorage.setItem("a",1)</script>', "blocked-storage", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><script>fetch("/x")</script>', "blocked-network", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><script>alert(1)</script>', "blocked-dialog", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><a download href="#">x</a>', "blocked-download", "warning"),
    (b'<!DOCTYPE html><meta charset=utf-8><img src="data:image/png;base64,AA">ok', None, "clean"),  # data: img is allowed
    (b'<!DOCTYPE html><meta charset=utf-8><script src="//cdn.jsdelivr.net/npm/x"></script>', None, "clean"),  # protocol-relative to an allowlisted CDN
    (b'<!DOCTYPE html><meta charset=utf-8><script src="//unpkg.com/x"></script>', "csp-rewrite", "warning"),  # protocol-relative, off-allowlist
    (b'<!DOCTYPE html><meta charset=utf-8><script src="data:text/javascript,1"></script>', "csp-scheme", "warning"),  # data: not allowed for script-src
    (b'<!DOCTYPE html><meta charset=utf-8><img srcset="https://evil.example/a.png 1x">', "csp-host", "warning"),  # srcset is host-checked
    (b'<!DOCTYPE html><meta charset=utf-8><style>@import url("https://evil.example/x.css");</style>', "csp-css", "warning"),  # CSS refs are host-checked
    (b'<!DOCTYPE html><body>no encoding declared</body>', "charset", "warning"),
]


def self_test():
    failures = 0

    good = lint_bytes(_GOOD)
    if good:
        failures += 1
        print("FAIL (expected clean template):")
        for f in good:
            print("    ->", f.format("<good>"))

    for raw, want_code, kind in _BAD_CASES:
        findings = lint_bytes(raw)
        codes = {f.code for f in findings}
        if kind == "clean":
            # Should not raise any CSP host/scheme/css warning.
            bad = codes & {"csp-host", "csp-scheme", "csp-css", "csp-rewrite"}
            if bad:
                failures += 1
                print(f"FAIL (expected no CSP warning) for {raw[:48]!r}: {sorted(bad)}")
        elif want_code not in codes:
            failures += 1
            print(f"FAIL (expected {want_code}) for {raw[:48]!r}: got {sorted(codes)}")

    total = 1 + len(_BAD_CASES)
    if failures:
        print(f"self-test: {failures}/{total} case(s) failed")
        return 1
    print(f"self-test: all {total} cases passed")
    return 0


def main(argv):
    args = [a for a in argv[1:] if a != "--strict"]
    strict = "--strict" in argv
    if "--self-test" in args:
        return self_test()
    if not args:
        print("usage: validate_page.py [--strict] [FILE ... | - | --self-test]", file=sys.stderr)
        return 2

    status = 0
    for path in args:
        if path == "-":
            status |= lint_source("<stdin>", sys.stdin.buffer.read(), strict)
        else:
            try:
                with open(path, "rb") as fh:
                    status |= lint_source(path, fh.read(), strict)
            except OSError as err:
                print(f"{path}: cannot read: {err}", file=sys.stderr)
                status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
