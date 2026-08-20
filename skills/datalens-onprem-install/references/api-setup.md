# Stage 7: Public API and service account

## 1. Enable the Public API (if not enabled)

Check `.values.debug.yaml` in the distributive folder (a hidden dot-file): the `public_api:` block
→ `enabled: true`/`false`. If it is off — repeat the stage-4 install command with `--public-api`
and `--yes` added (repeat the previous flags too; `--k3s-install` can be dropped — see "Re-running
init.sh" and "Speeding up a redeploy" in `flags.md`). This is a redeploy and takes time.

To check the API is alive, the raw OpenAPI spec returns JSON. If the domain does not resolve on the
machine itself, resolve it manually with `--resolve`:

```bash
curl -sk --resolve <domain>:443:127.0.0.1 \
  https://<domain>/api/docs/swagger/json | head -c 200
```

**Caution:** the status code means nothing — look at the body. It must be JSON starting with
`{"openapi":`. For an unknown path the on-prem usually returns the SPA (HTTP 200 +
`<!DOCTYPE html>`), and with public_api off it returns the HTML error
`Cannot GET /api/docs/swagger/json`; both mean "the API is not ready".

## 2. Service account — manual steps in the UI

The agent cannot do this; guide the engineer step by step:

1. In the UI, as admin, create a **service account** → save its id (`sa-id`).
2. Issue a **key** for it → save the `key-id` and the private `.pem` key (shown once).
3. Roles: with the minimal role (Visitor) the SA sees only the objects it was explicitly added to.
   For real work, add the SA to the relevant workbooks/collections or grant a higher role.

The `.pem` is a secret: `600` permissions, do not commit it to a repository.

## 3. Get an accessToken

The flow (from the on-prem docs): sign a JWT with the private key — `alg=PS256`, header
`kid=<key-id>`, payload `{iss:<sa-id>, iat, exp}`, `exp ≤ now+600` — and exchange it:
`POST /rpc/exchangeServiceAccountToken` with the header `x-dl-api-version: 2` and body
`{"saToken":"<JWT>"}` → `{"accessToken":"..."}`.

A ready-made script (needs node ≥ 18, no dependencies):

```bash
DL_HOST=https://<domain> DL_SA_ID=<sa-id> DL_KEY_ID=<key-id> \
DL_KEY_PATH=<path to .pem> node scripts/onprem_mint_token.mjs
```

Prints the accessToken to stdout, diagnostics to stderr.

**Where to run it.** On any machine with node ≥ 18 that can reach the API. The target VM often has
no node — then run it locally. If the domain does not resolve locally, add it to hosts, or sign the
JWT locally and do the exchange (`/rpc/exchangeServiceAccountToken`) with `curl` wherever the API
is reachable (self-signed TLS — `-k`, if needed — `--resolve <domain>:443:<ip>`).

**A key from chat.** A copy-pasted private key often arrives with the base64 broken up by spaces
(newlines lost). Before signing, reconstruct the PEM: strip all spaces between
`-----BEGIN/END-----` and fold the body at 64 characters, then check
`openssl pkey -in key.pem -check -noout` (expect `Key is valid`). File permissions `600`, do not
commit.

**Troubleshooting `AUTH.INVALID_SERVICE_ACCOUNT_JWT` / "signature verification failed".** This is
a **key mismatch**, not an algorithm problem — don't waste attempts switching PS256↔RS256. The
error "signature verification failed" (rather than "key not found") means the server found the key
by `kid` but the signature does not verify. If the key is valid per `openssl` and a local
self-verify of the signature passes, the private key does not match the registered public key:
re-issue the key in the UI and take the fresh private one.

## 4. Verify access

Pick any read-only method in Swagger (`https://<domain>/api/docs/swagger`) and call it. A handy
method with no parameters is `getRootCollectionPermissions`. If the domain does not resolve
locally, add `--resolve <domain>:443:<ip>`:

```bash
curl -sk -X POST https://<domain>/rpc/getRootCollectionPermissions \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-dl-api-version: 2" \
  -H "content-type: application/json" \
  -d '{}'
```

A 200 with a body (e.g. `{"createCollectionInRoot":true,...}`) means access works. A 400
`VALIDATION_ERROR` about a missing parameter is also an authentication success (the method simply
requires an argument). 401 — the token expired or the SA has no key; an empty object list is normal
for an SA-Visitor that was not added anywhere (not an access error).

## 5. Wire up the MCP server (if the engineer works in Claude Code)

The source is the public package `@datalens-tech/mcp` (GitHub `datalens-tech/datalens-mcp`), run
via `npx`, no separate build needed. It exposes a three-tool gateway: `list_commands` →
`describe_commands` → `invoke_command`.

```bash
TOKEN=$(DL_HOST=https://<domain> DL_SA_ID=<sa-id> DL_KEY_ID=<key-id> \
  DL_KEY_PATH=<key.pem> node scripts/onprem_mint_token.mjs)
claude mcp add datalens-onprem -s user \
  -e DATALENS_API_URL=https://<domain> \
  -e DATALENS_SCHEMA_URL=https://<domain>/api/docs/swagger/json \
  -e DATALENS_API_VERSION=2 \
  -e DATALENS_YC_STATIC_AUTH=1 \
  -e DATALENS_ORG_ID=onprem \
  -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
  -e "DATALENS_API_AUTH_HEADER=Bearer $TOKEN" \
  -- npx -y @datalens-tech/mcp@latest
```

- `DATALENS_YC_STATIC_AUTH=1` + `DATALENS_API_AUTH_HEADER` — static authentication with the on-prem
  token (instead of `yc`).
- `DATALENS_ORG_ID` is always required by the package; on a yandex installation the org-id is
  ignored — set a placeholder (any non-empty string).
- `NODE_TLS_REJECT_UNAUTHORIZED=0` — required with a self-signed certificate (`--ingress-tls-gen`),
  otherwise the node client silently fails to connect.
- `DATALENS_SCHEMA_URL` — exactly `/api/docs/swagger/json` (not `/json/`);
  `DATALENS_API_VERSION=2` — a const in the on-prem spec.
- Check: `claude mcp list` should show `datalens-onprem: ✔ Connected`.
- The token is static and expires: on a 401, re-mint it (`claude mcp remove datalens-onprem -s user`
  and add it again with a fresh token).
- The MCP tools appear only after restarting Claude Code.
