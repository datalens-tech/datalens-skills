---
name: datalens-html-pages
description: >-
  Use this skill to build or fix a standalone HTML page or report in DataLens. DataLens takes
  a whole self-contained HTML document — often an AI-generated report with tables, charts, and
  a CSV/download button — and renders it in a sandboxed, CSP-locked iframe, so normal web code
  silently breaks. Reach for it when generating such a page from scratch, and when one already
  in DataLens misbehaves: images, fonts, scripts, or CDN libraries blocked or throwing
  Content-Security-Policy errors; fetch/XHR/localStorage failing; charts blank; a download or
  Export button doing nothing; an upload rejected as too large or the wrong encoding; or the
  page needing to match the user's DataLens theme (light/dark) and language (ru/en). Also
  covers which CDNs and hosts are allowed and making the page fully self-contained. Not for
  DataLens chart cells or HTML-markup table columns.
license: Apache-2.0
metadata:
  domain: datalens
---

# DataLens HTML pages

DataLens serves standalone HTML pages — whole documents, usually AI-generated reports — by
storing them in a private bucket and rendering them in a **locked-down sandboxed iframe** from a
**short-TTL presigned URL**, with a **Content-Security-Policy injected as a `<meta>` tag at
upload**. You author a complete `<!DOCTYPE html>` page; scripts run, but only from an allowlist of
CDNs, and most browser APIs are blocked.

> **Not this skill:** HTML *inside a chart* — markup functions, HTML-markup table cells,
> `ChartEditor.generateHtml`. That is a different feature with a strict tag/attribute allowlist
> and **no scripts at all**. This skill is only for standalone HTML *pages*.

## The runtime in one picture

- **Sandboxed iframe:** `sandbox="allow-scripts"`, `allow=""`, `referrerpolicy="no-referrer"`, and
  crucially **no `allow-same-origin`** — the page runs in an opaque origin (parent also sends
  `Cross-Origin-Opener-Policy: same-origin`). Same-origin isolation depends on this; never assume
  same-origin access.
- **Injected CSP** (you do **not** write it — the platform prepends it, idempotently):
  `default-src 'none'` with a small allowlist for `script`/`style`/`font`/`img`/`media`, and
  `connect-src`, `form-action`, `frame-src`, `object-src`, `worker-src`, `base-uri` all `'none'`.
  Full policy in [references/csp-and-sandbox.md](references/csp-and-sandbox.md).
- **Served** from a presigned GET that expires in **10–30 seconds**, after a server-side
  permission check. Theme/language ride along as signed query params.

The net effect: **make the page fully self-contained.** Inline your own CSS/JS (the CSP allows
`'unsafe-inline'`/`'unsafe-eval'`), pull libraries only from allowlisted CDNs, and never rely on
network, storage, or the parent page.

## Authoring rules

**Allowed external resources** (everything else is blocked by the CSP):

| Resource | Allowed from |
|----------|--------------|
| Scripts | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com`, `yastatic.net` (+ inline) |
| Styles | the above **+** `fonts.googleapis.com` (+ inline) |
| Fonts | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `fonts.gstatic.com`, `data:` |
| Images | `yastatic.net`, `data:`, `blob:` |
| Media | `data:`, `blob:` only |

Load Google Fonts the standard way (`<link>` CSS from `fonts.googleapis.com`, font files from
`fonts.gstatic.com`). Mirror off-allowlist libraries (unpkg, plot.ly, d3js.org, jQuery) through
jsdelivr/cdnjs.

**Blocked — do not use** (they throw or silently fail):

- **Storage:** `localStorage`, `sessionStorage`, `indexedDB`, `document.cookie`, Cache API →
  keep all state in memory.
- **Network:** `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `sendBeacon` — `connect-src`
  is `'none'`. **Inline your data into the page** instead of fetching it.
- **Frames/objects/forms:** nested `<iframe>`, `<object>`, `<embed>`, `<form>` submission,
  `<base>`.
