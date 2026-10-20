---
name: datalens-onprem-install
description: >-
  Install, configure, troubleshoot, update, or remove the commercial DataLens
  On-premises distribution using current docs. Use for single-node K3s setup, sizing,
  interrupted installs, feature changes, Public API, service accounts, MCP,
  LDAP/OIDC, and backup or restore. Not for Yandex Cloud, Yandex Team, the
  Open Source edition, or building charts and dashboards.
---

# DataLens On-premises

Start with the [product landing page](https://datalens.ru/on-premises/) for a
basic overview of DataLens On-premises and links to product information.

Use `datalens` for shared concepts and interface choice. This file owns
administration of the commercial On-premises distribution. Use `datalens-sdk`
for work on analytical objects and `datalens-html-pages` for HTML reports.

## Choose the task

Confirm the edition and goal. If the edition is unclear, check the package docs
or ask where it came from. For the Open Source edition, use its
[repository docs](https://github.com/datalens-tech/datalens). The presence of
`init.sh`, Helm, or a local host alone does not identify the edition.

Check whether an instance already exists and go straight to the needed section.
API or login changes on a running instance do not need sizing
or a new install. Use the install flow for single-node K3s; for an existing
Kubernetes cluster or external services, follow the matching docs and keep
that setup.

## Read current sources

Read only what the task needs, whenever it is needed, including before install.

- [Deployment guide](https://datalens.ru/on-premises/docs/ru/concepts/create-instance.html): requirements, download, install, update, flags, and values.
- [Configuration recipes](https://datalens.ru/on-premises/docs/ru/cookbook/configuration.html): features and their dependencies.
- [Logs and diagnostics](https://datalens.ru/on-premises/docs/ru/cookbook/logging.html): pod logs, cluster events, and `--get-debug-info`.
- [Public API](https://datalens.ru/on-premises/docs/ru/operations/api-start.html) and [MCP README](https://github.com/datalens-tech/datalens-mcp): service accounts, tokens, and client setup.
- [LDAP/OIDC](https://datalens.ru/on-premises/docs/ru/concepts/auth-providers/): provider fields and examples.
- [Backup and restore](https://datalens.ru/on-premises/docs/ru/cookbook/migrations.html) and [secrets](https://datalens.ru/on-premises/docs/ru/concepts/secrets-instance/): data recovery and keys.
- [Service version](https://datalens.ru/on-premises/docs/ru/concepts/what-version.html) and [release notes](https://datalens.ru/on-premises/docs/ru/changelog.html): running version and changes along the update path.

If public docs are unreachable, use the local documentation:

- Find and unpack the Markdown docs archive inside the selected distribution.
  Inspect the package for its actual name and layout; search the Markdown files
  for the needed topic.
- Read the separate `readme.md` for deployment instructions and documentation
  links. Check the actual file name and letter case in the package.
- After deployment, open `<domain>/docs` on the target instance, using its
  configured scheme and domain. Follow its links or search for the needed topic.

Use docs that match the version being installed or managed. Without access,
ask the user for the relevant local files or excerpts, not only a public URL.

Run `./init.sh --help` from the selected distribution directory before building
commands. Check its `help/` examples and scripts when details are unclear.
Verify flags, file names, defaults, and merge rules against that distribution;
public docs may describe a newer release. If sources still conflict or neither
public nor local sources cover the task, explain the gap and request the
relevant help output or docs. Do not guess.

## Work with the user

- Reuse known inputs. Ask only for missing details needed for the task.
- Use local commands or SSH on the agreed target. Without access, give short
  command blocks and wait for the output before dependent steps.
- Give a short status after checks. Before deployment or a critical change,
  show the exact target, command, effect, and how to check the result. Get approval
  unless that specific action is already approved. Use `--yes` only for an approved
  non-interactive run, after checking that the distribution supports it.
- Keep passwords, tokens, private keys, provider files, and backup keys out of
  chat, logs, and Git. Store needed secret files outside the repo with mode 600.
  Treat all values and debug files as sensitive; tokens may be outside `secrets`.
- Use absolute paths for input files. Run `init.sh` from the distribution root.
  Keep long operations running and report progress; do not restart blindly.

## Inspect the target

Find the distribution path, installed version, cluster context, Helm release,
and namespace. Check access before treating a missing result as an empty system.
Use the target's Kubernetes and Helm tools; for local K3s, use
`sudo k3s kubectl` and a Helm client with the same kubeconfig.

Check nodes, pods, events, and Helm releases, including failed and pending ones:
`kubectl get nodes`, `kubectl get pods -A`, `kubectl get events -A`, and
`helm list -A --all`. Then inspect `helm status` and `helm history` for the
selected release and namespace. Check its current values and the UI when present.

A debug file such as `.values.debug.yaml` or `values.debug.yaml` is only a clue
from a past run. Its absence does not mean installation never started; its
presence does not prove the current release is healthy. Diagnose a failed or
pending deployment before continuing. Never replace an existing cluster just
because a file is missing.

## Size the machine

Read the current [hardware requirements](https://datalens.ru/on-premises/docs/ru/concepts/create-instance.html#hardware).
Ask for the approximate user count, concurrent use, workload, needed features,
and pilot or production use. Check OS, CPU, RAM, disk, network, domain, and TLS.
For production, review the documented external PostgreSQL and availability
requirements.

Use these single-node presets from the spec calculator, "Presets" tab
(snapshot 2026-08). Basic means dashboard viewing and basic features;
All features includes export, file connectors, Editor, and other features.
Round the user count up to the next table row. These are minimum machine
presets, not a capacity guarantee; check current requirements and validate
the planned workload with load testing.

| Users | Scenario | vCPU | RAM, GiB | SSD, GiB |
|---:|---|---:|---:|---:|
| 100 | Basic | 16 | 32 | 100 |
| 100 | All features | 32 | 64 | 100 |
| 250 | Basic | 32 | 64 | 100 |
| 250 | All features | 64 | 128 | 100 |
| 500 | Basic | 64 | 128 | 100 |
| 500 | All features | 96 | 192 | 100 |
| 1000 | Basic | 96 | 192 | 100 |
| 1000 | All features | 192 | 384 | 100 |
| 5000 | Basic | 448 | 896 | 100 |
| 5000 | All features | 640 | 1280 | 100 |
| 10000 | Basic | 768 | 1536 | 100 |
| 10000 | All features | 1216 | 2432 | 100 |

Offer a quick pilot option: **16 vCPU / 32 GiB RAM / 100 GiB SSD** for the
main features, with room to scale up later.

- Keep at least 16 vCPU and 32 GiB RAM, even for small teams.
- 100 GiB SSD is a minimum for the system and embedded databases. Allow more
  space for file connectors and usage tracking as their data grows.
- All features assumes an async load factor of ×1. For heavy background work,
  such as mass scheduled exports, budget ×2–×4 CPU/RAM; ask the DataLens team
  for a detailed calculation with the extended calculator.
- For 5,000+ users, review whether one machine is suitable. Above 10,000 users,
  ask the DataLens team for individual sizing and a multi-node setup.

## Install

Get the archive path or download link from the user. Follow the download and
unpack instructions; use an absolute destination and check for `init.sh` and
`helm/`. Build the command from this distribution's help and the agreed
features. Prepare LDAP/OIDC now if needed. Use `--k3s-install` only when a new
local cluster is required. Preserve existing certificates and keys on re-runs.

Run the approved command and verify the result below. For a new instance,
use the documented admin-password command and have the user test login and
store the password securely. Set up API or external login only when requested.

## Apply configuration

Read the current release settings before adding a feature. Preserve its domain,
TLS, storage, secrets, and other enabled features. Do not assume old flags are
kept on a re-run. Check how this version handles `--values` and `--values-merge`;
neither a partial file nor a few new flags should silently reset other settings.
Check feature dependencies in the current recipes and chart.

Prepare a custom values file that preserves the required existing settings.
Do not edit `helm/values.yaml`. Set `DL_DIST` and `DL_VALUES` to absolute paths,
and `DL_RELEASE` and `DL_NAMESPACE` to the inspected release. After reviewing
the config change, checking these flags, and getting approval, apply it:

```bash
cd "$DL_DIST"
./init.sh --release-name "$DL_RELEASE" --release-namespace "$DL_NAMESPACE" \
  --values "$DL_VALUES" --yes
```

Use the same command to apply later edits to that file. Keep the current
cluster context. Do not add cluster-install or key/certificate-generation flags
for a feature change. Reload images only when the selected change needs it.

## Public API and MCP

Enable the API with the supported flag or values setting using the configuration
flow above. Get the UI and API URLs from the user or verified deployment config;
do not infer one from the other. Read the instance's Swagger and OpenAPI schema.
Check that the schema response is valid OpenAPI JSON, not HTML returned with HTTP 200.

Follow the current API docs to create a service account and key, grant the
needed object access, sign its JWT, and exchange it for an access token.
This skill has no token script. If code is needed, adapt the current documented
example, use absolute paths for the temporary script and key, and state which
machine can reach the API. Check the response body and use a valid read-only
API call to verify access; a validation error is not a successful test.

For self-signed TLS, prefer a trusted CA; for Node, use `NODE_EXTRA_CA_CERTS`
with an absolute CA path. If the user approves a temporary verification bypass,
use only `NODE_TLS_REJECT_UNAUTHORIZED=0`, scoped to the individual process.
Apply the chosen TLS setting to both token exchange and MCP: an MCP setting
does not affect an earlier token command. Do not add a custom TLS variable.
For `fetch failed`, inspect the underlying cause without printing secrets.

If MCP is requested, use its current README and the installed client's setup
instructions. Set the instance URL, schema URL, API version, and Bearer auth
from the verified API. Check the connection and a read-only tool call. Plan
for token expiry and renewal; do not hard-code a token lifetime in this skill.

## LDAP/OIDC

Read the provider docs and the distribution's provider-config example. Check
provider reachability, the public DataLens URL, callback URL, and role mapping.
Use the documented provider flag or `secrets.AUTH_PROVIDERS_CONFIG`. If the
release uses `secrets.ref`, follow the external-secret instructions; inline
secret values may be ignored.

Keep `features.auth.local: true` for the first change. Apply the provider config
and login settings with the configuration command above, preserving the rest
of the release. Test a real LDAP/OIDC login in a fresh browser session and check
the expected roles, including administrator access. A visible provider button
alone is not enough.

Only after that test, if external-only login is requested, save a recovery path,
set `features.auth.local: false` in the same values file, and apply it with the
same command after approval. Re-test login. Use `skip_local` and
`force_redirect_open_id` only when the current docs and provider setup allow it.

## Verify and troubleshoot

Check Helm status, workload readiness, completed jobs, UI response, login, and
the requested feature. Running pods alone do not prove success.

Use `./init.sh --get-debug-info` from the distribution root to collect a
diagnostic archive. First check support and target options in this version's
help; use the intended cluster, release, and namespace. Inspect host CPU, RAM,
and disk, Helm values, pod status, events, and recent pod logs. Contents may
vary by version; collect missing details separately. Without access, give the
command to the user. Keep the archive private and share only redacted excerpts.

For `context deadline exceeded`, inspect pods and events first, then logs.
Too little CPU or memory can cause this timeout. Also check slow startup,
image pulls, storage, networking, and feature dependencies. Share redacted
evidence and the next action; do not silently rerun the deployment.

## Back up, update, or remove

Before update, restore, or removal, agree on backup scope. A PostgreSQL dump
covers the DataLens metadata stored there, such as users, permissions, and
objects. It does not include Kubernetes Secrets, S3 objects, ClickHouse data,
or external source databases. Check the dump command's exact database scope
in this distribution. Save `CONTROL_API_CRYPTO_KEY` separately and securely:
it is needed to read saved connection secrets. Preserve other required secrets,
configuration, and stores using the current recovery docs. Keep backups outside
the machine or directories that will be removed, and verify they can be read.

For an update, check the running version from the live instance and identify the
target version. An unpacked archive does not prove what is running. Read release
notes for the whole update path. Check which migrations the target script runs
automatically; do not repeat them manually or assume every migration is automatic.
Follow that version's update procedure, with explicit unpack and working
directories, then verify the running version and affected features. Use `--update`
only when supported for this path. `--restore-postgres` restores database data; it does
not roll back application images, Helm changes, or an update. Treat database
restore and application rollback as separate recovery actions. Check restore
compatibility and syntax in the selected distribution. Confirm any restore that
clears data.

For removal, confirm the exact instance, affected data, and backup decision.
Use `k3s-uninstall.sh` only for a dedicated K3s cluster whose removal is approved;
it removes the cluster and its local data, including other workloads. For a
shared cluster, follow the release-specific removal procedure. Confirm exact
paths before removing distribution files; do not assume external data is deleted.
