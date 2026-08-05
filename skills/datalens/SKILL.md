---
name: datalens
description: >-
  Start here for Yandex DataLens when the task has not yet settled on a tool, or when the question
  is about DataLens itself rather than about carrying something out in it: what DataLens is and
  what it can do; which installation is in play — Yandex Cloud, on-premise, or the internal Yandex
  one — and how they differ in auth, endpoints, and capabilities; what a collection, workbook,
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

[DataLens](https://datalens.tech) is a business intelligence and data visualization system: it
connects to databases, models the data into datasets, and renders charts and dashboards on top of
them. It is open source, offered as a managed service in Yandex Cloud, deployed on-premise, and run
internally at Yandex.

This file orients and routes. It does not teach any one interface — pick the interface below and
follow the skill that owns it.

## Object model

Everything is an entry in a hierarchy, and entries form a dependency chain:

```
collection / workbook        ← where entries live
    connection               ← credentials for a database
      └── dataset            ← fields, calculations, joins, parameters, RLS
            └── chart        ← wizard (dataset-backed) | QL (raw SQL) | editor (custom JS)
                  └── dashboard   ← tabs, widgets, selectors, layout
```

You build left to right, and reference by id. A chart needs a dataset (or, for QL, a connection); a
dashboard references charts. Deleting upstream breaks downstream.

## Installations

**Never assume which one is in play** — auth, endpoints, and available connectors and chart types
all differ. Establish it before writing anything that talks to an API.

| Installation | Where | Auth | Notes |
|---|---|---|---|
| **Yandex Cloud** | `datalens.yandex.com` / `.ru` | `yc` CLI IAM token, plus an organization id | The managed service |
| **On-premise** | a customer's own base URL | deployment-specific; commonly an OAuth token in the environment | Open-source self-host (`docker compose`, UI on `:8080`) and the commercial enterprise build both live here |
| **Internal Yandex** | internal host | internal | See *Installation overlays* below |

Tool-specific skills detect the installation for you — the SDK, for instance, ships a preflight
that reports it. Do not hand-roll detection.

## Choosing an interface

| Want to | Use | Skill |
|---|---|---|
| Manage entities from Python — create, update, inspect, export, clone | **Python SDK** (`datalens-sdk` on PyPI) | `datalens-sdk` |
| Let an agent call the DataLens API directly through tools | **MCP server** ([`@datalens-tech/mcp`](https://github.com/datalens-tech/datalens-mcp)) | — see its README |
| Build a standalone HTML page or report that DataLens renders | its sandboxed HTML page runtime | `datalens-html-pages` |
| Anything else programmatic | the public HTTP API | — |
| Explore, click around, look at a rendered chart | the web UI | — human work, not agent work |

**SDK vs MCP.** The SDK is the default for anything scripted, repeatable, or committed to a
repository — it is typed, it has a documented object model, and the work survives as code. The MCP
server suits interactive one-offs inside an agent session: it fetches the API's OpenAPI spec at
startup and exposes a three-tool gateway (`list_commands` → `describe_commands` →
`invoke_command`) instead of hundreds of tools. Do not mix them for one task.

**Neither, for raw HTTP.** If a skill covers the interface, use it rather than hand-building
requests against the API.

## Installation overlays

Installation-specific detail may be extended by a skill distributed separately — for the internal
Yandex installation, `datalens-yateam`. If it is present in the available skills list and the
environment targets that installation, invoke it: it adds and overrides installation-specific
detail from this file, and it wins where the two disagree.

If it is not available, do not reconstruct its content. Say which part of the answer is
installation-dependent and stop there.

## Out of scope

State the boundary and stop rather than improvising an adjacent solution:

- What a metric *means* for the business, or whether a number looks right.
- Screenshotting or driving the web UI.
- Embedding DataLens in another product, or iframes.
- SQL and analysis that does not touch DataLens entities.
