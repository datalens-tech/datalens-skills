---
name: datalens-onprem-install
description: >-
  Step-by-step installation of DataLens On-premises on a single-node K3s with embedded
  PostgreSQL/ClickHouse/Redis/MinIO: sizing by user count, delivering the distributive, choosing
  the feature set, running init.sh, retrieving the admin password, enabling the Public API and a
  service account; plus separate modes to update an instance (init.sh --update) and to uninstall
  it (k3s-uninstall). Use it when asked to install or deploy DataLens on-premises (установить или
  развернуть DataLens on-premise / онпрем), resume an interrupted installation, size a machine for
  an instance, update or remove an existing instance, enable the Public API, or configure external
  login providers (LDAP/OIDC) on-premise. NOT for Yandex Cloud or the internal Yandex Team
  installation, and not for building charts or dashboards (that is `datalens-sdk`).
license: Apache-2.0
metadata:
  domain: datalens
---

# DataLens On-premises installation

A conversational skill for a DevOps engineer. Scope: a single-node K3s with embedded
PostgreSQL/ClickHouse/Redis/MinIO (`init.sh --k3s-install`).

## Principles

- Every stage ends with a checkpoint: a short summary of what was done plus the engineer's
  confirmation. You can stop at any point — no state is stored anywhere; when you return, the
  skill re-detects where you left off (see "Re-detection").
- Read a reference only at its stage: `references/sizing.md` (stage 1), `references/flags.md`
  (stage 4), `references/api-setup.md` (stage 7), `references/auth-providers.md` (stage 8),
  `references/update.md` (update mode). Do not read them ahead of time.
- Never write secrets (the admin password, tokens, `.pem` keys) into project files, and never
  commit them.

## Command-execution mode

Chosen at stage 2, applies to stages 3–7:

- **ssh mode** — the agent runs the commands on the target machine itself via
  `ssh <host> '<cmd>'`. Before starting, verify non-interactive access:
  `ssh -o BatchMode=yes <host> 'echo ok'`.
- **instructions mode** — the agent prints commands in blocks, the engineer runs them and returns
  the output. Wait for the output after each block; do not push ahead blind.

If installing onto the current machine — just use Bash.

## Re-detection (always the first step when resuming)

Determine the state and jump to the first unfinished stage:

| Signal on the target machine | Go to |
|---|---|
| machine not chosen yet / new conversation | stage 1 |
| no unpacked distributive (`init.sh`, `helm/`) | stage 3 |
| distributive present, no `.values.debug.yaml` next to it | stage 4 (install never ran) |
| `.values.debug.yaml` present, pods not Running (`sudo k3s kubectl get pods -A`) | stage 5 (unfinished/broken) |
| pods Running, UI responds | stage 6 or 7 |
| instance running, engineer asks to update | update mode (`references/update.md`) |
| engineer asks to remove the instance | uninstall mode (see below) |

`.values.debug.yaml` is the source of truth for the previous run's parameters (a hidden dot-file).
It normally holds no secrets, but an install run with `--yandex-map-token` or `--ai-api-token` can
land those values in it — check before quoting the file wholesale.

## Stages

### 1. Sizing

Ask for the approximate number of users and the scenario: basic features only, or all of them.
Read `references/sizing.md` and pick a machine configuration. Always offer the option to skip the
calculation: the pilot config **16 vCPU / 32 GiB RAM / 100 GiB SSD** is enough for a pilot with
all the main features, and can be scaled up later. Checkpoint: the engineer confirms a machine with
those resources exists or will.

### 2. Target machine

Local or remote? For a remote one, ask for host/user and the execution mode (ssh or instructions),
and verify access. On the machine, check:

- OS: `cat /etc/os-release` — guaranteed to work on Debian-based (Ubuntu 20.04–24.04,
  Debian 10–12)
- resources: `nproc`, `free -g`, `df -h /` — compare against the stage-1 recommendation
- presence of `curl`, `tar`

Fewer resources than recommended — warn, but do not block.

### 3. Distributive

Ask what the engineer has: a path to the tar file, or a curl link (obtained in the DataLens
cabinet; requires a contract and the `datalens.admin` role).

- link: `curl -L "<url>" -o datalens-enterprise.tar`
- local file + remote machine: `scp <file> <host>:~/`

