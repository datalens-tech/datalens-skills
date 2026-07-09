# Installing the DataLens skills

Each skill is a folder with a `SKILL.md`, written to the open
[Agent Skills standard](https://agentskills.io). "Installing" one means putting that folder where
your agent looks for skills. Any of the paths below work — pick one.

## Any agent — the `skills` CLI (recommended)

The community [`skills`](https://www.npmjs.com/package/skills) CLI installs into whichever agent you
use — Claude Code, Codex, OpenCode, and more — detecting it automatically:

```bash
npx skills add datalens-tech/datalens-skills --skill datalens-html-pages
```

- `--agent '*'` — install into every agent you have (by default it targets the one it detects)
- `-g` — install globally (all projects) instead of just the current one
- `--copy` — copy the files instead of symlinking into the agent's directory
- `--list` — just list the skills in this repo without installing

## Claude Code — native plugin

If you prefer the built-in flow, this repo is also a Claude Code plugin marketplace:

```
/plugin marketplace add datalens-tech/datalens-skills
/plugin install datalens-skills@datalens
```

Installed skills are namespaced by the plugin, e.g. `datalens-skills:datalens-html-pages`.

## Manual — copy the folder

A skill is just a folder; drop the one(s) you want straight into the directory your tool scans:

| Tool | Single project | Personal (all projects) |
|------|----------------|-------------------------|
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| Codex | `.agents/skills/` | `~/.agents/skills/` |
| OpenCode | `.opencode/skills/` | `~/.config/opencode/skills/` |

```bash
git clone https://github.com/datalens-tech/datalens-skills
cp -R datalens-skills/skills/datalens-html-pages ~/.claude/skills/   # or ~/.agents/skills, …
```

Two things make this simpler than the table suggests:

- **`.agents/skills/` is vendor-neutral** — both Codex and OpenCode read it, so one folder there
  covers both. Codex scans `.agents/skills` from your working directory up to the repo root, and
  globally at `~/.agents/skills/`.
- **OpenCode also reads `.claude/skills/` and `.agents/skills/`** (per-project and under `~/`), so
  it rarely needs its own directory.

Restart your agent afterward so it re-scans skills.

## Verify it loaded

The skill should show up in your agent's list of available skills — `datalens-html-pages` when
installed directly, or `datalens-skills:datalens-html-pages` when installed via the Claude Code
plugin.

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
