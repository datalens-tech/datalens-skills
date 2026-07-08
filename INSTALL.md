# Installing the DataLens skills

Each skill is a folder with a `SKILL.md`, written to the open
[Agent Skills standard](https://agentskills.io). "Installing" one means putting that folder where
your agent looks for skills. Pick the path that matches your tool.

## Claude Code — plugin (recommended)

This repo is also a Claude Code plugin marketplace, so it installs (and updates) in two commands:

```
/plugin marketplace add datalens-tech/datalens-skills
/plugin install datalens-skills@datalens
```

Installed skills are namespaced by the plugin, e.g. `datalens-skills:datalens-html-pages`.

## Any tool — copy the skill folder

A skill is just a folder, so you can drop the one(s) you want straight into the directory your tool
scans:

| Tool | Single project | Personal (all projects) |
|------|----------------|-------------------------|
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| Codex | `.agents/skills/` | `~/.agents/skills/` |
| OpenCode | `.opencode/skills/` | `~/.config/opencode/skills/` |

Two things make this simpler than the table suggests:

- **`.agents/skills/` is vendor-neutral** — both Codex and OpenCode read it, so one folder there
  covers both. Codex scans `.agents/skills` from your working directory up to the repo root, and
  globally at `~/.agents/skills/`.
- **OpenCode also reads `.claude/skills/` and `.agents/skills/`** (per-project and under `~/`), so
  it rarely needs its own directory.

Neither Codex nor OpenCode has a marketplace-style one-command install — for them, "installing" is
placing the folder and restarting the agent. (Codex ships a `$skill-installer` for its own curated
catalog and can bundle skills as a plugin, but for *this* repo, folder placement is the path.)

For example, the HTML-pages skill into your personal Claude Code directory:

```bash
git clone https://github.com/datalens-tech/datalens-skills
cp -R datalens-skills/skills/datalens-html-pages ~/.claude/skills/
```

Or use the community [`skills`](https://www.npmjs.com/package/skills) CLI:

```bash
npx skills add https://github.com/datalens-tech/datalens-skills --skill datalens-html-pages
```

Restart your agent afterward so it re-scans skills.

## Verify it loaded

The skill should show up in your agent's list of available skills — `datalens-html-pages` when
copied directly, or `datalens-skills:datalens-html-pages` when installed via the plugin.

---

## Developing inside this repo (contributors)

You only need this if you clone the repo and open it *as your agent's workspace* to add or edit
skills. The canonical skills live in `skills/`, and each tool's project directory
(`.claude/skills`, `.agents/skills`, `.opencode/skills`) is a **committed symlink** to it, so all
three tools discover them while you work. If those symlinks didn't survive checkout — common on
Windows, or with `git config core.symlinks=false` — recreate them (the script copies the folder as
a fallback):

```bash
node scripts/install.mjs
```

This is a maintainer convenience only; consumers of the skills never need it.
