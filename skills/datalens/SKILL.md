---
name: datalens
description: >-
  Start here for Yandex DataLens and DataLens Platform (DLP) when the task has not yet settled on a tool, or when the question
  is about DataLens itself rather than about carrying something out in it: what DataLens is and
  what it can do; which installation is in play — Yandex Cloud, on-premise, or the internal Yandex
  Team one — and how they differ in hosts, auth, and capabilities; what a collection, workbook,
  connection, dataset, chart, or dashboard is and how they relate; and whether to reach for the MCP
  server, the Python SDK, the HTTP API, or the web UI. Use it to orient and to route to the skill
  that does the work. NOT for doing the work once the approach is chosen — that is `datalens-sdk`
  for Python and `datalens-html-pages` for standalone HTML reports — and not for interpreting what
  business metric values mean.
  Also use for DLP storage and processing: catalogs, transfers, Trino, Spark, and Airflow.
license: Apache-2.0
metadata:
  domain: datalens
---

# DataLens

[DataLens](https://datalens.ru) is a business intelligence and data visualization system: it connects to databases, models the data into datasets, and renders charts and dashboards on top of them. It is offered as a managed service in Yandex Cloud, deployed on-premise, and run internally at Yandex.

This file orients and routes. It does not teach any one interface — pick the interface below and follow the skill that owns it.

## Data flow

```
database → connection → source → dataset → chart → dashboard
```

- **connection** — credentials and driver for one database.
- **source** — a table or a SQL query exposed by that connection.
- **dataset** — the modelling layer: fields, calculated fields, joins, parameters, row-level
  security.
- **chart** — one visualization. *Wizard* charts sit on a dataset; *QL* charts skip the dataset and
  query a connection directly; *editor* charts are custom JavaScript.
- **dashboard** — tabs, widgets, selectors, and layout over charts.

Build left to right and reference by id. Deleting upstream breaks everything downstream.

## Object IDs and URLs

DataLens URLs for objects with an explicit type can use either of these forms:

- `/<object_type>/<object_id>-<readable_slug>` — pass only the object ID before the readable
  suffix to the API.
- `/<object_type>/<object_id>` — when the readable suffix is absent, the entire final path segment
  is the object ID.

Dashboard links have an additional short form: `https://datalens.ru/<dashboard_id>`. When the URL
is identified as a dashboard link, the only path segment is the dashboard ID; there is no object
type segment. For example, `https://datalens.ru/bgquq1234567` refers to dashboard ID
`bgquq1234567`.

For an explicitly typed object, `https://datalens.ru/connections/r6wa2j1ww5cad-demo` refers to the connection ID
`r6wa2j1ww5cad`; `demo` is a human-readable URL suffix. If the URL is
`https://datalens.ru/connections/r6wa2j1ww5cad`, use the same complete segment as the ID. The same
rule applies to connections, datasets, and charts. Do not apply the root-level short form to those
object types.

Treat object IDs as opaque values. Prefer the value from `Copy ID` or the API response's `id`
field when available. If a URL is ambiguous or does not match these forms, do not guess the ID.
Do not confuse an object ID with a display name, readable URL suffix, or a field UUID.

## Object model

Where entries are filed — a separate axis from the flow above. Connections, datasets, charts, and
dashboards are all *entries*, and entries live in a container tree. Two schemes exist, and which
one is available differs per installation:

```
newer    collection
           ├── collection …            nested, arbitrarily deep
           └── workbook
                 └── entries           connection, dataset, chart, dashboard

older    folder tree, path-addressed   e.g. Users/someone/reports
           └── entries                 held directly, no workbook in between
```

The workbook is the unit of grouping and permissions in the newer scheme; the folder path plays
that role in the older one. **Never assume which is available** — an installation may offer one,
the other, or both, so establish it the way the interface skill tells you rather than writing
path-based logic against a workbook-only deployment.

## Installations

**Never assume which one is in play** — hosts, auth, and the available connectors and chart types
all differ. Establish it before writing anything that talks to an API.

| Installation | UI | API host | Auth |
|---|---|---|---|
| **Yandex Cloud** | `datalens.ru` | `api.datalens.tech` | `yc` CLI IAM token, plus an organization id |
| **On-premise** | ask the user | ask the user | deployment-specific; commonly an OAuth token in the environment |
| **Yandex Team** (internal) | `datalens.yandex-team.ru` | `api.datalens.yandex.net` | internal |

**Yandex Cloud** is the managed service. **On-premise** covers both the open-source self-host
(`docker compose`, UI on `:8080`) and the commercial enterprise build. **Yandex Team** is the
internal Yandex installation — see *Installation-specific detail* below before answering anything
specific to it.

Tool-specific skills detect the installation for you — the SDK, for instance, ships a preflight
that reports it. Do not hand-roll detection.

## Choosing an interface

| Want to | Use | Skill |
|---|---|---|
| Manage entities from Python — create, update, inspect, export, clone | **Python SDK** (`datalens-sdk` on PyPI) | `datalens-sdk` |
| Let an agent call the DataLens API directly through tools | **MCP server** ([`@datalens-tech/mcp`](https://github.com/datalens-tech/datalens-mcp)) | — see its README |
| Anything else programmatic | the public HTTP API | — see below |
| Explore, click around, look at a rendered chart | the web UI | — human work, not agent work |

**SDK vs MCP.** The SDK is the default for anything scripted, repeatable, or committed to a
repository — it is typed, it has a documented object model, and the work survives as code. The MCP
server suits interactive one-offs inside an agent session: it fetches the API's OpenAPI spec at
startup and exposes a three-tool gateway (`list_commands` → `describe_commands` →
`invoke_command`) instead of hundreds of tools. Do not mix them for one task.

**The HTTP API, when neither fits.** The SDK and the MCP server are both built on it, so reach for
it directly only where they fall short. It is an HTTP API in an RPC style rather than a REST one:
you call named commands with JSON payloads, not resources. It is also self-describing — fetch the
OpenAPI spec from `/json/` on the installation's API host (*Installations* above;
`https://api.datalens.tech/json/` on the cloud) and work from the spec rather than guessing command
names or payload shapes. On the cloud the organization id is required, sent as an `x-dl-org-id`
header.

## Installation-specific detail

Two installations withhold something you need, and in both cases the answer is to ask rather than
to fill the gap yourself.

**Yandex Team** is extended by a skill distributed separately, `datalens-yateam`. If it is present
in the available skills list and the environment targets that installation, invoke it: it adds and
overrides installation-specific detail from this file, and it wins where the two disagree. If the
task concerns Yandex Team and the skill is *not* in the list, stop and ask the user to install it,
following the instructions at <https://datalens.yandex-team.ru/get-skills>. Do not reconstruct its
content in the meantime — say which part of the answer is installation-dependent and leave it
there.

**On-premise** publishes no endpoints, and the API does not necessarily sit on the UI's host. Stop
and ask the user for both — the DataLens endpoint and the DataLens API endpoint — before writing
anything that talks to either. Do not derive one from the other, do not fall back to a cloud
default, and do not carry on with a placeholder.

## Out of scope

State the boundary and stop rather than improvising an adjacent solution:

- What a metric *means* for the business, or whether a number looks right.
- Screenshotting or driving the web UI.
- Embedding DataLens in another product, or iframes.
- SQL and analysis that does not touch DataLens entities.

# DataLens Platform instructions

DataLens Platform (DLP) is an extension of DataLens for data storage and processing.

- Integration methods: https://yandex.cloud/ru/docs/datalens/concepts/ai-agents
- Documentation: https://yandex.cloud/ru/docs/datalens/datalens-platform/

For work requiring project state, use `memory.md` in the actual working project.
Read existing memory. Ask only for facts needed now.
Record confirmed non-secret resource IDs, environment and artifact paths in memory;
append outcomes to the session log. No inter-agent task/result/status files are needed.

## SQL Rule

Never use `CROSS JOIN`. This prohibition also applies to a join with a single-row
aggregate. You can use `CROSS JOIN` only when you create test data.

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
in project memory.

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
errors. The bundled helper prints only the subject returned by YC.

For the identity used by DLP, pass the same explicit YC profile and environment as the
DLP call.

## Airflow Trino and Spark task run, service account, DAG storage and status

Obtain the attached Airflow service account's IAM token inside a DAG task using
[the exact IAM-token example: Prepare the DAG file and run the graph](https://yandex.cloud/ru/docs/managed-airflow/operations/get-iam-token?utm_referrer=about%3Ablank#dag).
Do not copy the example's token logging into task code or return tokens through XCom.
The following are examples of calls through the official Python SDK `datalens-sdk`.
Both examples take a `DataLensClientYC` instance
configured with `StaticYCIAMAuthProvider(org_id=org_id, token=iam_token)`.
Obtaining the IAM token is the DAG's responsibility.

Trino: execute an existing saved SQL query whose connection targets Trino.
The saved query declares `SqlQueryParameter.date("report_date")` and uses
`{{report_date}}`, for example `WHERE partition_date = {{report_date}}`.
Pass the date as a `YYYY-MM-DD` string.

```python
def run_trino_sql(client, query_id, report_date):
    query = client.get.sql_query(by_id=query_id)
    return query.run(params={"report_date": report_date})
```

Spark: obtain a download URL for a Python file already uploaded to CloudEnv S3
and submit it. `object_path` is the object's key, for example `scripts/job.py`;
`lakehouse_id` is the Spark cluster's Lakehouse ID (`SparkCluster.id`).

```python
def run_spark_python(client, lakehouse_id, cloud_environment_id, object_path):
    python_file_uri = client.create.bucket_download_url(
        cloud_environment_id=cloud_environment_id, path=object_path
    ).url
    return (
        client.create.spark_application(cluster=lakehouse_id, name="python-job")
        .pyspark(main_python_file_uri=python_file_uri)
        .build()
    )
```

`python_file_uri` is a temporary signed HTTPS URL to the S3 object, a supported
[PySpark main-file URI](https://yandex.cloud/en/docs/managed-spark/operations/jobs-pyspark).
Generate it immediately before each submission and do not log it.
The Spark call returns a submission operation; it does not wait for the Python
application to finish.

Airflow's S3 storage is the S3 storage of the selected CloudEnv. Access it through
[the DLP API](https://api.datalens.tech/) using the storage workflow of the selected
official execution skill (`references/cloud-environment-storage.md` in the SDK skill).
Discover existing DAG object paths before uploading; do not overwrite unrelated DAGs. Do not ask for or store the CloudEnv
S3 location in project memory. Artifact configuration may contain object paths required
for deployment; resolve the storage from the selected CloudEnv and API.

## Optional startup questions for memory

At the start of DLP work requiring project state, read existing memory and the user's
current instructions first. Ask only the unanswered questions below, using the user's
language. Present them together as a short optional questionnaire (or group them within
the input tool's limits). Say explicitly that the user may answer any subset or skip
the entire questionnaire. Do not run this onboarding for documentation-only work.

| Memory field | Question |
| --- | --- |
| `organization` | Which DLP organization ID (`org_id`) should be used? Provide the ID; an organization name is not sufficient. |
| `data-processing code repository` | Where is the data-processing code stored? Provide a repository or local path. |
| `Airflow scheduling repository`, `Airflow DAG folder` | Only if the user selects Git instead of CloudEnv S3: which repository, branch and DAG folder should be used? |
| `repository access` | If Git is selected, how should the repository be accessed? Provide the method and a non-secret reference such as an SSH key path, SSH alias or CLI profile. Do not send key contents or tokens. |

Save non-secret answers in the working project's `memory.md`, creating the file and
adding missing fields when needed. Preserve existing confirmed values unless the user
corrects them.

For declined, omitted or unanswered fields, leave `UNKNOWN`; do not invent answers or
fill them from defaults. Record an explicit skip separately from the field value so
future starts do not repeat a declined question. No response leaves the questionnaire
unanswered, not approved. Continue independent work while awaiting optional answers;
the questionnaire itself must not block the task. Apply the same optional-answer rules
to the environment and profile questions supplied through `dlp-iam-token`. A skipped field may be requested later only when a concrete operation requires
it; explain why, and keep that dependent operation pending until the fact is resolved.
The user can fill or correct memory at any time.
