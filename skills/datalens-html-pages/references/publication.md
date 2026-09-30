# Publishing an HTML page

Read this when the user asks to upload or publish a standalone HTML report. HTML generation and
publication are separate: a valid local file is not yet a saved DataLens page.

## Choose the interface

Use `datalens` to establish the installation, UI/API endpoints, authentication, and container
model, including its installation overlay when applicable. Reuse that context if already loaded.
Publish to the requested installation; a report upload does not require a local DataLens dev
server or an authenticated browser.

Preserve the user's selected interface. When none was selected, follow `datalens`'s interface
guidance and reuse an already configured suitable client rather than setting up another one.

- **Python SDK:** load `datalens-sdk` for environment setup and the instructions bundled with
  the installed version. Use its documented HTML-page operation if available; do not translate
  `createHtmlPage` into a guessed Python method. If that version lacks support, report the
  limitation and offer MCP/HTTP publication. Do not reach into private SDK internals or silently
  replace an explicitly selected SDK with HTTP. The location and verification rules below still
  apply, using the SDK's documented names and result types.
- **MCP:** use the configured DataLens server to discover and describe HTML-page and container
  commands before invoking them. Use its returned schema for arguments and results.
- **HTTP API:** use the installation's OpenAPI specification at `/json/` to verify that the
  commands below exist and to resolve their argument/response schemas and required headers.
  Requests are JSON POSTs to `/rpc/<command>` on the API endpoint, with the authentication and
  headers taught by `datalens` and its applicable overlay. Keep the UI endpoint separate from
  the API endpoint.

These HTTP/MCP command names describe the wire API, not an SDK interface:

| Purpose | Command |
|---|---|
| Check a legacy folder and its entries | `listDirectory` |
| Check a workbook and its entries | `getWorkbook`, `getWorkbookEntries` |
| Create the HTML page | `createHtmlPage` |
| Read the saved page metadata | `getHtmlPage` |
| Obtain a temporary URL to check the stored HTML | `getHtmlPagePreviewUrl` |

If the chosen installation/interface lacks a required operation, report that capability gap
before attempting a write. Do not infer support from another installation.

## Place and create the page

Validate the HTML with this skill's `scripts/validate_page.py` before upload. Read the complete
UTF-8 file into `content`; send JSON rather than multipart data or a presigned bucket PUT. The
server injects CSP and stores the object.

Check the requested destination and use exactly one location form supported by the installation:

| Destination | `createHtmlPage` location fields |
|---|---|
| Legacy folder | `key`: full path including the report's leaf name |
| Workbook | `workbookId` and `name`: workbook ID and report leaf name |

For example, the folder `Users/alice/reports` and leaf name `sales-report` give
`"key": "Users/alice/reports/sales-report"`. A folder path alone is not the page's key. Do not
combine `key` with `workbookId`/`name`, or substitute a folder entry ID for a workbook ID.

HTTP/MCP payload examples, after resolving the schema:

```json
{"content": "<!DOCTYPE html>...", "key": "Users/alice/reports/sales-report"}
```

```json
{"content": "<!DOCTYPE html>...", "workbookId": "<workbookId>", "name": "sales-report"}
```

The optional `annotation` has a `description` field. Check for a name collision before creating;
creating a new report is not authorization to overwrite an existing page. After a timeout or
uncertain create result, look for the page at the intended location before retrying the write.

## Verify and return the link

1. Keep the created entry ID from the result. For `createHtmlPage`, it is `entry.entryId`; examine
   `warnings` and report any remaining ones. HTTP 200 alone does not prove the page is correct.
2. Fetch the page with `getHtmlPage` (`entryId`, `branch: "published"`), or the documented SDK
   equivalent. Confirm its ID, `scope: "artifact"`, and `type: "html-page"`. For a folder, compare
   the full `entry.key`; for a workbook, compare `entry.workbookId` and the last non-empty segment
   of `entry.key` with the requested workbook ID and page name. `name` is a creation argument,
   not a response field.
   If there is no published revision, do not claim publication is complete.
3. When checking the stored content, obtain `getHtmlPagePreviewUrl` for the published branch and
   fetch it immediately: the URL expires in seconds. Confirm the expected report content and
   charset. The server injects CSP, so byte-for-byte equality with the original file is not
   expected. This verifies storage, not browser rendering; report those checks separately.
4. Return a permanent UI link: `<UI endpoint>/pages/<entryId>`. Use the created entry ID, never
   `revId`, `publishedId`, or the bucket object ID. A readable slug is optional. Do not return
   `/navigate/<entryId>`, `/navigation/<entryId>`, or the temporary preview URL as the report link.

For UI endpoint `https://datalens.ru` and entry ID `abc123`, the link is
`https://datalens.ru/pages/abc123`. Use the actual installation's UI endpoint when different.
An API response or a successful preview fetch does not verify this final UI route. If checking
the link, follow redirects and confirm it opens the page rather than folder navigation or login;
a login redirect alone cannot establish that the page rendered.
