---
name: datalens-rls-resolve
description: >-
  Use this skill when a DataLens user on datalens.yandex.cloud needs to resolve user, email,
  service-account, or Cloud Organization group names into RLSv2 subject IDs, fill the `rls2`
  field, or migrate a legacy `rls` configuration.
license: Apache-2.0
metadata:
  domain: datalens
---

# DataLens RLS resolve

## Overview

For cloud DataLens (`datalens.yandex.cloud`). RLSv2 (the `rls2` field) stores subjects by
**id**, whereas the legacy RLS (the `rls` text config) let you use **names**. This skill
resolves names → ids via the `yc` CLI (Cloud Organization Manager) and can emit a complete
`rls2` config.

Users → cloud subject id (`subjectId`, = `subjectClaims.sub`); groups → org group `id`.
`subject_name` is display-only; `subject_id` is what enforcement uses. Unresolved subjects
in `convert` output become `notfound` with a `!FAILED_` name prefix. In `resolve` output,
resolved subject objects stay under `resolved` and unresolved input names are listed separately
under `unresolved`.

> **⚠️ Access required.** To resolve Yandex Cloud subjects you must hold at least the
> **`organization-manager.viewer`** role on the *target organization*. Without it, the
> `yc organization-manager user list` / `group list` calls fail with a `PermissionDenied`
> error and nothing resolves. If you hit that, ask an organization admin to grant you
> **`organization-manager.viewer`** (or a higher Organization Manager role) on that org —
> do not work around it.

## When to use

- Filling `rls2` for a dataset and you only have logins / emails / group names.
- Migrating an existing dataset from the legacy `rls` text config to `rls2`.

## Two modes

| Mode | Input | Output |
|------|-------|--------|
| `resolve` | subject names (logins, emails, group names) | `rls2` `subject` objects + unresolved list |
| `convert` | a legacy `rls` config `{field_guid: "text"}` | the full exact `rls2` config `{field_guid: [rules]}` |

## Subject input format

| Subject | Input form |
|---------|------------|
| user | login or email as-is |
| group | `@group:<group name>` |
| service account | `@sa:<service-account id>` |
| all rows | `*` |
| source-level user id | `userid` |

Normalize explicit group names and service-account IDs before invoking the tool. If the user says
"group Analysts", pass `@group:Analysts`. If the user supplies service-account ID `aje123`, pass
`@sa:aje123`; do not look it up as a user or ask for the same ID again.

## Prerequisites

- Python 3.9+ (standard library only — no `pip install`).
- The `yc` CLI installed and authenticated (IAM-token session — OAuth Yandex ID is
  deprecated for YC). Auth is handled below, by you.
- **At least the `organization-manager.viewer` role on the target organization** (see the
  ⚠️ warning above) — required to list users/groups.

## Authenticate `yc` — YOU run these checks; never expose the token

Run these yourself with the Bash tool and read **only the exit code**:

1. Is `yc` installed? — `command -v yc`
2. Is the session valid? — `yc iam create-token >/dev/null 2>&1`
   - exit 0 → authenticated; continue.
   - non-zero → re-authenticate (below).

The `>/dev/null 2>&1` on step 2 is **mandatory**: `yc iam create-token` prints a live token,
and the redirect throws it away so it is never shown.

**NEVER run `yc config list`, `yc config get token`, or `yc iam create-token` without the
redirect** — they print the OAuth token / SA key into the transcript. Do not print, echo,
log, or store any token or key. (`yc config profile list`, which shows only profile names,
is fine if you need to check which profile is active.)

### Re-authenticate — drive it, don't hand the user a to-do list

If step 2 failed, re-auth yourself. **Do not use a plain OAuth token**: OAuth Yandex ID
tokens are not supported for IAM exchange (error `OAuth token … is not supported for IAM
token exchange`). Use one of these instead:

- **Federated SSO (default).** `yc init --federation-id <FEDERATION_ID>` authenticates via
  the org federation in the browser — not subject to the OAuth deprecation. If you don't
  already know the federation id, ask the user for it (YC console → **Organization →
  Federations**, or their cloud admin). Run `yc init --federation-id <FEDERATION_ID>` in an
  interactive terminal. If the current agent cannot complete the browser interaction, ask the
  user to run that one command locally, then continue automatically.
- **Service-account key.** If the user has an SA key file:
  `yc config set service-account-key <path>` (a path, not a secret).

Then re-check `yc iam create-token >/dev/null 2>&1` and proceed. Do **not** stop and dump a
list of manual steps — drive the flow, and only hand off the single interactive browser step.

## Organization id — YOU fetch it

Run `yc organization-manager organization list --format json`.
- Exactly one org → use its `id`.
- Several → ask the user which one.

## Run the resolver — YOU run it, then present the result

Do **not** tell the user to "then run the resolver". You invoke the tool via Bash yourself
and show them the output.

```bash
# resolve names
python3 scripts/rls_tool.py resolve --org-id <ORG_ID> alice@example.com "@group:Analysts" bob

# convert a legacy rls config -> full rls2 (rls JSON on stdin, or --input FILE)
python3 scripts/rls_tool.py convert --org-id <ORG_ID> --input old_rls.json
```

Names may be comma / newline / semicolon separated (not space — cloud group names can
contain spaces). Prefix groups with `@group:` and service accounts with `@sa:`. If the tool
prints an auth error (the `yc` session lapsed mid-run),
re-authenticate as above and retry — automatically, without asking the user to intervene.

## Output shape

`convert` prints exactly what the backend stores:

```json
{
  "<field_guid>": [
    {"subject": {"subject_id": "aje1234...", "subject_name": "alice@example.com", "subject_type": "user"},
     "allowed_value": "Philadelphia", "pattern_type": "value"}
  ]
}
```

Subject id details and the `yc` calls are in [references/id-formats.md](references/id-formats.md).

## Common mistakes

- **Leaking the token.** Never run `yc config list` / `yc config get token`. Check auth
  only via `yc iam create-token >/dev/null 2>&1` (exit code).
- **Handing work to the user.** Drive `yc init` and run the resolver yourself; don't tell
  the user to do it.
- **Sending both `rls` and `rls2`.** The backend rejects a dataset with both set — send
  only `rls2`.
- **Cross-installation ids.** Yandex Cloud ids (cloud subject id / org group id) are not valid on
  other DataLens installations.
- **Unresolved subjects.** In `convert`, they are emitted as `notfound` (never dropped) and
  summarized; fix the name and re-run rather than shipping a `!FAILED_` entry. In `resolve`,
  they are listed under `unresolved`.

## Verify the transform

`python3 tests/test_rls_tool.py` runs offline logic tests (parser, normalization,
resolution assembly) whose expected `rls2` values mirror the backend.
