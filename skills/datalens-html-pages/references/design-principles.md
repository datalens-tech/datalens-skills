# Yandex DataLens dashboard design principles

## Core principle

A dashboard's job is not to impress but to let the reader take in the data fast: see the values, compare them, and spot deviations. Styling must not compete with the data for attention. Keep only what helps reading: no 3D, shadows, glows, or decorative flourishes. Gradients are not decoration — use them only where they encode magnitude (see "Gradients").

## Wiring up the styles

The page must be fully self-contained (the CSP blocks external requests except the allowlist), so:

1. Inline the full contents of `assets/dl-theme-tokens.css` and `assets/dl-dashboard.css` into the page's `<style>`.
2. DataLens itself appends the `theme` (`light | dark | system`) and `lang` (`ru | en`) parameters to the page's query string at render time — nothing to configure, just read `location.search`. Put the theme classes on the root element and define a helper for reading tokens from JS:

```js
const params = new URLSearchParams(location.search);
let theme = params.get('theme') ?? 'light';
if (theme === 'system') {
  theme = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
document.documentElement.className = `g-root g-root_theme_${theme}`;

const cssVar = (name) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim();
```

3. Use variables from these files throughout the CSS instead of raw hex values. For chart libraries that need explicit colors, pass values via `cssVar('--dl-graph-palette-color-1')` and the like — then dark theme works with no separate code path. The one exception is the preset gradients from the "Gradients" section: they are the same in both themes.

## Dashboard structure

Top to bottom:

- Title
- Tabs (if there are multiple sections)
- Selectors (filters)
- Charts

Content order: a row of key indicators first, then trends and comparisons, with detail (tables) at the bottom. The reader should get the main takeaway without scrolling.

## Grid and spacing

- The horizontal grid has **9 columns**. The gap between columns and between widgets is **8px (`--g-spacing-2`) — never less**.
- Vertical rhythm follows a **26px** grid: align widget heights to this step.
- A widget is a card with `--dl-color-widget-background` and a 12px radius (the `.dashboard-widget` class). Inner padding — 16px (`--g-spacing-4`).
- Page background — `--dl-color-dashboard-background`; base styles — the `.dashboard` class.

## Typography

Set the page-wide font from the `--g-font-family-sans` variable. Its second entry is Inter — load it from Google Fonts as a fallback for users without YS Text installed.

- Base size — `--g-text-body-1-font`.
- Main page title — `--g-text-header-2-font`.
- Section headings — `--g-text-header-1-font`.
- Widget title — `--g-text-body-2-font`; the caption/period below it — `--g-color-text-secondary`.
- Prefer the combined styles ending in `-font`.
- Avoid overly small sizes — 11px and below.

## Number and date formatting

- Take the locale from the `lang` query parameter (`ru` | `en`).
- Thousands separator: `ru` — non-breaking space (1 234 567), `en` — comma (1,234,567). Decimal: `ru` — comma, `en` — point.
- Abbreviate large numbers: `ru` — 12,4 тыс. / 3,1 млн / 1,2 млрд; `en` — 12.4K / 3.1M / 1.2B.
- Use 0–2 decimal places, the same for every value in a given chart or column. Percentages — usually one decimal (12.4%).
- In tables, indicators, and on axes enable `font-variant-numeric: tabular-nums` — digits become equal-width, place values line up in a column, and numbers can be compared down the column at a glance.
- Keep dates short: `ru` — 5 авг, 05.08.2026; `en` — Aug 5, 08/05/2026. Don't show the time when the data has daily granularity.

## Colors

The overall feel is a light, clean dashboard on a soft gray background (`--dl-color-dashboard-background`). Accents come from the brand colors and the chart colors.

- Series colors — `--dl-graph-palette-color-1`…`-20` from `dl-theme-tokens.css`. Start with the first and take them in order.
- **One metric — one color.** Don't paint the bars of a single series in different palette colors: color is there to tell series apart, not to decorate.
- Semantics beats palette order: growth/positive — `--g-color-text-positive` / `--g-color-base-positive`, decline/problem — `-danger`, warning — `-warning`. Color deltas in indicators and tables semantically (▲ green, ▼ red).
- Text: primary — `--g-color-text-primary`, secondary — `--g-color-text-secondary`.
- Accent: `--g-color-text-brand` for text, `--g-color-base-brand` for backgrounds.
- Lines: `--g-color-line-generic`; `--g-color-line-generic-solid` when lines overlap each other.

