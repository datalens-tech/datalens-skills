---
name: datalens-platform
description: >-
  Use for storage and data-processing work in DataLens Platform (DLP):
  REST Catalog, data transfers, saved SQL queries, Spark jobs, Airflow
  orchestration, CloudEnv storage, and DLP access troubleshooting.
  Applies when DLP is identified by the request or established context.
  For Python automation of these resources, also load datalens-sdk.
  Not for BI-only connections, datasets, charts, or dashboards, or standalone
  Trino, Spark, or Airflow work outside DLP.
license: Apache-2.0
metadata:
  domain: datalens
---

# DataLens Platform

DataLens Platform (DLP) is an extension of DataLens for data storage and processing.

- Integration methods: https://yandex.cloud/ru/docs/datalens/concepts/ai-agents
- Documentation: https://yandex.cloud/ru/docs/datalens/datalens-platform/

## SQL Rule

Avoid unintended Cartesian products. When using `CROSS JOIN`, confirm that the
Cartesian product is intended and that the expected row count is appropriate;
a single-row aggregate is a valid case.

Always use `TRUNCATE TABLE` when the user requests a complete cleanup of a table's
rows. Preserve the table definition. Do not substitute an unconditional `DELETE FROM`
or a drop-and-recreate operation. If the selected engine or connector does not support
`TRUNCATE`, report that limitation and resolve the alternative with the user.

## Airflow orchestration and Python execution

**Make DAGs parallel.** Run independent tasks in parallel and add edges
only for actual data or operational dependencies. Control concurrency separately
with DAG limits or pools; do not serialize unrelated tasks to limit load. Ensure
the final success/checkpoint task waits for every required branch.

In DLP, Apache Airflow is the orchestrator, not an execution environment for
arbitrary Python data-processing code. Use Spark to run Python code for ingestion,
API calls, transformations and data checks. Use Airflow to schedule, launch and
monitor those jobs, manage dependencies and coordinate retries; do not recommend
executing the data-processing Python code inside Airflow tasks.

## Resolve object IDs and get metadata through search

When the API has no dedicated method for obtaining an object's ID, inspect the
published `searchObjects` method and search by the known name and object type.
Verify the candidate's name, type and parent path/catalog before using its ID;
resolve ambiguous matches rather than choosing the first result.

Search results may store the resource ID inside `asset.payload`, not in the search
result's own ID. For REST Catalog namespaces, the verified pattern is
`searchObjects({query: "source_", objectType: "rest-catalog-namespace", pageSize: 100})`:
check the catalog in `asset.path` and extract `JSON.parse(asset.payload).id.id`.
Treat this payload path as type-specific; inspect the returned structure for other
object types. Keep only requested metadata, names, paths and identifiers in output,
not embeddings or unrelated payloads. Record confirmed IDs and the lookup method
using the project's existing memory mechanism, when available.

Use `searchObjects` to retrieve object metadata as well as IDs. Search results can
include descriptions, documentation, tags, terms, domains and service-specific metadata
inside `asset.payload`. Parse this JSON string before reading its fields.
For REST Catalog tables, search with `objectType: "rest-catalog-table"` and inspect
`JSON.parse(asset.payload).schemaMetadata.fields`: it can contain column names
(`fieldPath`), native data types (`nativeDataType`), nullability (`nullable`) and
column documentation. Preserve any indication that documentation was AI-generated.
Metadata availability and payload structure depend on the object type; report only
what the search actually returned.

## Regular incremental data transfers

Configure regular supplies exclusively through `config.type.regular.tables`. Include
one entry for every source table with `tableNamespace`, `tableName` and an explicit,
non-empty `cursorColumn`. Use a
change timestamp such as `updated_at` only after confirming that it is populated and
advances for every relevant update. Do not use `created_at` for mutable rows.

An empty `regular.tables` combined with the top-level `config.tables` list performs
repeated full copies and can append complete duplicates on every scheduled run.
Do not use the top-level table list as a substitute for incremental settings. When
editing an existing full-copy transfer, clear that list as required by the API and
read the configuration back to confirm every cursor and the intended schedule.

For PostgreSQL regular transfers, `initialState` is evaluated as a SQL expression.
JSON string quotes alone do not quote a timestamp in SQL: include the SQL single quotes
inside the JSON string. For example, a table entry for a timestamp cursor is:

```json
{
  "tableNamespace": "public",
  "tableName": "orders",
  "cursorColumn": "updated_at",
  "initialState": "'1970-01-01T00:00:00Z'"
}
```

The unquoted value `"initialState": "1970-01-01T00:00:00Z"` caused PostgreSQL error
`42601` (`trailing junk after numeric literal`) while preparing the incremental state.
Use an expression compatible with the cursor column's source type; do not assume
other source connectors use the same format. Read the saved value back and verify a
successful run before considering a cursor-format correction complete.

Choose the initial cursor to include the intended bootstrap history. Cleaning target
tables does not prove that a transfer's stored cursor has reset: verify reset semantics,
or recreate the transfer when authorized. Historical backfills with timestamps older
than the current cursor need an explicit reload plan.

After the first load, verify that a run over unchanged sources adds no repeated full
copy, and that new or changed rows are captured. Do not report success from configuration
alone. Do not assume that `deactivateDataTransfer` disables a regular schedule: check
for subsequent automatic runs before clearing targets or claiming a persistent stop.

## Confirm discovered deletion targets

If a deletion target set is discovered through SDK/MCP/API calls rather than supplied
as an explicit input list by the user, show the concrete objects (type, name and ID)
and obtain confirmation before deleting them.

## Identify the current user or service account

