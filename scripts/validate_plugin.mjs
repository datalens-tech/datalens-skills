#!/usr/bin/env node
// Validate the plugin package: the portable Agent Plugins manifest, the client-specific
// manifests kept in sync with it, and path containment.
//
// Zero npm dependencies, matching scripts/validate_skills.mjs. The portable schema is small,
// closed, and fixed at one spec version, so a hand-written check is clearer here than pulling
// in a JSON Schema validator.
//
// Usage: node scripts/validate_plugin.mjs [plugin-root]   (default: the repo root)
//
// Spec: https://github.com/agentplugins/agent-plugins-spec/blob/main/spec/1.0.0.md

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, lstatSync, realpathSync, readlinkSync } from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SPEC_VERSION = '1.0.0';
const PLUGIN_SCHEMA_ID = `https://agent-plugins.org/schemas/${SPEC_VERSION}/plugin.schema.json`;

// §5.2 — the portable manifest schema is closed; these ten fields are the whole surface.
const MANIFEST_FIELDS = [
  '$schema',
  'name',
  'version',
  'description',
  'author',
  'homepage',
  'repository',
  'license',
  'keywords',
  'extensions',
];
const STRING_FIELDS = ['version', 'description', 'homepage', 'repository', 'license'];
// §5.4 — `author` may carry only these three, each a string. Anything else is fatal.
const AUTHOR_FIELDS = ['name', 'email', 'url'];

// §5.5 — plugin names permit periods and are checked against this pattern. Skill names are
// stricter (no periods); see NAME_RE in scripts/validate_skills.mjs. Deliberately two
// constants in two files rather than one shared regex, because they are two different rules.
const PLUGIN_NAME_RE = /^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
const NAME_MAX = 64;

const SEMVER_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

// Client-specific manifests that mirror the portable one. Their client-only fields
// (`skills`, `interface`, …) are none of our business here — only the shared metadata is.
const CLIENT_MANIFESTS = ['.claude-plugin/plugin.json', '.codex-plugin/plugin.json'];
// Fields that must agree between the portable manifest and a client manifest that declares
// them. Descriptions written for a store listing are exempt: `.codex-plugin`'s
// `interface.shortDescription` / `interface.longDescription` and the marketplace entries
// exist to be phrased for a human browsing a catalog, and may differ on purpose.
const SHARED_FIELDS = ['name', 'version', 'description', 'homepage', 'repository', 'license'];
const REQUIRED_IN_CLIENT = ['name', 'version'];

// Marketplace formats are outside Agent Plugins v1 entirely, so nothing here validates their
// shape — only that they still point at the plugin name the portable manifest declares, so a
// rename cannot half-land.
const MARKETPLACES = ['.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'];

const SKIP_DIRS = new Set(['.git', 'node_modules', '.venv', 'venv', '__pycache__']);

const scriptDir = dirname(fileURLToPath(import.meta.url));
const pluginRoot = resolve(process.argv[2] ?? resolve(scriptDir, '..'));

const errors = [];
const warnings = [];

// Cached, so a manifest consulted by several checks is read — and a broken one reported —
// exactly once.
const jsonCache = new Map();

function readJson(relPath) {
  if (jsonCache.has(relPath)) return jsonCache.get(relPath);
  let result;
  try {
    const raw = readFileSync(join(pluginRoot, relPath), 'utf8');
    try {
      result = { data: JSON.parse(raw) };
    } catch (err) {
      errors.push(`${relPath}: not valid JSON — ${err.message}`);
      result = { invalid: true };
    }
  } catch {
    result = { missing: true };
  }
  jsonCache.set(relPath, result);
  return result;
}

