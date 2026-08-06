---
name: datalens
description: >-
  Start here for Yandex DataLens when the task has not yet settled on a tool, or when the question
  is about DataLens itself rather than about carrying something out in it: what DataLens is and
  what it can do; which installation is in play — Yandex Cloud, on-premise, or the internal Yandex
  Team one — and how they differ in hosts, auth, and capabilities; what a collection, workbook,
  connection, dataset, chart, or dashboard is and how they relate; and whether to reach for the MCP
  server, the Python SDK, the HTTP API, or the web UI. Use it to orient and to route to the skill
  that does the work. NOT for doing the work once the approach is chosen — that is `datalens-sdk`
  for Python and `datalens-html-pages` for standalone HTML reports — and not for interpreting what
  business metric values mean.
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
| **On-premise** | the deployment's own host | the same deployment | deployment-specific; commonly an OAuth token in the environment |
| **Yandex Team** (internal) | `datalens.yandex-team.ru` | `api.datalens.yandex.net` | internal |

**Yandex Cloud** is the managed service. **On-premise** covers both the open-source self-host
(`docker compose`, UI on `:8080`) and the commercial enterprise build; it has no fixed host, so a
base URL is always required and nothing about endpoints can be assumed. **Yandex Team** is the
internal Yandex installation — see *Installation overlays* below before answering anything specific
to it.

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
it directly only where they fall short. It is self-describing: fetch the OpenAPI spec from `/json/`
on the installation's API host — `https://api.datalens.tech/json/` on the cloud — and work from the
spec rather than guessing endpoint names or payload shapes. On the cloud the organization id is
required, sent as an `x-dl-org-id` header.

## Installation overlays

Installation-specific detail may be extended by a skill distributed separately — for Yandex Team,
`datalens-yateam`. If it is present in the available skills list and the environment targets that
installation, invoke it: it adds and overrides installation-specific detail from this file, and it
wins where the two disagree.

If the task concerns Yandex Team and `datalens-yateam` is *not* in the list, stop and ask the user
to install it, following the instructions at <https://datalens.yandex-team.ru/get-skills>. Do not
reconstruct its content in the meantime — say which part of the answer is installation-dependent
and leave it there.

## Out of scope

State the boundary and stop rather than improvising an adjacent solution:

- What a metric *means* for the business, or whether a number looks right.
- Screenshotting or driving the web UI.
- Embedding DataLens in another product, or iframes.
- SQL and analysis that does not touch DataLens entities.
