# Evals

Curated test sets for the skills in this repo — the **specs of intended behavior**. Version and
review them in PRs. Optimizer/run *outputs* (timestamped logs, HTML reports) are throwaway and stay
untracked under `.skill-creator/`.

Two kinds live here, per skill.

## `datalens-rls-resolve/`

### `triggering.json` — *should the skill fire?*

20 realistic queries labelled `should_trigger` true/false: RLSv2 subject-id resolution, legacy
`rls` migration, Yandex Cloud Organization users/groups, auth and permission failures, plus
near-misses such as generic database RLS, IAM administration, chart filtering, and non-cloud
DataLens installations. Run it after changing the skill description:

```bash
python -m scripts.run_loop \
  --eval-set evals/datalens-rls-resolve/triggering.json \
  --skill-path skills/datalens-rls-resolve \
  --model <model-id> --holdout 0.4 --verbose
```

### `behavior.json` — *does resolution and conversion stay correct and safe?*

Five cases cover mixed subject types, legacy conversion, safe auth recovery, permission denial,
and unresolved subjects. These cases require human or model judgement. The bundled offline test
suite mechanically checks parsing, normalization, RLSv2 assembly, CLI naming, and error handling:

```bash
python skills/datalens-rls-resolve/tests/test_rls_tool.py
```

## `datalens-html-pages/`

### `triggering.json` — *should the skill fire?*

20 realistic queries labelled `should_trigger` true/false: when `datalens-html-pages` should fire,
and the near-misses where it should not (chart-markup, dashboard embedding, generic CSP/sandbox
questions, plain offline HTML reports, …). The reference set for tuning the frontmatter
`description`. Bare-array format, as the skill-creator optimizer expects.

Runs against a live model (`claude -p`), so **not** in CI — run periodically, and after any
`description` change:

```bash
python -m scripts.run_loop \
  --eval-set evals/datalens-html-pages/triggering.json \
  --skill-path skills/datalens-html-pages \
  --model <model-id> --holdout 0.4 --verbose
```

### `behavior.json` — *is the generated page correct?*

Test cases (prompt → assertions) describing what a good generated page looks like: self-contained,
passes the linter, inlines data instead of fetching, reads theme/lang from the query, exports via
`postMessage`, no blocked storage, etc. Each assertion is tagged:

- **`"auto": true`** — checked mechanically by `grade_report.py` (the assertion `id` matches a
  check the grader runs).
- **`"auto": false`** — needs human/LLM judgement (does the chart actually render, is the RU/EN
  copy coherent, …).

`fixtures/broken-report.html` is the deliberately-broken input for the "fix it" case (#2).

Generating a page needs a live model, so that step is manual; grading the result is mechanical:

```bash
# 1. have the skill generate a page for a case's prompt, then:
python evals/datalens-html-pages/grade_report.py path/to/generated.html
```

`grade_report.py --self-test` grades the **shipped template** — it must pass every mechanical
check, so it doubles as a regression guard on the exemplar (and runs in CI).

## What runs in CI

Only the deterministic checks (see [`../.github/workflows/validate.yml`](../.github/workflows/validate.yml));
the model-in-the-loop *generation* evals above are run by hand.

- `node scripts/validate_skills.mjs` — frontmatter + naming
- `python skills/datalens-rls-resolve/tests/test_rls_tool.py` — offline RLS parsing, resolution,
  conversion, CLI naming, and error handling
- `python skills/datalens-html-pages/scripts/validate_page.py --self-test` + linting every shipped page
- `python evals/datalens-html-pages/grade_report.py --self-test` — the template still demonstrates
  every behavior the skill teaches
