---
name: datalens-sdk
description: >-
  Use this skill for any Yandex DataLens automation task through the Python package
  `datalens-sdk`. Trigger on: DataLens, datalens, даталенс, chart, чарт, график, dashboard,
  дашборд, dataset, датасет, connection, подключение, workbook, воркбук, collection, коллекция,
  wizard chart, QL chart, editor chart, BI automation, автоматизация DataLens, "create a
  dashboard", "построй дашборд", "создай чарт", "export dataset", or "clone dashboard"; entity
  ids such as dataset_id, chart_id, dashboard_id, or workbook_id; and requests to create, update,
  inspect, import, export, copy, or diagnose DataLens objects with code. NOT for: business
  questions about metric values; viewing or screenshotting the DataLens web UI; embedding or
  iframes; raw SQL/YQL analysis that does not manage DataLens entities; raw HTTP API calls;
  standalone HTML pages or reports.
license: Apache-2.0
metadata:
  domain: datalens
---

# DataLens SDK

Operate Yandex DataLens through the official Python SDK — never hand-built HTTP requests.

**The instructions for this skill are stored inside the installed `datalens-sdk` package**, and are
extended there by whatever DataLens installation the environment targets. The SDK is a 0.x alpha
where minor releases rename classes and methods, so instructions that shipped separately would
describe an API the user does not have. Load them from the package before doing anything else.

## Load the instructions

Resolve the skill directories, preferring the project's interpreter (`.venv/bin/python`,
`uv run python`, `poetry run python`):

```bash
python -c "
import sys
try:
    import datalens_sdk
except ImportError:
    print('NOT_INSTALLED'); sys.exit()
for p in datalens_sdk.agent_skill_paths():
    print(p)
"
```

It prints one absolute path per line: the base instructions first, then any **installation
overlays** available in this environment. Extra lines are normal — they are additional detail for
particular DataLens installations, and not all of them necessarily apply here.

**Keep those absolute paths.** Each directory carries its own bundled scripts, examples, and
`references/` tree, referenced relative to it, and expects to be invoked by absolute path. Never
`cd` into one; the user's project directory stays the working directory throughout.

Read `SKILL.md` from the **first** path now and **follow it as if written here** — it is
authoritative and overrides anything you believe about this SDK, including anything in this file.
It owns installation detection: it decides which of the remaining paths apply and tells you when to
read them, so do not read an overlay before it says so. Where an overlay contradicts the base, the
overlay wins. Read the references they route you to on demand, not all of them.

Do not write SDK code, install anything, answer an SDK question, or commit to an approach before
you have read it. A plausible guess at this API is worse than one extra command.

## If it prints `NOT_INSTALLED`

The SDK is not installed in this environment. Do not answer from memory:

```bash
pip install datalens-sdk
```

Then start again from the step above. If the user is only asking what the SDK is or whether it
fits their task, answer that much from this file and stop — installing a package to read its
documentation is not worth it.

Anything that writes files writes to the user's project directory or a temp dir; the package
directory may be read-only or root-owned.

## Scope

| Task | Where it belongs |
|------|------------------|
| Anything driving DataLens entities from Python | here — load the package instructions above |
| Standalone HTML pages and reports rendered by DataLens | `datalens-html-pages` |
| The DataLens web UI, screenshots, embedding, metric interpretation | neither — say it is out of scope and stop |
