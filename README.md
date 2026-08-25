# DataLens Skills

Agent Skills for **Yandex DataLens**, portable across
[Claude Code](https://code.claude.com/docs/en/skills),
[Codex](https://developers.openai.com/codex/skills), and
[OpenCode](https://opencode.ai/docs/skills/). Each skill is a folder written to the open
[Agent Skills standard](https://agentskills.io) — a `SKILL.md` plus optional scripts, references,
and assets — so the same knowledge applies whether you drive DataLens from the UI, the
HTTP API, or an MCP server.

## Skills

| Skill | What it does |
|-------|--------------|
| [`datalens`](skills/datalens/SKILL.md) | Start here. What DataLens is, how its installations differ, the entity model, and which interface — SDK, MCP, API, UI — fits the task. Routes to the rest. |
| [`datalens-html-pages`](skills/datalens-html-pages/SKILL.md) | Author, sanitize, validate, and publish standalone HTML pages (AI-generated reports) that render in a sandboxed iframe under an injected CSP. |
| [`datalens-onprem-install`](skills/datalens-onprem-install/SKILL.md) | Install DataLens On-premises on single-node K3s — a staged, resumable flow: sizing, distributive, feature flags, admin password, Public API + service account, and external auth providers (LDAP/OIDC), plus update and uninstall modes. |
| [`datalens-sdk`](skills/datalens-sdk/SKILL.md) | Drive DataLens from Python — connections, datasets, charts, dashboards. Loads its instructions from the installed SDK package so they always match the installed version. |
| [`datalens-yc-rls-resolve`](skills/datalens-yc-rls-resolve/SKILL.md) | Resolve Yandex Cloud users and groups into DataLens RLSv2 subject IDs, or convert a legacy `rls` configuration to `rls2`. |

## Install

**Any agent — one command.** The community [`skills`](https://www.npmjs.com/package/skills) CLI
installs the skill into whichever agent you use — Claude Code, Codex, OpenCode, and more —
detecting it automatically:

```bash
npx skills add datalens-tech/datalens-skills --skill datalens
npx skills add datalens-tech/datalens-skills --skill datalens-html-pages
npx skills add datalens-tech/datalens-skills --skill datalens-onprem-install
npx skills add datalens-tech/datalens-skills --skill datalens-sdk
npx skills add datalens-tech/datalens-skills --skill datalens-yc-rls-resolve
```

Choose the skill you need. Add `--agent '*'` to install it into every agent you have, or `-g` for
a global (all-projects) install.

**Codex — native plugin.** Add this repository as a marketplace and install the plugin:

```bash
codex plugin marketplace add datalens-tech/datalens-skills
codex plugin add datalens-skills@datalens
```

This repository-root plugin layout requires Codex CLI 0.142.0 or newer. Check with
`codex --version`; upgrade with `codex update` when available, or with the package manager used to
install Codex.

Start a new Codex session afterward so it discovers the installed skills.

**Claude Code — native plugin.** If you prefer the built-in flow, this repo is also a plugin
marketplace:

```
/plugin marketplace add datalens-tech/datalens-skills
/plugin install datalens-skills@datalens
```

**Manual.** A skill is just a folder — copy the selected directory from `skills/` into the
directory your agent scans: `.claude/skills/` (Claude Code), `.agents/skills/` (Codex), or
`.opencode/skills/` (OpenCode), or the matching `~/…` path for a global install.

Full per-tool paths and contributor setup are in **[INSTALL.md](INSTALL.md)**.

## Validation

```bash
node scripts/validate_skills.mjs                              # frontmatter + naming
bash tests/datalens-sdk/test_bootstrap.sh                     # SDK setup and upgrade protocol
python skills/datalens-html-pages/scripts/validate_page.py -  # HTML page linter (reads stdin)
python skills/datalens-yc-rls-resolve/tests/test_rls_tool.py      # offline RLS resolver tests
```

These run in CI on every PR and have no external dependencies.

## Contributing & license

See [CONTRIBUTING.md](CONTRIBUTING.md) (external contributors must adopt the Yandex CLA). Adding a
skill is just a new folder under `skills/` with a valid `SKILL.md`. Licensed under
[Apache-2.0](LICENSE).
