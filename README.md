# DataLens Skills

Agent Skills for **Yandex DataLens**, portable across
[Claude Code](https://code.claude.com/docs/en/skills),
[Codex](https://developers.openai.com/codex/skills), and
[OpenCode](https://opencode.ai/docs/skills/). Each skill is a folder written to the open
[Agent Skills standard](https://agentskills.io) — a `SKILL.md` plus optional scripts, references,
and assets — so the same knowledge applies whether you drive DataLens from the UI, an SDK, the
HTTP API, or an MCP server.

## Skills

| Skill | What it does |
|-------|--------------|
| [`datalens-html-pages`](skills/datalens-html-pages/SKILL.md) | Author, sanitize, validate, and publish standalone HTML pages (AI-generated reports) that render in a sandboxed iframe under an injected CSP. |

## Install

In **Claude Code**, this repo is a plugin marketplace — install and update in two commands:

```
/plugin marketplace add datalens-tech/datalens-skills
/plugin install datalens-skills@datalens
```

For **any tool**, a skill is just a folder: copy the one you want into your tool's skills directory
(`~/.claude/skills/`, `~/.agents/skills/` for Codex, or `~/.config/opencode/skills/`). Per-tool paths, the
`npx skills add` shortcut, and contributor setup are in **[INSTALL.md](INSTALL.md)**.

## Validation

```bash
node scripts/validate_skills.mjs                              # frontmatter + naming
python skills/datalens-html-pages/scripts/validate_page.py -  # HTML page linter (reads stdin)
```

Both run in CI on every PR and have no external dependencies.

## Contributing & license

See [CONTRIBUTING.md](CONTRIBUTING.md) (external contributors must adopt the Yandex CLA). Adding a
skill is just a new folder under `skills/` with a valid `SKILL.md`. Licensed under
[Apache-2.0](LICENSE).
