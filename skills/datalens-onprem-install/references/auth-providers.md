# External authentication providers (LDAP / OIDC)

DataLens On-premises can delegate login to an external IdP: **LDAP** and **OIDC** (OpenID
Connect). SAML is not supported. Providers are configured as a JSON array and passed to the
install — there is no per-provider feature flag.

Docs (the `/en/` page for this section may 404 — use `/ru/`):
https://datalens.ru/on-premises/docs/ru/concepts/auth-providers/

## How it's wired

- **`--auth-providers-config <path>`** — the init.sh flag that points to a JSON file with the
  provider array. A template ships in the distributive at
  `./help/auth-provider-config.example.json`. Under the hood it becomes
  `secrets.AUTH_PROVIDERS_CONFIG` (env `AUTH_PROVIDERS_CONFIG`), a JSON string.
- The auth service is on by default (`features.auth.enabled`); its RSA keys are generated
  automatically (`--auth-rsa-gen`) on first deploy.
- Login behavior (`features.auth.*`, set via values):
  - `local` — local users. Disable to allow login **only** through external IdP providers.
  - `skip_local` — skip the local-login step (no effect if the IdP array is empty).
  - `force_redirect_open_id` — redirect straight to OpenID when `skip_local=true`, there is no
    LDAP provider, and exactly one OIDC provider is configured.

The config file holds bind credentials / client secrets — treat it as a **secret** (`600`
permissions, do not commit).

## Config shape

A JSON array; each element is one provider:

```json
[
  {
    "slug": "openldap",
    "title": "OpenLDAP",
    "type": "ldap",
    "defaultRole": "datalens.visitor",
    "config": { }
  }
]
```

### LDAP (`type: "ldap"`)

Key `config` fields (full list in the docs):

- Connection: `url` (`ldap://host:389` or `ldaps://host:636`), `bindDN`, `bindCredentials`,
  `bindProperty` (default `dn`).
- User search: `searchBase`, `searchFilter` (with `{{username}}`, e.g. `(uid={{username}})`),
  `searchScope` (`base` / `one` / `sub`).
- Group search (optional): `groupSearchBase`, `groupSearchFilter` (with `{{dn}}`),
  `groupDnProperty`, `groupSearchScope`.
- Attribute mapping (optional): `userId`, `login`, `email`, `firstName`, `lastName` (defaults
  `uid` / `uid` / `mail` / `givenName` / `sn`); group `groupId` (default `dn`), `title`
  (default `cn`).
- Roles: `roleToGroupId` maps DataLens roles to LDAP group ids; `syncUserRoles` / `syncUserGroups`
  (default `true`). Sync happens at login; if a user has >100 groups it is skipped — set up
  periodic sync (see the sync-IdP doc).

### OIDC (`type: "oidc"`)

Key `config` fields:

- `issuer` — the OIDC server base URL (its `.well-known/openid-configuration`).
- `clientId`, `clientSecret` — from the provider registration.
- `scope` — array, default `['openid', 'profile', 'email']`.
- `codeChallengeMethod` — PKCE, default `S256` (`null` to use `state`/`nonce` without PKCE).
- Register the callback `{UI_APP_ENDPOINT}/auth/callback/oidc` at the provider.
- Optional: `userAttributes`, `roles` (`path` / `targetType` / `mapping`), `groups`,
  `syncUserRoles` (default `true`), `syncUserGroups` (default `false`).

## Steps

1. Copy `./help/auth-provider-config.example.json`, fill in your provider(s). Keep the file `600`
   and out of version control (it holds secrets).
2. Apply it. At first install, add the flag to the stage-4 command; to add it to a running
   instance, re-run with the previous flags + this one (drop `--k3s-install`, add `--yes` — see
   "Speeding up a redeploy" in `flags.md`):
   ```bash
   ./init.sh --ingress-domain <domain> --ingress-tls --ingress-tls-gen \
     <previous feature flags> --auth-providers-config ./auth-providers.json --yes
   ```
3. For external-only login, set `features.auth.local: false` (and, for a single OIDC provider,
   `skip_local: true` + `force_redirect_open_id: true`).
4. Verify: open `https://<domain>` — the login page should offer the provider(s); an IdP user can
   log in and lands on `defaultRole` (or a role mapped from their group).

For the full field reference and worked examples, see the docs:
`ldap-config.html` / `ldap-examples.html`, `oidc-config.html` / `oidc-examples.html`, and
`sync-IdP.html` under https://datalens.ru/on-premises/docs/ru/concepts/auth-providers/
