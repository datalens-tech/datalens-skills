#!/usr/bin/env node
// Validate every skill under skills/: SKILL.md presence, frontmatter, and naming.
// Zero dependencies — a deliberately small YAML frontmatter reader handles the few
// keys we care about (name, description). Exits non-zero if any skill is invalid.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..');
const skillsDir = join(repoRoot, 'skills');

const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const NAME_MAX = 64;
const DESC_MAX = 1024;

const errors = [];
const warnings = [];

// Parse a leading `---` ... `---` YAML block into a flat object. Supports inline
// scalars (quoted or bare) and block scalars (`>`, `>-`, `|`, `|-`) — enough for
// SKILL.md frontmatter without pulling in a YAML dependency.
// Unwrap an inline YAML scalar: matched surrounding quotes, else a plain value with any
// trailing " # comment" removed. Only strips quotes when both ends match, so a value like
// `he said "hi"` is preserved rather than mangled.
function stripInlineScalar(v) {
  const q = v[0];
  if (v.length >= 2 && (q === '"' || q === "'") && v[v.length - 1] === q) {
    return v.slice(1, -1);
  }
  return v.replace(/\s+#.*$/, '').trim();
}

function parseFrontmatter(text) {
  const lines = text.split(/\r?\n/);
  if (lines[0].trim() !== '---') return null;

  const body = [];
  let closed = false;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') {
      closed = true;
      break;
    }
    body.push(lines[i]);
  }
  if (!closed) return null;

  const out = {};
  const BLOCK = /^[>|][0-9+-]*$/; // >, |, and indent/chomping variants: >-, |2, |4-, …
  for (let i = 0; i < body.length; i++) {
    const line = body[i];
    if (!line.trim() || line.trimStart().startsWith('#')) continue;

    const m = /^([A-Za-z0-9_-]+):(.*)$/.exec(line);
    if (!m) continue; // only top-level (column-0) keys; indented lines are folded in below

    const key = m[1];
    const rest = m[2].trim();

    if (rest === '' || BLOCK.test(rest)) {
      // Block scalar (or a nested mapping like `metadata:`): gather the indented lines.
      const literal = rest.startsWith('|');
      const collected = [];
      while (i + 1 < body.length && (body[i + 1].trim() === '' || /^\s/.test(body[i + 1]))) {
        collected.push(body[++i].replace(/^\s+/, ''));
      }
      out[key] = literal ? collected.join('\n').trim() : collected.join(' ').trim();
    } else {
      // Inline scalar. A plain scalar may fold onto following indented lines — gather them too,
      // or a multi-line description is truncated and its length check silently bypassed.
      const cont = [];
      while (i + 1 < body.length && /^\s/.test(body[i + 1]) && body[i + 1].trim() !== '') {
        cont.push(body[++i].trim());
      }
      out[key] = stripInlineScalar(cont.length ? [rest, ...cont].join(' ') : rest);
    }
  }
  return out;
}

function listSkills() {
  let entries;
  try {
    entries = readdirSync(skillsDir, { withFileTypes: true });
  } catch {
    errors.push(`skills/ directory not found at ${skillsDir}`);
    return [];
  }
  return entries.filter((e) => e.isDirectory()).map((e) => e.name).sort();
}

function validateSkill(name) {
  const dir = join(skillsDir, name);
  const skillPath = join(dir, 'SKILL.md');

  let raw;
  try {
    raw = readFileSync(skillPath, 'utf8');
  } catch {
    errors.push(`${name}: missing SKILL.md`);
    return;
  }

  const fm = parseFrontmatter(raw);
  if (!fm) {
    errors.push(`${name}: SKILL.md has no valid \`---\` frontmatter block`);
    return;
  }

  // name
  if (!fm.name) {
    errors.push(`${name}: frontmatter missing \`name\``);
  } else {
    if (fm.name !== name) {
      errors.push(`${name}: frontmatter name "${fm.name}" must equal the folder name "${name}"`);
    }
    if (!NAME_RE.test(fm.name)) {
      errors.push(`${name}: name "${fm.name}" must be kebab-case (^[a-z0-9]+(-[a-z0-9]+)*$)`);
    }
    if (fm.name.length > NAME_MAX) {
      errors.push(`${name}: name is ${fm.name.length} chars (max ${NAME_MAX})`);
    }
  }

  // description
  if (!fm.description) {
    errors.push(`${name}: frontmatter missing \`description\``);
  } else {
    if (fm.description.length > DESC_MAX) {
      errors.push(`${name}: description is ${fm.description.length} chars (max ${DESC_MAX})`);
    }
    if (!/\b(use|when|for|if)\b/i.test(fm.description)) {
      warnings.push(`${name}: description should say *when* to use the skill (no trigger cue found)`);
    }
  }
}

const skills = listSkills();
if (skills.length === 0 && errors.length === 0) {
  errors.push('no skills found under skills/');
}
for (const name of skills) validateSkill(name);

for (const w of warnings) process.stdout.write(`⚠ ${w}\n`);
for (const e of errors) process.stdout.write(`✗ ${e}\n`);

if (errors.length) {
  process.stdout.write(`\n${errors.length} error(s) across ${skills.length} skill(s).\n`);
  process.exit(1);
}
process.stdout.write(`✓ ${skills.length} skill(s) valid${warnings.length ? `, ${warnings.length} warning(s)` : ''}.\n`);
