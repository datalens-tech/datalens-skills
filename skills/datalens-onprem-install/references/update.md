# Mode: updating an installed instance

Activated only on an explicit request from the engineer ("update DataLens", "install the latest
version"). Do not offer updates proactively.

## 1. Determine the versions

- **Installed:** look in the distributive folder for a version file (e.g. `VERSION`) or the image
  versions in `.values.debug.yaml`; if it cannot be determined unambiguously — ask the engineer.
- **Latest:** with internet access — https://datalens.ru/on-premises/docs/en/changelog.html, the
  "Current version" section. Versions use a calendar format: YEAR.MONTH.PATCH (e.g. 26.7.0).
  Without internet — the engineer names the version.

If the versions match — there is nothing to update; say so and stop.

## 2. Breaking changes between versions

Review the "Backward-incompatible changes" blocks in the changelog for every version between the
installed and the target one. Known checkpoints (snapshot 2026-08):

| Version | What breaks |
|---|---|
| 25.11.0 | Redis replaced with valkey: when upgrading from ≤25.10.0, manually delete the Redis deployment and pvc; during the upgrade, loading new file connections is unavailable |
| 26.5.0 | A new `pg-aux-db` database with extensions (pg_trgm, btree_gin, btree_gist, uuid-ossp) is required: for embedded PG — init scripts after the upgrade; for external — create it beforehand |
| 26.6.0 | Notifications need three new databases (`pg-notify-db` and others), a similar manual procedure when upgrading from ≤26.5.1 |

Starting with 26.7.0, `./init.sh --update` determines the version itself and performs the required
migrations for Redis (when upgrading from <25.11.0) and embedded PostgreSQL (from <26.5.0); for
external PostgreSQL the migrations remain manual.

Checkpoint: show the engineer a summary of breaking changes along their upgrade path and get
confirmation.

## 3. Backup

Before the upgrade, offer a dump of the embedded PostgreSQL:

```bash
./init.sh --dump-postgres
```

See the dump path in the command output; advise copying it off the machine.

## 4. Download and unpack over the top

The engineer provides the link to the new archive (the DataLens cabinet):

```bash
curl -L "<url>" -o datalens-enterprise.tar
tar -xvf datalens-enterprise.tar --directory ./datalens-enterprise
```

Unpack **into the same folder, over the old version**.

## 5. Update and verify

From the distributive folder:

```bash
./init.sh --update --yes
```

`--yes` is required for a non-interactive run (background, ssh without a TTY) — otherwise `init.sh`
hangs on the helm-diff confirmation. This is a long operation — run it like install stage 5
(background / large timeout). When done, the same verification: `sudo k3s kubectl get pods -A` —
pods Running/Completed, the UI responds, login works.

Rollback on failure: `--restore-postgres` from the step-3 dump (`--restore-postgres-with-clear` —
with a wipe, apply only deliberately and with the engineer's confirmation).
