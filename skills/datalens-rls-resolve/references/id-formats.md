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
  `yc organization-manager user list --organization-id <ORG> --format json`,
  match `subjectClaims.preferredUsername` / `subjectClaims.email`; the subject id is
  `subjectId` (= `subjectClaims.sub`). There is no server-side login/email filter on the
  list call, so the tool lists members and matches client-side. (A login-only fast path
  exists via `yc organization-manager oslogin profile list --filter "login=<login>"`.)
- **Group** — name → org group id:
  `yc organization-manager group list --organization-id <ORG> --format json`,
  match `name` → `id`.

## Caveats

- **`subject_name` is display-only.** The exact stored form for a group in cloud
  (`group:<name>` vs the `@group:<name>` the user typed) is not fixed in public docs;
  correctness depends only on `subject_id`, so the tool keeps the readable input form.
- **Never expose credentials.** Auth is checked via `yc iam create-token >/dev/null 2>&1`
  (exit code only); `yc config list` / `yc config get token` would print the token/key and
  must not be run.
- **Cross-installation ids are not interchangeable** with other DataLens installations.
- Backend reference for the rls2 shape / semantics: `mainrepo/lib/dl_rls`,
  `dl_api_lib … dataset_loader.py`.