- **Workers, popups, dialogs, downloads, camera/geolocation/fullscreen**, and navigating the
  parent frame.

**Theme & language** — read them from the query string:

```js
const theme = new URLSearchParams(location.search).get('theme'); // 'light' | 'dark' | 'system'
const lang  = new URLSearchParams(location.search).get('lang');  // 'ru' | 'en'
```

When designing and generating HTML, try to create a page that supports available themes, languages
and also adaptive: some users will view them via mobile web version of the DataLens.

**Exporting a file** — the download APIs are blocked; hand data to the host instead. The host
verifies `event.source`, applies a MIME allowlist + size cap, sanitizes the filename, and creates
the download:

```js
parent.postMessage({ type: 'export', name: 'report.csv', mime: 'text/csv', data: csvString }, '*');
```

**Encoding & size** (enforced at upload):

- Valid **UTF-8**; declare `<meta charset="utf-8">` within the **first 1024 bytes**. The server
  detects mojibake but never repairs it.
- **Do not wrap the document in markdown code fences** (```` ```html ````) — they prematurely close
  `<head>`.
- Page size **up to ~10 MB**, ideally keep below ~5 MB.

See [references/authoring-constraints.md](references/authoring-constraints.md) for the exhaustive
lists, and [assets/report.template.html](assets/report.template.html) for a compliant starting
point.

## Validate before you upload

Lint the page against the exact CSP allowlist and sandbox constraints — a clean run means nothing
will be blocked or stripped at render:

```bash
python scripts/validate_page.py report.html          # errors + warnings
python scripts/validate_page.py --strict report.html # warnings fail too (CI mode)
cat report.html | python scripts/validate_page.py -   # from stdin
```

It flags off-allowlist resource hosts, blocked APIs (storage/fetch/workers/…), blocked tags,
missing charset, mojibake, wrapping code fences, and oversize pages. Run
`python scripts/validate_page.py --self-test` to check the linter itself.

## Serve & publish

Serving is server-side; know the shape so you author correctly:

- **Presigned GET, 10–30 s TTL**, minted only after a permission check (no TOCTOU gap). Don't
  build flows that assume a long-lived URL.
- Object stored with `Content-Type: text/html; charset=utf-8`, `Content-Disposition: inline`,
  `Cache-Control: no-store`. Upload is server-side JSON-RPC (no presigned PUTs — the server owns
  CSP injection and metadata).
- The iframe carries the sandbox above; the parent sends `COOP: same-origin`.

**Accepted risks to design around** (details in
[references/csp-and-sandbox.md](references/csp-and-sandbox.md)): a URL opened top-level (within its
TTL) loses the iframe sandbox but keeps the injected CSP; a page can self-navigate via
`<meta http-equiv="refresh">`; allowlisted CDNs are not SRI-pinned. Because the frame is
same-origin-isolated and network-less, **do not put viewer data, parameters, or live LLM output
that must stay private into the page** — it is a report, not a trusted app surface.

## Common pitfalls → fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Library never loads / CSP error in console | script/style host off the allowlist | serve it from jsdelivr / cdnjs / tailwind / yastatic |
| Data never appears | code calls `fetch`/XHR | inline the dataset into the page at generation time |
| "localStorage is not available" / throws | storage API in sandbox | keep state in memory |
| Fonts don't render | font host off-allowlist | Google Fonts (`fonts.googleapis.com` CSS + `fonts.gstatic.com` files) or jsdelivr/cdnjs |
| Image is blank | `http://` or off-allowlist host | use `yastatic.net`, `data:`, or `blob:` |
| Download button does nothing | download APIs blocked | use the `parent.postMessage({type:'export'…})` protocol |
| Page renders as plain text / broken head | wrapping markdown code fences | remove the ``` fences |
| Upload rejected | > 10 MB or invalid UTF-8 | shrink assets; ensure UTF-8 + early `<meta charset>` |