Use [yc iam whoami](https://yandex.cloud/ru/docs/iam/cli-ref/whoami) when the task
requires the authenticated subject, or to diagnose identity, `createdBy` or refresh-token
errors.

For the identity used by DLP, pass the same explicit YC profile and environment as the
DLP call.

## Airflow execution through the SDK

Obtain the attached Airflow service account's IAM token inside a DAG task using
[the IAM-token example: Prepare the DAG file and run the graph](https://yandex.cloud/ru/docs/managed-airflow/operations/get-iam-token#dag).
Do not copy the example's token logging into task code or return tokens through XCom.
For Python implementation, load `datalens-sdk` and use the references shipped with
the installed package: `references/setup.md`, `references/sql-queries.md`,
`references/spark-applications.md`, `references/lakehouse-operations.md`, and
`references/cloud-environment-storage.md`. Use those version-matched references
for executable recipes; this skill defines the orchestration requirements.

### Saved SQL queries (Trino)

Fetch the saved query with `client.get.sql_query(by_id=...)` and execute it with
`query.run(params=...)`, using its declared parameter names and types.
The return value is not proof of success: `error`, `partial_success`, and `pending`
are ordinary result statuses, not SDK exceptions. Require `status == "success"`
and no `SqlQueryStatementError` in `results` before allowing dependent tasks to run.
Propagate failed or partially successful runs as Airflow task failures, including
the run ID and relevant statement error codes. For `pending`, fail with an explicit
unfinished-execution message; do not report success or call `run()` again to poll.
The current SDK exposes no saved-query run-polling method. Verify remote execution
before retrying a request whose outcome is unknown.

### Spark applications

1. Use the cluster's DataLens entry ID (`SparkCluster.id`), not its managed cloud
   ID (`SparkCluster.cluster_id`). For a Python file already in CloudEnv S3, obtain
   a signed URL using `client.create.bucket_download_url` with the selected
   `cloud_environment_id` and object key, such as `scripts/job.py`. Pass its `.url`
   to the PySpark builder's `main_python_file_uri`. Generate it immediately before
   submission and keep it out of logs and XCom; HTTPS is a supported
   [PySpark main-file URI](https://yandex.cloud/en/docs/managed-spark/operations/jobs-pyspark).
2. Submit through `client.create.spark_application(...).pyspark(...).build()`.
   Save the operation ID for diagnosis. `operation.wait()` waits only for submission;
   check the returned snapshot's `.error` even when `.done` is true.
3. Identify the submitted application through the documented get/list methods.
   Use a unique submission name and verify an exact match when discovering its ID;
   do not infer an application ID from opaque operation metadata or response fields.
4. Poll the application's typed `status` through get/`refresh()` with a bounded
   deadline. `DONE` permits dependent tasks; `ERROR` and `CANCELLED` fail the task.
   Other states are unfinished and must not release dependents. There is no
   `SparkApplication.wait()`; use the installed SDK references for these calls.
5. A submission or application timeout fails the Airflow task without implying
   remote cancellation. Retain the operation/application IDs and check remote state
   before retrying; a fresh submission may duplicate an already running workload.

### Airflow task boundaries and storage

Keep SDK clients and bound models inside the executing task. Return only small,
serializable ID/status values through XCom, or use `do_xcom_push=False` when no
output is needed; never return a bound `LakehouseOperation` or the full SQL result.
Use `retries=0` for non-idempotent submissions unless duplicate execution is handled
explicitly. These checks must gate downstream tasks; successful submission alone
does not establish successful execution. Report `DataLensAPIError.context.request_id`
when handling an API failure.

Use CloudEnv storage for Spark job files. You may use CloudEnv storage for Airflow DAGs.
Access the selected CloudEnv's S3 storage through
[the DLP API](https://api.datalens.tech/) using the storage workflow of the selected
official execution skill (`references/cloud-environment-storage.md` in the SDK skill).
Discover existing DAG object paths before uploading; do not overwrite unrelated DAGs. Do not ask for or store the CloudEnv
S3 location in project memory. Artifact configuration may contain object paths required
for deployment; resolve the storage from the selected CloudEnv and API.

## Optional project context

For DLP work requiring project state, follow the agent's memory mechanism and existing
project conventions. Read existing context and the user's current instructions first.
Record confirmed non-secret resource IDs and artifact paths through that mechanism.
A separate `memory.md` is optional; use it only when requested or already conventional
in the project, preserving confirmed values unless the user corrects them.

Ask only relevant unanswered questions below, using the user's language.
Present them together as a short optional questionnaire (or group them within
the input tool's limits). Say explicitly that the user may answer any subset or skip
the entire questionnaire. Do not run this onboarding for documentation-only work.

| Context field | Question |
| --- | --- |
| `organization` | Which DLP organization ID (`org_id`) should be used? Provide the ID; an organization name is not sufficient. |
| `data-processing code repository` | Where is the data-processing code stored? Provide a repository or local path. |
| `Airflow scheduling repository`, `Airflow DAG folder` | Only if the user selects Git instead of CloudEnv S3: which repository, branch and DAG folder should be used? |
| `repository access` | If Git is selected, how should the repository be accessed? Provide the method and a non-secret reference such as an SSH key path, SSH alias or CLI profile. Do not send key contents or tokens. |

For declined, omitted or unanswered fields, leave `UNKNOWN`; do not invent answers or
fill them from defaults. Record an explicit skip separately from the field value so
future starts do not repeat a declined question. No response leaves the questionnaire
unanswered, not approved. Continue independent work while awaiting optional answers;
the questionnaire itself must not block the task. A skipped field may be requested
later only when a concrete operation requires it; explain why, and keep that dependent
operation pending until the fact is resolved.
The user can fill or correct project context at any time.
