# Changelog

Notable changes to this plugin, in the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), which Agent Plugins
[§10.2](https://github.com/agentplugins/agent-plugins-spec/blob/main/spec/1.0.0.md#102-plugin-versions)
recommends and clients use for update checks and cache freshness.

What the segments mean for a package of skills:

- **Major** — a breaking change. Note that narrowing a skill's `description` far enough that it stops
  triggering on prompts it used to handle is breaking for that skill's users, even though no
  instruction was removed.
- **Minor** — a new skill, or new behavior in an existing one, that breaks nothing.
- **Patch** — a corrective change with no intended behavioral break.

## [Unreleased]

## [0.2.0] — 2026-08-10

Makes the repository a conformant [Agent Plugins v1.0.0](https://github.com/agentplugins/agent-plugins-spec)
package. No skill content changed, and no install command changes for existing consumers.

### Added

- `plugin.json` at the repository root — the portable manifest that is the specification's
  conformance floor (§5.1). Clients that read the standard now discover this plugin; previously only
  the Claude Code and Codex client manifests existed, and neither has a portable role.
- `scripts/validate_plugin.mjs`, run in CI: validates the portable manifest against the closed
  schema (§5.2–§5.6), asserts the client manifests and marketplace entries agree with it, and checks
  that every packaged path resolves inside the plugin root (§4.1).
- This changelog.

### Changed

- `version` is now `0.2.0` across the portable and both client manifests. It had been `0.1.0` since
  the first commit, through three feature releases, so no client could detect an update.
- `.claude-plugin/plugin.json` gained the `yandex-cloud` keyword, which `.codex-plugin/plugin.json`
  already had. The two lists are now identical and CI fails if they diverge again.

## [0.1.0]

Released untagged, as the state of `main` through
[#7](https://github.com/datalens-tech/datalens-skills/pull/7).

### Added

- The `datalens`, `datalens-html-pages`, `datalens-sdk`, and `datalens-yc-rls-resolve` skills.
- Claude Code plugin marketplace (`.claude-plugin/`) and Codex plugin marketplace
  (`.codex-plugin/`, `.agents/plugins/`).
- Skill frontmatter validation, DataLens SDK bootstrap tests, the HTML page linter, and the
  deterministic report eval, all running in CI.

[Unreleased]: https://github.com/datalens-tech/datalens-skills/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/datalens-tech/datalens-skills/releases/tag/v0.2.0
