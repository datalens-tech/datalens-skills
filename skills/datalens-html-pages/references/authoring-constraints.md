# Authoring constraints

Exhaustive rules for a DataLens HTML page. The runtime = opaque-origin sandboxed iframe + injected
CSP ([csp-and-sandbox.md](csp-and-sandbox.md)). Golden rule: **self-contained, network-less,
state-in-memory.**

## Allowed external resources

| Resource | Allowed sources |
|----------|-----------------|
| `<script src>` | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com`, `yastatic.net` |
| inline `<script>` | ✅ allowed (`'unsafe-inline'` / `'unsafe-eval'`) |
| `<link rel=stylesheet>` / `<style>` | script hosts above **+** `fonts.googleapis.com`; inline ✅ |
| fonts (`@font-face`, font files) | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `fonts.gstatic.com`, `data:` |
| `<img>` | `yastatic.net`, `data:`, `blob:` |
| `<audio>` / `<video>` / `<source>` | `data:`, `blob:` only |

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
| Network | `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `navigator.sendBeacon` | **inline the data** into the page |
| Workers | `new Worker`, `SharedWorker`, `navigator.serviceWorker` | do work on the main thread |
| Popups/dialogs | `window.open`, `alert`, `confirm`, `prompt` | render UI in the page |
| Navigation | navigating the parent (`parent.location`, `top.location`) | — (allowed: `parent.postMessage`) |
| Downloads | `<a download>`, programmatic blob downloads | the postMessage export protocol (below) |
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

## Files out — the export protocol

Download APIs are blocked. Post the file to the host, which validates the source frame, enforces a
MIME allowlist and size cap, sanitizes the filename, and creates the download:

```js
function exportFile(name, mime, data) {
  parent.postMessage({ type: 'export', name, mime, data }, '*');
}
exportFile('report.csv', 'text/csv', csvString);
```

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
- missing early `<meta charset>`; high `U+FFFD` density
- wrapping markdown code fences
- size over the soft (5 MB) / hard (10 MB) limits
