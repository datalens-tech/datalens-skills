# RLSv2 subject ids — formats and resolution (Yandex Cloud)

`subject_id` is authoritative (used for access checks). `subject_name` is display-only —
any readable value is safe; enforcement never re-resolves it.

## Subject id map

| Subject | `subject_type` | `subject_id` | `subject_name` |
|---|---|---|---|
| user | `user` | cloud `subjectId` (= `subjectClaims.sub`, e.g. `aje…`/`ssxiy…`) | login or email as typed |
| service account | `user` | id from `@sa:<id>` (passthrough) | `@sa:<id>` |
| group | `group` | org group `id` | `@group:<name>` |
| all | `all` | `*` | `*` |
| source-level (userid) | `userid` | `""` | `userid` |
| unresolved | `notfound` | `""` (user) / name (group) | `!FAILED_<input>` |

## Resolution (`yc` CLI — Cloud Organization Manager)

Auth: the `yc` CLI's own IAM-token session. Plain OAuth Yandex ID tokens are not supported for
IAM exchange — authenticate via federated SSO
(`yc init --federation-id <ID>`) or a service-account key (`yc config set service-account-key
<path>`). The tool never handles a token; the skill ensures `yc` is authenticated first.
Needs `--org-id`.

- **Org id:** `yc organization-manager organization list --format json` → `id`.
- **User** — login/email → cloud subject id:
  `yc organization-manager user list --organization-id <ORG> --limit <N> --format json`.
  Each member is an `OrganizationUser` whose **only** field is `subject_claims`; the subject id
  is **`subject_claims.sub`** — there is *no* top-level `subject_id`/`id` in the CLI output.
  There is no server-side filter, so the tool lists members and matches client-side, restricted
  to `sub_type == "USER_ACCOUNT"`, on `canonize(preferred_username)` and `canonize(email)`, where
  `canonize` lowercases and drops the default `@yandex.ru` suffix (mirrors the backend
  `_canonize_subject_name` + `_login_to_email`). The CLI returns `preferred_username` for every
  user account but `email` only sometimes, so `preferred_username` is the primary key. Resolution
  needs an exact, **unique** match — a name hitting zero or several subjects is left unresolved
  (never guessed).
- **Pagination:** `yc … user list` / `group list` default to `--limit 1000` and **silently
  truncate** larger orgs, so the tool passes a high `--limit` (the CLI auto-paginates up to it).
- **Group** — name → org group id:
  `yc organization-manager group list --organization-id <ORG> --limit <N> --format json`,
  match `name` exactly and take `id`, requiring **exactly one** match (the backend's
  `resolve_group_by_name` returns nothing on 0 or >1 rather than picking one). That `id` is the
  group's subject id stored in `rls2`.

## Caveats

- **`subject_name` is display-only.** For a group the backend keeps
  `subject_name = @group:<name>` with `subject_id = <org group id>` (confirmed in `dl_rls`); it
  can also resolve an unresolved group *slug* (where `subject_id == bare name`) on save.
  Correctness depends only on `subject_id`, so the tool keeps the readable input form.
- **Never expose credentials.** Auth is checked via `yc iam create-token >/dev/null 2>&1`
  (exit code only); `yc config list` / `yc config get token` would print the token/key and
  must not be run.
- **Cross-installation ids are not interchangeable** with other DataLens installations.
- Backend reference: rls2 shape/semantics in `mainrepo/lib/dl_rls` and
  `dl_api_lib … dataset_loader.py`; Yandex Cloud user/group resolution in
  `bi_service_registry_ya_cloud/iam_subject_resolver.py` and
  `bi_cloud_integration/yc_subject_details/` (there `subject_claims.sub` = rls2 `subject_id`).
