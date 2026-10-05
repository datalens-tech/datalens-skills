# Publishing an HTML page

## Choose the interface

Take the installation, its UI and API endpoints, and authentication from `datalens`. Use the
interface the user chose, or else a client that is already configured; publishing needs no local
dev server or browser session. If that interface cannot create HTML pages, say so before any write
and offer another; never switch silently.

- **Python SDK:** load `datalens-sdk` and use the HTML-page operation documented by the
  instructions bundled with the installed version, under the SDK's own names and result types. If
  there is none, report the limitation and offer an SDK upgrade, MCP, or HTTP. Do not guess a
  method from `createHtmlPage` or call SDK internals.
- **MCP:** discover and describe the commands below on the configured server before invoking
  them, and follow the returned schemas.
- **HTTP API:** JSON POST to `/rpc/<command>` on the API endpoint; take schemas and required
  headers from its `/json/` spec.

The command and field names below are the HTTP/MCP wire API, not an SDK interface.

## Place and create the page

Validate the file with this skill's `scripts/validate_page.py`, then check the destination:
`listDirectory` for a legacy folder, `getWorkbook` and `getWorkbookEntries` for a workbook. If the
name is taken, ask rather than overwrite. Then call `createHtmlPage` with the complete UTF-8 file
as the `content` string and exactly one location form the installation supports:

| Destination | Location fields | Example |
|---|---|---|
| Legacy folder | `key`: full path including the page's leaf name | `"key": "Users/alice/reports/sales-report"` |
| Workbook | `workbookId` and `name` (the leaf name) | `"workbookId": "<id>", "name": "sales-report"` |

Never combine `key` with `workbookId`/`name`. After a timeout or an uncertain result, look for the
page at the destination before retrying, and verify what you find as below.

## Verify and return the link

1. Take `entry.entryId` from the create result and report any `warnings`.
2. Fetch `getHtmlPage` (`entryId`, `branch: "published"`); without a published revision,
   publication is not complete. The result is the entry itself, not wrapped in `entry`. Confirm
   the ID, `scope: "artifact"`, and `type: "html-page"`. For a folder, compare the full `key`; for
   a workbook, compare `workbookId` and the last non-empty segment of `key`. `name` is a creation
   argument, not a response field.
3. Check the stored content: get `getHtmlPagePreviewUrl` for the published branch and fetch it at
   once, since it expires in seconds. Expect the report's content and charset, not byte equality,
   because the server injects CSP. This verifies storage, not the `/pages/` route or browser
   rendering; report it as such, or say the content was not checked if the command is unavailable.
4. Return the permanent link `<UI endpoint>/pages/<entryId>`: the UI endpoint, not the API one,
   and the entry ID, not `revId`, `publishedId`, or the bucket object ID. A `/navigate/` or
   `/navigation/` URL or the preview URL is not the report link.

If you open the link to check it, a redirect to login or folder navigation does not show that the
page rendered.
