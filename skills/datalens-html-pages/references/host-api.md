# Host API: live data and shareable state (experimental)

A page can ask the DataLens host page to run a small set of DataLens API methods for it. This is
what turns a static report into a mini-app: filters that re-query a dataset, a table that pages
through a chart's data, a view the user can share by link.

> **Experimental, and off in production.** The host API sits behind a feature flag and is not
> enabled in production installations yet. Where it is off, or where the page was uploaded
> without permissions, every call is rejected. A page that uses it must still open and say
> something sensible when the calls fail.

## How it works

The sandbox does not change: the page still has no network access of its own. Instead it posts a
request to the host with `parent.postMessage`, the host runs the call through the DataLens UI
gateway **as the user who is viewing the page**, and posts the result back.

Consequences worth designing around:

- **Data follows the viewer, not the author.** Dataset and chart permissions, including RLS, are
  the viewer's. Two people opening the same page can see different rows, and a viewer without
  access to the dataset gets an error where the author saw data. Render that error.
- **Nothing is baked in.** The page holds entity ids and field GUIDs, not rows. Inline data only
  when the page must also work without the host API.
- **Calls are asynchronous and can be slow.** A dataset query takes from a fraction of a second
  to tens of seconds. Show a loading state; do not block rendering on the first response.

## Permissions

Each page carries its own list of allowed methods, set when the file is uploaded or replaced.
A method that is not on the list is rejected with `METHOD_NOT_ALLOWED`.

| Method | Allows |
|--------|--------|
| `getDatasetData` | querying any dataset the viewer can read |
| `getChartData` | reading the data of any saved chart the viewer can open |
| `getState`, `createState` | saving the page's own state and restoring it from a link |

- **In the UI:** the upload form has a checkbox per group; tick them before choosing the file.
- **Through the API:** pass `allowedApiMethods` to `createHtmlPage` / `updateHtmlPage`, for
  example `"allowedApiMethods": ["getDatasetData", "getState", "createState"]`. On update, omit
  the field to keep the current list; pass `[]` to revoke everything.

Ask for the methods the page actually calls and nothing more. Tell the user which ones the page
needs, because a page uploaded without them looks broken rather than unauthorized.

## The message protocol

Each request carries its own `MessagePort`, and the answer comes back on that port:

```js
const { port1, port2 } = new MessageChannel();
port1.onmessage = ({ data }) => { /* { result } or { error: { code, message, status } } */ };
parent.postMessage({ code: 'API_REQUEST', data: { method, args } }, '*', [port2]);
```

A request without a port gets no answer. The host answers only the frame it rendered and runs at
most 6 requests at a time for a page; a seventh is rejected with `TOO_MANY_REQUESTS`, so queue
requests rather than firing one per table cell.

**Use the bundled client** instead of writing this by hand: inline the contents of
[../assets/dl-host-api.js](../assets/dl-host-api.js) into the page's `<script>`. It pairs each
answer with its request, turns failures into rejected promises with a `code`, and times out when
nothing answers:

```js
const { rows } = await DataLens.getDatasetData({ datasetId, columns: [regionGuid, salesGuid] });
```

### Errors

| `error.code` | Meaning | What the page should do |
|--------------|---------|-------------------------|
| `METHOD_NOT_ALLOWED` | the method is not in the page's permissions, or the host API is off in this installation | say that live data is unavailable here; do not retry |
| `TOO_MANY_REQUESTS` | more than 6 requests in flight | queue and retry |
| `INVALID_ARGS`, `VALIDATION_ERROR` | the arguments do not match the method's schema | fix the call |
| `TIMEOUT` (client-side) | nothing answered: an older DataLens version, or a very slow query | offer a retry |
| `NOT_FRAMED` (client-side) | the file was opened outside DataLens | show a placeholder or sample data |
| anything else | the DataLens API error, passed through with its own `code` and `message` | show `message` |

Branch on `code`, not on `status`: the host often reports 500 for an error that is really "not
found" or "not supported".

## `getDatasetData`

Queries a dataset the way a chart does: dimensions group, measures aggregate.

```js
const result = await DataLens.getDatasetData({
  datasetId: 'abcd1234efgh5',
  columns: ['region_x1y2', '5f2c9a1e-7b3d-4c8a-9e0f-1a2b3c4d5e6f'], // a dimension and a measure
  filters: [{ guid: 'channel_k9m3', operation: 'in', values: ['Online'] }],
  sort: [{ guid: '5f2c9a1e-7b3d-4c8a-9e0f-1a2b3c4d5e6f', direction: 'desc' }],
  limit: 100,
});
// { schema: [{ name, guid, type }, …], rows: [['North', 68515528.55], ['South', 56873834.15], …] }
```

