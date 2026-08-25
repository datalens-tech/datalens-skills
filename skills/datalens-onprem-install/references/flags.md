# Presets and feature flags

Docs snapshot from 2026-08. The up-to-date list is always here:
https://datalens.ru/on-premises/docs/en/concepts/create-instance.html#functionality

## Presets

Both commands are run from the unpacked distributive folder.

**Full** (popular features):

```bash
./init.sh --k3s-install \
  --ingress-domain <domain> --ingress-tls --ingress-tls-gen \
  --export --files --editor --cache --usage-tracking \
  --yandex-map
```

If there is a Yandex Maps token — add `--yandex-map-token <token>`.

**Basic:**

```bash
./init.sh --k3s-install \
  --ingress-domain <domain> --ingress-tls --ingress-tls-gen
```

Notes:

- Non-interactive run (ssh mode, background) — add `--yes`, otherwise the install hangs on the
  helm-diff confirmation. In instructions mode (the engineer runs it and wants to see the diff)
  `--yes` can be omitted.
- `--yandex-map` works without a token too: there is a free tier of ~1000 Maps requests per day,
  but the machine needs network access to the Yandex Maps API (in an air-gapped environment the
  feature will not work). `--yandex-map-token` is for volumes above the free tier.
- `--ingress-tls-gen` is a self-signed certificate. If you have your own, use
  `--ingress-tls-crt <path> --ingress-tls-key <path>` instead.
- No domain — you can omit `--ingress-domain`: the default is `datalens.enterprise`, and then a
  hosts entry is needed on users' machines.
- `--public-api` is not part of the presets — it is enabled at stage 7 if needed.

## Custom install: flag table

| Flag | Default | What it enables |
|---|---|---|
| `--export` | off | Workbook import/export (pulls in meta-manager, ui-api, temporal) |
| `--background-exports` | off | Background CSV/XLSX export for table charts |
| `--files` | off | CSV/XLSX file connectors (pulls in embedded ClickHouse, Redis, S3) |
| `--editor` | off | Editor charts and the JSON API Connector |
| `--cache` | off | Dataset caching |
| `--usage-tracking` | off | Writing usage events to ClickHouse (via Fluent Bit) |
| `--yandex-map` (opt. `--yandex-map-token <t>`) | off | Yandex Maps layers: without a token, free tier ~1000 requests/day, needs access to the Maps API |
| `--sec-embeds` | off | Non-public embeds |
| `--auth-cookie-domain <d>` | off | Embeds on a corporate domain |
| `--public-api` | off | Public API (needed for stage 7) |
| `--ai-endpoint`, `--ai-model-name`, `--ai-api-token` | off | AI assistant (OpenAI-compatible API) |
| `--disable-demo` | demo on | Remove demo data |
| `--disable-hc` | HC on | Replace Highcharts with Gravity UI Charts |

Disabling embedded components (`--disable-postgres`, `--disable-clickhouse`, `--disable-redis`,
`--disable-s3`, `--disable-temporal`) is the external-cluster scenario, out of scope for this
skill's single-node install.

## Other useful arguments

- `--yes` — skip all interactive confirmations. **Required for a non-interactive run** (background,
  ssh without a TTY): without it `init.sh` hangs on the helm-diff confirmation.
- `--atomic` — transactional install with a full rollback on failure. Do not offer it by default,
  but run it if the engineer asks.
- `--cpu-scale <k>` — CPU-requests scaling factor.
- `--k3s-image-load` — only load images into k3s (without installing the cluster); for a redeploy
  with changed images, instead of `--k3s-install`.
- `--skip-meta-check` — skip the distributive checksum verification.
- `--get-admin-password`, `--update` (version upgrade), `--stern` (logs), `--kubectl` (kubectl into
  the cluster).

## Re-running init.sh

Assume flags **do not accumulate** between runs: a restart applies whatever is passed now. The
previous run's parameters are in `.values.debug.yaml` (created after the deploy, a hidden dot-file).
It normally holds no secrets, but tokens passed at install (`--yandex-map-token`, `--ai-api-token`)
can end up in it — check before quoting it wholesale. When adding a feature, repeat the previous
flags + the new ones, and verify the result against a fresh `.values.debug.yaml`.

**Non-interactive run:** add `--yes` — otherwise `init.sh` hangs on the helm-diff confirmation
(`... do you want to continue [Y/n]?`), waiting for input on a disconnected stdin.

**Speeding up a redeploy.** `--k3s-install` is only needed for the first install (it provisions the
cluster). On a re-run, **drop it**: with it, `init.sh` still runs the image load (~8–10 min on a
single node). Images only need reloading when they actually changed (a version upgrade) — then use
`--k3s-image-load`. For a pure feature-flag toggle (same version) you can pass neither
`--k3s-install` nor `--k3s-image-load`: init goes straight to the helm upgrade using the
already-loaded images. Example of quickly enabling a feature:

```bash
./init.sh --ingress-domain <domain> --ingress-tls --ingress-tls-gen \
  <previous feature flags> --public-api --yes
```