Unpack: `mkdir -p datalens-enterprise && tar -xvf datalens-enterprise.tar --directory ./datalens-enterprise`
Check: `init.sh` and `helm/` appeared in the folder.

### 4. Install composition

Read `references/flags.md`. Offer three options: **full**, **basic**, **custom** (per the flag
table). If the stage-1 scenario was "all features" — default to full; "basic" — to basic. Collect
the inputs: the domain for `--ingress-domain` (no domain — default `datalens.enterprise` + a hosts
entry), TLS (self-signed `--ingress-tls-gen` or your own certificates), and, for the full option,
whether there is a Yandex Maps token (without a token `--yandex-map` runs on the free tier ~1000
requests/day but needs network access to the Maps API; in an air-gapped environment drop the flag).
If the engineer wants login through an external IdP (LDAP / OIDC) from the start, this is also set
here via `--auth-providers-config` — see stage 8 and `references/auth-providers.md` (it can equally
be added later to a running instance). Checkpoint: show the assembled `./init.sh ...` command in
full and get confirmation.

### 5. Install

Run the stage-4 command from the distributive folder. **For a non-interactive run (background, ssh
without a TTY) you must add `--yes`** — otherwise `init.sh` reaches the prompt
`Check diff for new helm release, do you want to continue [Y/n]?` and hangs forever, waiting for
input on a disconnected stdin (you lose the whole image-import cycle on the restart). This takes a
while (tens of minutes): run it in the background / with a large timeout and show progress. When
done:

- `sudo k3s kubectl get pods -A` — all pods Running/Completed
- UI check. If the domain does not resolve on the machine itself (no hosts entry), resolve it
  manually: `curl -sk --resolve <domain>:443:127.0.0.1 https://<domain>/` — the UI responds

If the install fails — show the tail of the output, offer diagnostics (`./init.sh --stern` for
logs), and do not silently restart.

### 6. Admin password

`./init.sh --get-admin-password` — show it to the engineer and advise storing it in a password
manager (if lost, it can be reset and regenerated). Login: `https://<domain>`, user `admin`.
Checkpoint: the engineer confirms they logged in.

### 7. Public API and service account (optional)

Offer to set up programmatic API access. If agreed — read `references/api-setup.md` and follow it:
enabling `--public-api` (if not already on), the service account (manual steps in the UI), minting
an accessToken with `scripts/onprem_mint_token.mjs`, verification, and optionally wiring up the MCP
server.

### 8. External authentication providers — LDAP / OIDC (optional)

If the engineer wants login through an external IdP (LDAP or OpenID Connect; SAML is not
supported) — read `references/auth-providers.md` and follow it: fill a JSON provider config (a
template ships at `./help/auth-provider-config.example.json`), pass it via
`--auth-providers-config <path>`, optionally restrict login to external IdP only
(`features.auth.local: false`), and verify the provider appears on the login page. This can be set
at first install (stage 4) or added later to a running instance via a re-run (see "Speeding up a
redeploy" in `references/flags.md`). The config holds bind credentials / client secrets — treat it
as a secret.

## Mode: update (only on an explicit request)

If the instance is already installed and the engineer asks to update it — read
`references/update.md` and follow it: determine the installed and the latest versions (changelog or
manually), review the breaking changes along the upgrade path, offer a `--dump-postgres` backup,
unpack the new archive over the old one, `./init.sh --update`, verify. Do not offer updates
proactively.

## Mode: uninstall (only on an explicit request)

A destructive operation: the cluster and all instance data are deleted. Before running it,
explicitly confirm with the engineer that the instance and its data are no longer needed, and offer
a backup: `./init.sh --dump-postgres` (copy the dump off the machine immediately — it disappears
together with the folder).

1. `sudo /usr/local/bin/k3s-uninstall.sh` — tears down K3s with all pods and data (the script
   appears once K3s is installed).
2. Remove the distributive folder: `rm -rf <path>/datalens-enterprise` (and the tar archive if no
   longer needed).

## Docs

- Installation and all parameters: https://datalens.ru/on-premises/docs/en/concepts/create-instance.html
- Feature flags: https://datalens.ru/on-premises/docs/en/concepts/create-instance.html#functionality
