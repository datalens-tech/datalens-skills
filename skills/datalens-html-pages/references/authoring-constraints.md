# Authoring constraints

Exhaustive rules for a DataLens HTML page. The runtime = opaque-origin sandboxed iframe + injected
CSP ([csp-and-sandbox.md](csp-and-sandbox.md)). Golden rule: **self-contained, network-less,
state-in-memory.**

## Allowed external resources

| Resource | Allowed sources |
|----------|-----------------|
| `<script src>` | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com`, `yastatic.net`, `api-maps.yandex.ru`, `*.api-maps.yandex.ru`, `*.maps.yandex.net`, `suggest-maps.yandex.ru` |
| inline `<script>` | ✅ allowed (`'unsafe-inline'` / `'unsafe-eval'`) |
| `<link rel=stylesheet>` / `<style>` | the CDN hosts above (not the maps hosts) **+** `fonts.googleapis.com`, `blob:`; inline ✅ |
| fonts (`@font-face`, font files) | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `fonts.gstatic.com`, `data:` |
| `<img>` | `yastatic.net`, `api-maps.yandex.ru`, `*.api-maps.yandex.ru`, `*.maps.yandex.net`, `data:`, `blob:` |
| `<audio>` / `<video>` / `<source>` | `data:`, `blob:` only |
| `fetch` / XHR | `api-maps.yandex.ru`, `*.api-maps.yandex.ru`, `*.maps.yandex.net`, `suggest-maps.yandex.ru` only — used by the Maps API internally |

Yandex Maps JS API 2.1 from `api-maps.yandex.ru` is the one external service the page may talk
to. Do not route it through a CDN mirror, and do not use v3 (it needs an API key to load and
workers to render).

Rewrite off-allowlist libraries through an allowed mirror:

| If you reach for… | Load instead from |
|-------------------|-------------------|
| `unpkg.com/<pkg>` | `cdn.jsdelivr.net/npm/<pkg>` |
| `cdn.plot.ly` / `plot.ly` | `cdn.jsdelivr.net` or `cdnjs.cloudflare.com` |
| `d3js.org` | `cdn.jsdelivr.net` or `cdnjs.cloudflare.com` |
| `code.jquery.com` / `ajax.googleapis.com` | `cdn.jsdelivr.net` or `cdnjs.cloudflare.com` |

## Blocked APIs (throw or silently fail — never use)

| Category | Blocked | Do instead |
|----------|---------|------------|
| Storage | `localStorage`, `sessionStorage`, `indexedDB`, `document.cookie`, Cache API | in-memory JS variables |
| Network | `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `navigator.sendBeacon` to any host but Yandex Maps | **inline the data** into the page |
| Workers | `new Worker`, `SharedWorker`, `navigator.serviceWorker` | do work on the main thread |
| Popups/dialogs | `window.open`, `alert`, `confirm`, `prompt` | render UI in the page |
| Navigation / links | navigating the parent (`parent.location`, `top.location`); ordinary `<a href>` link navigation | post `{code:'OPEN_URL', data:{url}}` on click (below) |
| Downloads | `<a download>`, programmatic blob downloads | post `{code:'EXPORT', data:{…}}` (below) |
| Capabilities | `getUserMedia` (camera/mic), `navigator.geolocation`, `requestFullscreen` | — |

## Blocked tags

`<iframe>` (frame-src none), `<object>` / `<embed>` (object-src none), `<base>` (base-uri none),
`<form>` submission (form-action none). SVG is fine; inline `<svg>` needs no external resource.

## Parameters in

Theme and language arrive as signed query params:

```js
const params = new URLSearchParams(location.search);
const theme = params.get('theme'); // 'light' | 'dark' | 'system'
const lang  = params.get('lang');  // 'ru' | 'en'
```

## Files & links out — the parent-message protocol

`parent.postMessage` is the only channel to the host; the host dispatches on the message `code`.

**Export a file** (download APIs are blocked). The host validates the source frame, enforces a MIME
allowlist and size cap, sanitizes the filename, and creates the download:

```js
function exportFile(name, mime, data) {
  parent.postMessage({ code: 'EXPORT', data: { name, mime, data } }, '*');
}
exportFile('report.csv', 'text/csv', csvString);
```

**Open a link** (ordinary navigation is blocked — an `<a href>` does nothing, and `target="_blank"`
only reaches `about:blank`). Attach one delegated listener that turns link clicks into `OPEN_URL`,
gated on being framed:

```js
if (window.parent !== window) {
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[href]');
    if (!a || a.getAttribute('href').startsWith('#')) return; // leave in-page anchors alone
    e.preventDefault();
    parent.postMessage({ code: 'OPEN_URL', data: { url: a.href } }, '*');
  });
}
```

A presigned URL opened top-level within its TTL, or a local preview, has `parent === window`:
nothing answers `OPEN_URL`, so ungated `preventDefault()` cancels navigation.
Gating the listener leaves those links to the browser.

## Encoding & size (upload-time)

- **UTF-8 only.** The server flags mojibake (high `U+FFFD` density) but never repairs it.
- Declare `<meta charset="utf-8">` **within the first 1024 bytes** (the encoding prescan window).
- **No wrapping markdown code fences** (```` ```html … ``` ````) — a closing fence prematurely
  ends `<head>`. Emit raw HTML.
- **Size 5–10 MB.** HTML travels as a plain JSON-RPC string (not base64); the per-method body
  limit is ≈ 10 MB with early `Content-Length` rejection. Keep embedded data/images lean.
- A closing `</head>` is optional — the parser synthesizes nesting — but well-formed markup is
  safer.

## Upload lint checklist (what `validate_page.py` reports)

- external `src`/`href` host outside the CSP allowlist (with jsdelivr/cdnjs rewrite hints)
- storage / network / worker / popup / dialog / capability API usage
- blocked tags and `<a download>`
- `link-navigation` (advisory note): `<a href>` links with no `OPEN_URL` handler detected
- `unguarded-open-url` (advisory note): `OPEN_URL` interception with no recognizable frame check
- CSS `url()` / `@import` and `srcset` hosts off the allowlist
- missing early `<meta charset>`; high `U+FFFD` density
- wrapping markdown code fences
- size over the soft (5 MB) / hard (10 MB) limits

The link notes use page-wide text heuristics; a frame comparison elsewhere can suppress a note
without guarding the listener. Verify link behavior in a browser, both framed and top-level.
