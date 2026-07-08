#!/usr/bin/env node
// Wire the canonical skills/ folder into the directories each agent tool scans.
//
//   node scripts/install.mjs            recreate the repo-local links
//                                       (.claude/skills, .agents/skills, .opencode/skills)
//   node scripts/install.mjs --global   also link every skill into the per-user tool dirs
//   node scripts/install.mjs --force     replace a real (non-symlink) dir/file in the way
//
// Symlinks are preferred. When they cannot be created (Windows without developer mode,
// core.symlinks=false, restricted filesystems) we fall back to copying the tree so the skills
// still resolve. We never delete a real directory that is already in place unless you pass
// --force, so an existing skill you put there by hand (or a previous copy) is left untouched.

import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readlinkSync,
  rmSync,
  symlinkSync,
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..');
const skillsDir = join(repoRoot, 'skills');

const global = process.argv.includes('--global');
const force = process.argv.includes('--force');

let created = 0;
let copied = 0;
let skipped = 0;
let failed = 0;

function log(symbol, message) {
  process.stdout.write(`${symbol} ${message}\n`);
}

// Point `linkPath` at `target`.
//   relativeTarget=true  stores a path relative to the link's own directory — best for
//                        repo-local links, which then keep working if the repo is moved.
//   relativeTarget=false stores an absolute path — best for global links, which must keep
//                        resolving no matter where the repo lives.
// Returns 'linked' | 'copied' | 'skipped' | 'failed'.
function link(linkPath, target, { relativeTarget }) {
  mkdirSync(dirname(linkPath), { recursive: true });

  const linkValue = relativeTarget ? relative(dirname(linkPath), target) : resolve(target);

  if (isSymlink(linkPath)) {
    if (resolveLink(linkPath) === resolve(target)) {
      skipped++;
      log('=', `${rel(linkPath)} already links here`);
      return 'skipped';
    }
    // A stale/broken symlink is ours to replace — removing a link never loses data.
    rmSync(linkPath, { force: true });
  } else if (existsSync(linkPath)) {
    // A real file/dir is here — a previous copy fallback, or a skill the user placed by hand.
    // Never delete it implicitly; that is how a naive --global run could wipe a user's skill.
    if (!force) {
      skipped++;
      log('=', `${rel(linkPath)} exists and is not a link — leaving it (pass --force to replace)`);
      return 'skipped';
    }
    rmSync(linkPath, { recursive: true, force: true });
  }

  // Use a 'dir' symlink (not a junction): junctions force an absolute target resolved against
  // the CWD, which silently breaks the relative repo-local target. A real symlink honors the
  // target relative to the link's own directory on every platform.
  try {
    symlinkSync(linkValue, linkPath, 'dir');
    created++;
    log('+', `${rel(linkPath)} -> ${linkValue}`);
    return 'linked';
  } catch (err) {
    // Symlinks unavailable — copy instead so the skills still resolve (stale until re-run).
    try {
      cpSync(target, linkPath, { recursive: true });
      copied++;
      log('c', `${rel(linkPath)} (copied — symlink unavailable: ${err.code || err.message})`);
      return 'copied';
    } catch (copyErr) {
      failed++;
      log('!', `${rel(linkPath)} failed: ${copyErr.message}`);
      return 'failed';
    }
  }
}

function isSymlink(p) {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
}

function resolveLink(p) {
  try {
    return resolve(dirname(p), readlinkSync(p));
  } catch {
    return null;
  }
}

function rel(p) {
  const r = relative(repoRoot, p);
  return r.startsWith('..') ? p : r;
}

function installRepoLocal() {
  // Each tool scans a different directory; all three point at the one skills/ folder. OpenCode
  // reads all three (.opencode plus .claude and .agents) but dedups skills by name/precedence,
  // so aiming them at a single source does not double-load. Repo-local links stay relative.
  for (const toolDir of ['.claude', '.agents', '.opencode']) {
    link(join(repoRoot, toolDir, 'skills'), skillsDir, { relativeTarget: true });
  }
}

function installGlobal() {
  // Per-user skill directories. Every skill is linked individually so unrelated skills already
  // installed there are left untouched. Claude Code reads ~/.claude/skills; Codex reads
  // ~/.agents/skills; OpenCode reads both, so these two dirs cover all three tools. Global links
  // use an absolute target so they survive the repo being moved.
  const targets = [
    join(homedir(), '.claude', 'skills'),
    join(homedir(), '.agents', 'skills'),
  ];
  const skills = readdirSync(skillsDir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);

  for (const dest of targets) {
    for (const name of skills) {
      link(join(dest, name), join(skillsDir, name), { relativeTarget: false });
    }
  }
}

log('·', `skills source: ${skillsDir}`);
installRepoLocal();
if (global) installGlobal();

const parts = [];
if (created) parts.push(`${created} linked`);
if (copied) parts.push(`${copied} copied`);
if (skipped) parts.push(`${skipped} up to date`);
if (failed) parts.push(`${failed} failed`);
log('·', parts.join(', ') || 'nothing to do');

if (failed) process.exit(1);