## Gradients

A gradient is acceptable only when it encodes magnitude — "more/less", "worse/better". Don't use it as decorative background for cards, headers, or buttons.

Where it fits:

- heat fill of table or pivot-table cells by value;
- background of progress indicators and plan-completion scales;
- area-chart fill (series color → transparent toward the bottom);
- intensity on maps (choropleth) and in treemaps;
- "bad → good" scales (e.g. Red Orange Green).

Preset gradients (identical in light and dark themes):

| Name | Stops |
|---|---|
| Orange Green | `#FFB433 → #7FD169` |
| Red Orange | `#FF6A59 → #FFB433` |
| Yellow | `#FFB433 → #FFDC73` |
| Blue | `#3D97F2 → #8CD5FF` |
| Light Blue | `#8CD5FF → #B2F2FF` |
| Purple | `#AB94D9 → #D4BFFF` |
| Turquoise | `#60A196 → #AFDBD1` |
| Green | `#7FD169 → #C3E55C` |
| Red Orange Green | `#FF6A59 → #FFB433 → #7FD169` |

## Choosing a visualization type

The core set: line, area (+normalized), column (+normalized), bar (+normalized), funnel, scatter, pie, donut, indicator, treemap, table, pivot table, map, combined. Other types aren't forbidden, but pick from this list by default.

| Task | Chart type |
|---|---|
| Change over time | Line |
| Parts' contribution over time | Area; shares — normalized area |
| Comparing categories | Column; many categories or long labels — bar |
| Composition, shares of a whole | Normalized column/bar; pie or donut — only with ≤5 categories |
| Conversion, process stages | Funnel |
| Relationship between two metrics | Scatter |
| One key number | Indicator |
| Hierarchy, nested category contribution | Treemap |
| Exact values, many dimensions | Table, pivot table |
| Geography | Map |
| Metrics with different scales or types | Combined (columns + line, second axis) |

Anti-patterns:

- pie/donut with 6+ categories — replace with a bar chart;
- gauges, radars, 3D — don't use unless explicitly requested;
- different chart types for widgets that mean the same thing on one dashboard.

## Chart construction rules

- Column and bar charts — the value axis always starts at zero: a truncated axis distorts comparison. Line charts may use the data range.
- Grid lines — only perpendicular to the value axis (horizontal on vertical charts), color `--g-color-line-generic`. Axes and axis labels — `--g-color-infographics-axis`.
- Sorting: categories — by descending value; time — chronologically; funnel — by stage order.
- Legend: hide it with a single series — the widget title names it. With several series — below the chart. Series markers in the legend are circles, not rectangles.
- Value labels on points — only when there are few points (up to ~10–12); otherwise show values in the tooltip (background — `--g-color-infographics-tooltip-bg`).
- No chart entrance animation — the data is visible immediately. Animation is acceptable on interaction, when a state change needs showing (a filter applied, a tab switched): it should explain behavior, not decorate.
- Slightly round chart elements where possible: for example, the ends of columns and bars.

## Tables

- Numbers — right-aligned with `tabular-nums`, text — left-aligned. Column headers — `--g-text-subheader-1-font`, color — `--g-color-text-primary`.
- Row separators — horizontal lines `--g-color-line-generic`; the last row has no bottom separator. **Avoid vertical separators unless necessary** — alignment and spacing are usually enough.
- Zebra striping — optional, only for wide tables, with `--g-color-base-generic-ultralight`.
- Heat-filled cells — use the gradients from the "Gradients" section; text in filled cells must stay readable.

## Responsiveness and states

- Below ~768px lay widgets out in a single column.
- Put wide tables in a container with `overflow-x: auto`; don't squeeze columns into unreadability.

## Checklist before shipping the page

- [ ] CSS tokens are inlined, the root has `g-root g-root_theme_…`, the theme from the query parameter works (including `system`).
- [ ] No hardcoded hex in CSS or chart configs (except the preset gradients) — everything via variables / `cssVar()`.
- [ ] Chart types match the tasks in the table; no pies with 6+ categories.
- [ ] Column/bar axes start at zero; grid lines are horizontal only; series use `--dl-graph-palette-color-N` in order; one metric — one color.
- [ ] Numbers and dates are formatted per the `lang` locale; tables and indicators use `tabular-nums`.
- [ ] 9-column grid, gaps ≥8px, heights on the 26px step; single column at mobile widths.
- [ ] Checked in light and dark themes: text and lines are readable, charts recolor.