function isPlainObject(v) {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// ---------------------------------------------------------------------------
// 4a. Portable manifest against the closed schema (§5.2–§5.6)
// ---------------------------------------------------------------------------

function validateManifest(m) {
  for (const key of Object.keys(m)) {
    if (!MANIFEST_FIELDS.includes(key)) {
      // §5.2 has clients report-and-ignore unknown fields. In our own package a stray
      // top-level field is a bug — usually a typo or a client field in the wrong file — so
      // fail the build instead of shipping something every client will complain about.
      errors.push(`plugin.json: unknown top-level field \`${key}\` (client data belongs under \`extensions\`)`);
    }
  }

  // $schema — required, and exactly the canonical identifier for the targeted spec version.
  if (m.$schema === undefined) {
    errors.push('plugin.json: missing required `$schema`');
  } else if (m.$schema !== PLUGIN_SCHEMA_ID) {
    errors.push(`plugin.json: \`$schema\` must be exactly "${PLUGIN_SCHEMA_ID}" (got ${JSON.stringify(m.$schema)})`);
  }

  // name — required, and constrained by §5.5.
  if (typeof m.name !== 'string' || m.name === '') {
    errors.push('plugin.json: missing required `name` (non-empty string)');
  } else {
    if (m.name.length > NAME_MAX) {
      errors.push(`plugin.json: name is ${m.name.length} chars (max ${NAME_MAX})`);
    }
    if (!PLUGIN_NAME_RE.test(m.name)) {
      errors.push(
        `plugin.json: name "${m.name}" must be lowercase alphanumeric with \`-\`/\`.\`, ` +
          'start and end alphanumeric, and contain no `--` or `..`',
      );
    }
  }

  for (const field of STRING_FIELDS) {
    if (m[field] !== undefined && typeof m[field] !== 'string') {
      errors.push(`plugin.json: \`${field}\` must be a string`);
    }
  }

  if (m.keywords !== undefined) {
    if (!Array.isArray(m.keywords) || m.keywords.some((k) => typeof k !== 'string')) {
      errors.push('plugin.json: `keywords` must be an array of strings');
    }
  }

  if (m.author !== undefined) {
    if (!isPlainObject(m.author)) {
      errors.push('plugin.json: `author` must be an object');
    } else {
      for (const [key, value] of Object.entries(m.author)) {
        if (!AUTHOR_FIELDS.includes(key)) {
          errors.push(`plugin.json: \`author.${key}\` is not permitted (only ${AUTHOR_FIELDS.join(', ')})`);
        } else if (typeof value !== 'string') {
          errors.push(`plugin.json: \`author.${key}\` must be a string`);
        }
      }
    }
  }

  if (m.extensions !== undefined) {
    if (!isPlainObject(m.extensions)) {
      errors.push('plugin.json: `extensions` must be an object keyed by reverse-domain namespace');
    } else {
      for (const [ns, value] of Object.entries(m.extensions)) {
        if (!isPlainObject(value)) {
          errors.push(`plugin.json: \`extensions["${ns}"]\` must be an object`);
        }
        if (!ns.includes('.')) {
          warnings.push(`plugin.json: extension namespace "${ns}" should be a reverse-domain identifier (§8)`);
        }
      }
    }
  }

  // §5.4 forbids *clients* from rejecting a manifest over a non-SemVer `version`, but this
  // script runs as the package author, and our release process — CHANGELOG.md, `vX.Y.Z` tags,
  // cross-manifest version sync — assumes SemVer, so here it is an error. URL fields stay
  // warnings: nothing downstream depends on them parsing.
  if (typeof m.version === 'string' && !SEMVER_RE.test(m.version)) {
    errors.push(`plugin.json: version "${m.version}" is not Semantic Versioning (release process requires it; spec §10.2 recommends it)`);
  }
  for (const field of ['homepage', 'repository']) {
    if (typeof m[field] === 'string') {
      try {
        new URL(m[field]);
      } catch {
        warnings.push(`plugin.json: \`${field}\` is not a parseable URL`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 4b. Cross-manifest consistency
// ---------------------------------------------------------------------------

function sameStringSet(a, b) {
  const as = [...new Set(a)].sort();
  const bs = [...new Set(b)].sort();
  return as.length === bs.length && as.every((v, i) => v === bs[i]);
}

function validateClientManifests(m) {
  for (const relPath of CLIENT_MANIFESTS) {
    const { data, missing, invalid } = readJson(relPath);
    if (missing) {
      errors.push(`${relPath}: missing — expected alongside the portable manifest`);
      continue;
    }
    if (invalid) continue;
    if (!isPlainObject(data)) {
      errors.push(`${relPath}: top level must be an object`);
      continue;
    }

    for (const field of REQUIRED_IN_CLIENT) {
      if (data[field] === undefined) {
        errors.push(`${relPath}: missing \`${field}\` (must match plugin.json)`);
      }
    }

    for (const field of SHARED_FIELDS) {
      if (data[field] === undefined) continue;
      if (data[field] !== m[field]) {
        errors.push(
          `${relPath}: \`${field}\` is ${JSON.stringify(data[field])} but plugin.json says ` +
            `${JSON.stringify(m[field])}`,
        );
      }
    }

    if (isPlainObject(data.author) && isPlainObject(m.author) && data.author.name !== m.author.name) {
      errors.push(
        `${relPath}: \`author.name\` is ${JSON.stringify(data.author.name)} but plugin.json says ` +
          `${JSON.stringify(m.author.name)}`,
      );
    }

    if (data.keywords !== undefined) {
      if (!Array.isArray(data.keywords)) {
        errors.push(`${relPath}: \`keywords\` must be an array`);
      } else if (!sameStringSet(data.keywords, m.keywords ?? [])) {
        errors.push(`${relPath}: \`keywords\` differs from plugin.json (compared as a set)`);
      }
    }
  }
}

function validateMarketplaces(m) {
  for (const relPath of MARKETPLACES) {
    const { data, missing, invalid } = readJson(relPath);
    if (missing || invalid) continue; // marketplaces are optional and outside the portable spec
    const entries = Array.isArray(data?.plugins) ? data.plugins : [];
    if (!entries.length) {
      warnings.push(`${relPath}: no \`plugins\` entries found — cannot check the plugin name`);
      continue;
    }
    if (!entries.some((e) => isPlainObject(e) && e.name === m.name)) {
      errors.push(`${relPath}: no entry named "${m.name}" — a plugin rename must land everywhere at once`);
    }
  }
}

// ---------------------------------------------------------------------------
// 4c. Path containment (§4.1)
// ---------------------------------------------------------------------------

// The package set is what ships, so prefer git's view of it. Falls back to a filesystem walk
// when the plugin root is not a git checkout (e.g. an installed copy).
function packagePaths() {
  try {
    const out = execFileSync('git', ['-C', pluginRoot, 'ls-files', '-z'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const list = out.split('\0').filter(Boolean);
    if (list.length) return list;
  } catch {
    // not a git checkout, or git unavailable
  }

  const found = [];
  const walk = (relDir) => {
    const abs = relDir ? join(pluginRoot, relDir) : pluginRoot;
    for (const entry of readdirSync(abs, { withFileTypes: true })) {
      if (entry.isDirectory() && SKIP_DIRS.has(entry.name)) continue;
      const rel = relDir ? join(relDir, entry.name) : entry.name;
      found.push(rel);
      // Do not descend through a symlink: its target is containment-checked as one entry,
      // and following it can loop.
      if (entry.isDirectory()) walk(rel);
    }
  };
  walk('');
  return found;
}

// Separator-aware, so a sibling directory like `/repo-backup` does not pass as inside `/repo`.
function isInside(root, candidate) {
  return candidate === root || candidate.startsWith(root + sep);
}

// Paths the manifests point a client at. A client dereferences these whether or not they are
// committed, so they are checked on top of the package set (which covers only tracked files).
function declaredPaths() {
  const declared = [];
  const codex = readJson('.codex-plugin/plugin.json').data;
  if (typeof codex?.skills === 'string') declared.push(codex.skills);
  for (const relPath of MARKETPLACES) {
    const entries = readJson(relPath).data?.plugins;
    for (const entry of Array.isArray(entries) ? entries : []) {
      if (typeof entry?.source === 'string') declared.push(entry.source);
      if (typeof entry?.source?.path === 'string') declared.push(entry.source.path);
    }
  }
  return declared;
}

function validateContainment() {
  let resolvedRoot;
  try {
    resolvedRoot = realpathSync(pluginRoot);
  } catch {
    errors.push(`plugin root ${pluginRoot} does not resolve`);
    return 0;
  }

  const paths = packagePaths();
  for (const rel of declaredPaths()) {
    if (!paths.includes(rel)) paths.push(rel);
  }
  for (const rel of paths) {
    const abs = join(pluginRoot, rel);
    let resolved;
    try {
      resolved = realpathSync(abs);
    } catch {
      // A dangling symlink still reveals where it points, and pointing outside the root is
      // the violation we care about. Report either way: a broken package path is a bug.
      let target = '(unresolvable)';
      try {
        if (lstatSync(abs).isSymbolicLink()) {
          target = resolve(dirname(abs), readlinkSync(abs));
        }
      } catch {
        /* fall through to the generic message */
      }
      errors.push(`${rel}: does not resolve within the plugin root (target: ${target})`);
      continue;
    }
    if (!isInside(resolvedRoot, resolved)) {
      errors.push(`${rel}: resolves to ${resolved}, outside the plugin root (§4.1)`);
    }
  }
  return paths.length;
}

// ---------------------------------------------------------------------------

const { data: manifest, missing, invalid } = readJson('plugin.json');
let checkedPaths = 0;

if (missing) {
  errors.push('plugin.json: missing at the plugin root — required by Agent Plugins §5.1');
} else if (!invalid) {
  if (!isPlainObject(manifest)) {
    errors.push('plugin.json: top level must be an object');
  } else {
    validateManifest(manifest);
    validateClientManifests(manifest);
    validateMarketplaces(manifest);
  }
}
checkedPaths = validateContainment();

for (const w of warnings) process.stdout.write(`⚠ ${w}\n`);
for (const e of errors) process.stdout.write(`✗ ${e}\n`);

if (errors.length) {
  process.stdout.write(`\n${errors.length} error(s) validating the plugin package.\n`);
  process.exit(1);
}
process.stdout.write(
  `✓ Agent Plugins ${SPEC_VERSION} manifest valid, ` +
    `${CLIENT_MANIFESTS.length} client manifest(s) in sync, ` +
    `${checkedPaths} package path(s) contained` +
    `${warnings.length ? `, ${warnings.length} warning(s)` : ''}.\n`,
);