| Argument | Notes |
|----------|-------|
| `datasetId` | required |
| `workbookId` | optional |
| `columns` | required, at least one; field **GUIDs**, not titles; no duplicates |
| `filters` | `{ guid, operation, values }`. Operations: `in`, `nin`, `between` (exactly two values), `isnull` / `isnotnull` (no `values`), and the single-value ones `eq`, `ne`, `gt`, `lt`, `gte`, `lte`, `contains`, `icontains`, `notcontains`, `noticontains`, `startswith`, `istartswith`, `endswith`, `iendswith`, `leneq`, `lenne`, `lengt`, `lengte`, `lenlt`, `lenlte` |
| `params` | `{ guid, value }` for dataset parameters |
| `sort` | `{ guid, direction: 'asc' \| 'desc' }`; every sorted field must also be in `columns` |
| `limit` | 1–100000, default **100**. Without `sort` the selected rows are not deterministic |
| `offset` | requires a non-empty `sort` |

`rows` are arrays in `schema` order. Values keep the dataset types: dates come as ISO strings,
numbers as numbers.

**Get the GUIDs while generating the page, not at runtime.** There is no host method that lists
a dataset's fields. Read them through whatever DataLens interface is configured (`datalens-sdk`,
MCP, or the HTTP API's dataset read) and put the GUIDs in the page as constants, next to a
human-readable name. A field GUID is stable; its title is not.

Selecting several dimensions with no measure returns their distinct combinations — that is how
to fill a filter's option list. It is not a row count: the request cannot define its own
aggregation, so a count or a sum needs a measure field that already exists in the dataset. When
the dataset has none, ask the user to add one, or read a saved chart with `getChartData`.

## `getChartData`

Returns the data behind a saved chart, with the chart's own settings applied.

```js
const result = await DataLens.getChartData({ chartId: 'wxyz6789abcd0', params: { region: 'North' } });
// { chartType: 'wizard' | 'ql' | 'editor', results: [{ schema: [{ name, … }], rows: [[…], …] }] }
```

- `params` is optional: chart parameters, each a string or an array of strings.
- `results` holds one table per query or block; tables with different schemas come separately.
- Column descriptions differ by chart type: Wizard gives `name`, `type` and sometimes `guid`;
  QL gives `name` and a QL `type`, and may return numbers as strings; Editor gives `name` only.
- Not every visualization is supported. A pivot table, for one, is rejected with the code
  `UNSUPPORTED_CHART_DATA_VISUALIZATION`. Prefer `getDatasetData` when the page needs its own
  grouping or filtering, and `getChartData` when it must show exactly what an existing chart shows.

## State: `createState` and `getState`

State is how a user shares what they clicked together in the page. It works like a dashboard's
state link.

```js
const { hash } = await DataLens.createState({ filters: { region: ['North'] }, tab: 'map' });
```

The host stores the object, puts `?state=<hash>` into the address bar of the DataLens page, and
returns the hash. The link the user copies from the address bar now restores that state.

```js
const { hash, data } = await DataLens.getState(); // { hash: null, data: null } when the link has no state
if (data) applyState(data);
```

- `data` must be a plain JSON object, at most 64 KB serialized. Store choices (filter values,
  the active tab, a sort order), never query results.
- The page cannot read the address bar and cannot pick a hash: `getState` returns the state of
  the link the viewer opened, and nothing else.
- A state is immutable. Each `createState` makes a new one, so call it on an explicit action
  ("Save view", "Share") or debounced after changes, not on every keystroke.
- Restore once, at start-up, before the first data request, so the first query already uses the
  restored filters.

## A page that degrades well

```js
async function load() {
  setStatus('loading');
  try {
    const saved = await DataLens.getState().catch(() => null);
    if (saved && saved.data) applyState(saved.data);
    render(await DataLens.getDatasetData(buildQuery()));
    setStatus('ready');
  } catch (error) {
    setStatus(error.code === 'METHOD_NOT_ALLOWED' || error.code === 'NOT_FRAMED'
      ? 'Live data is not available here'
      : `Could not load data: ${error.message}`);
  }
}
```

## Security notes for the author

- The page acts with the viewer's access. Request only the data the page shows; do not pull
  whole tables "just in case".
- The existing channels out of the sandbox are unchanged and now carry more weight: `OPEN_URL`
  can put values into a URL, `EXPORT` hands a file to the user. Never place query results into a
  link, and export only what the user asked to download.
- Do not navigate the frame (`location.href = …`, `<meta http-equiv="refresh">`). For a page
  with host API access the host blocks any navigation away from the page's own file, and the
  frame goes blank.
