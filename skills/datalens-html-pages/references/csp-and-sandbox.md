# CSP, sandbox & serving model

The security model for DataLens HTML pages is three layers: an **opaque-origin sandboxed
iframe**, a **CSP injected at upload**, and **short-TTL presigned serving**. This is the
authoritative reference; the linter (`../scripts/validate_page.py`) encodes the resource
allowlist below.

## Iframe & origin isolation

The host renders the page like this:

```html
<iframe src="<presigned-url>&theme=dark&lang=ru"
        sandbox="allow-scripts" allow="" referrerpolicy="no-referrer"></iframe>
```

- `sandbox="allow-scripts"` — scripts run, but the frame is an **opaque origin**: no
  `allow-same-origin`, so it cannot reach the parent's origin, cookies, or storage.
- `allow=""` — no delegated permissions (camera, geolocation, fullscreen, …).
- The **parent** sends `Cross-Origin-Opener-Policy: same-origin`. The opaque-origin isolation
  depends on both the missing `allow-same-origin` **and** this COOP header — never add
  `allow-same-origin`.

## The injected CSP

Prepended at upload (after stripping any leading BOM and any prior injection block — injection is
idempotent). You do **not** author this; you author *against* it:

The Maps hosts are `api-maps.yandex.ru`, `*.api-maps.yandex.ru`, `*.maps.yandex.net` and
`suggest-maps.yandex.ru` — referred to below as "the four Yandex Maps hosts".

```html
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="
  default-src 'none';
  script-src https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://cdn.tailwindcss.com https://yastatic.net https://api-maps.yandex.ru https://*.api-maps.yandex.ru https://*.maps.yandex.net https://suggest-maps.yandex.ru 'unsafe-inline' 'unsafe-eval';
  style-src  https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://cdn.tailwindcss.com https://yastatic.net https://fonts.googleapis.com 'unsafe-inline' blob:;
  img-src    https://yastatic.net https://api-maps.yandex.ru https://*.api-maps.yandex.ru https://*.maps.yandex.net https://suggest-maps.yandex.ru https://yandex.ru/clck/ data: blob:;
  font-src   https://cdn.jsdelivr.net https://cdnjs.cloudflare.com https://fonts.gstatic.com data:;
  media-src  data: blob:;
  connect-src https://api-maps.yandex.ru https://*.api-maps.yandex.ru https://*.maps.yandex.net https://suggest-maps.yandex.ru;
  form-action 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'">
```

Notes / rationale:

- **`default-src 'none'`** — everything is denied unless a specific directive re-allows it.
- **Inline is allowed** (`'unsafe-inline'`, `'unsafe-eval'` for scripts) — inline your own CSS/JS
  freely; the isolation comes from the sandbox, not from blocking inline code.
- **Google Fonts is split on purpose:** CSS from `fonts.googleapis.com` (in `style-src`), font
  files from `fonts.gstatic.com` (in `font-src`).
- **KaTeX / MathJax** `woff2` files come from jsdelivr/cdnjs — that is why those hosts are in
  `font-src`.
- **`connect-src`** lists only the Yandex Maps hosts, so the JS API can fetch its config and
  vector tiles. For everything else `fetch`/XHR/WebSocket/EventSource/`sendBeacon` still fail —
  the page cannot reach your data over the network. Inline the data.
- **`worker-src 'none'`** is explicit so it can't fall back to `script-src`.
- **Yandex Maps JS API 2.1** (`api-maps.yandex.ru`, `*.api-maps.yandex.ru`, `*.maps.yandex.net`,
  `suggest-maps.yandex.ru` for the search control's suggestions) is allowed in `script-src`,
  `img-src` (tiles, icons) and `connect-src`. `style-src` carries `blob:` because the Maps API
  injects its own stylesheets as blob URLs. `yandex.ru/clck/` in
  `img-src` is the API's usage beacon; you never reference it yourself. Maps v3 is **not**
  supported: it needs an API key to load at all and its vector renderer wants workers.
- `img-src` is `yastatic.net` + the maps hosts + `data:` + `blob:`; `media-src` is `data:`/`blob:`
  only.

### Resource allowlist (what the linter checks)

| Directive | Hosts / schemes |
|-----------|-----------------|
| `script-src` | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com`, `yastatic.net`, the four Yandex Maps hosts, inline |
| `style-src` | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `cdn.tailwindcss.com`, `yastatic.net`, `fonts.googleapis.com`, `blob:`, inline |
| `font-src` | `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `fonts.gstatic.com`, `data:` |
| `img-src` | `yastatic.net`, the four Yandex Maps hosts, `data:`, `blob:` (the policy also lists `yandex.ru/clck/` for the Maps API's own beacon — the linter does not allow it, never reference it) |
| `media-src` | `data:`, `blob:` |
| `connect-src` | the four Yandex Maps hosts (Maps API internals only) |
| `form-action`, `frame-src`, `object-src`, `worker-src`, `base-uri` | `'none'` |

## Serving

- **`getHtmlPagePreviewUrl`** validates the viewer's permission, resolves the current page
  revision, and mints a **presigned GET with a 10–30 s expiry** — the permission check and URL
  minting are in one function, so there is no time-of-check/time-of-use gap.
- Theme and language travel as **signed query params**.
- A presigned URL opened top-level within its TTL keeps the injected CSP but loses the iframe sandbox.
- Object metadata on PutObject: `Content-Type: text/html; charset=utf-8`,
  `Content-Disposition: inline`, `Cache-Control: no-store`.
- Upload is **server-side JSON RPC-like API** (HTML as a plain string, never base64); there are **no
  presigned PUTs**, because CSP injection and metadata must stay server-controlled. Per-method
  body limit ≈ 10 MB, with early `Content-Length` rejection at the edge.

## Parent-message protocol

`parent.postMessage` is the **only** sanctioned channel to the host (it is not blocked by the
linter). The host verifies `event.source === iframe.contentWindow` and dispatches on the message
`code`.

**Export a file** — downloads are blocked in the sandbox, so hand the bytes to the host, which
applies a MIME allowlist and a size cap, sanitizes the filename, and generates the download:

```js
parent.postMessage({ code: 'EXPORT', data: { name, mime, data } }, '*');
```

**Open a URL** — ask the host to open a link from the sandbox:

```js
parent.postMessage({ code: 'OPEN_URL', data: { url } }, '*');
```

Use the framed-only delegated listener in
[authoring-constraints.md](authoring-constraints.md), which leaves in-page anchors alone.
