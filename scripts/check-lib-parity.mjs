#!/usr/bin/env node
/**
 * Fail when a SHARED ENGINE FILE has drifted between its copies.
 *
 * WHY THIS EXISTS. The installer-parsing engine lives byte-identical in more than one repo
 * (the public SwitchHunt tool and the hosted copy on the marketing site, with RFF.Web planned).
 * A banner comment at the top of each file asks you to keep them in sync. Banners do not work:
 * measured 2026-07-29, within ONE HOUR of a deliberate sync, installerDetect.ts and burn.ts were
 * both already out of step - in OPPOSITE directions. One had a fix the other lacked, and vice
 * versa. Nobody noticed because nothing was looking.
 *
 * So this looks.
 *
 * Usage:
 *   node scripts/check-lib-parity.mjs                     auto-detect a sibling checkout
 *   node scripts/check-lib-parity.mjs <path>              compare against an explicit path
 *   node scripts/check-lib-parity.mjs --require <path>    CI mode - see below
 *
 * --require is MANDATORY IN CI. Without it, three different mishaps all produce a green build
 * that compared nothing:
 *   - the sibling checkout step failed  -> no candidates      -> exit 0 "skipping"
 *   - the path is wrong                 -> every file MISSING -> exit 0 having skipped them all
 *   - someone renames the shared files  -> zero compared      -> exit 0
 * Under --require each of those is a failure. A check that cannot prove it ran must not pass.
 *
 * NOT CHECKED: catalog.ts. It legitimately diverges - the marketing copy carries catalogSlug()
 * for its /switchhunt/<slug> routes and the public copy has no such pages. Entry parity there is
 * a different question; compare CATALOG.md counts instead.
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

/** Files that MUST be byte-identical everywhere. Pure engine code, no repo-specific logic. */
const SHARED = ['msi.ts', 'installerDetect.ts', 'burn.ts', 'intunewin.ts', 'psadt.ts'];

/** Where the other copy might live locally. Extend when a third home lands. */
const CANDIDATES = [
  resolve(repoRoot, '..', 'rff-marketing'),
  resolve(repoRoot, '..', 'SwitchHunt'),
  'C:/temp/rff-marketing',
  'C:/Temp/SwitchHunt',
];

const REQUIRE = process.argv.includes('--require');
const explicit = process.argv.slice(2).find((a) => !a.startsWith('--'));

const others = explicit
  ? [resolve(explicit)]
  : CANDIDATES.filter((p) => resolve(p) !== repoRoot && existsSync(join(p, 'src', 'lib')));

if (others.length === 0) {
  if (REQUIRE) {
    console.error('check-lib-parity: --require was set but no sibling checkout was found.');
    console.error('Nothing was compared. Failing rather than reporting a pass it did not earn.');
    process.exit(1);
  }
  console.log('check-lib-parity: no sibling checkout found locally - skipping (not a failure).');
  process.exit(0);
}

let failed = false;
let compared = 0;

for (const other of others) {
  console.log('');
  console.log('Comparing against ' + other);
  for (const f of SHARED) {
    const a = join(repoRoot, 'src', 'lib', f);
    const b = join(other, 'src', 'lib', f);

    if (!existsSync(a) || !existsSync(b)) {
      // Under --require a missing file is a FAILURE. An explicit-but-wrong path makes `others`
      // non-empty, so every file would "skip" and the script would exit 0 having compared
      // nothing - a check that passes without checking.
      console.log('  ' + f.padEnd(22) + (REQUIRE ? 'MISSING - cannot compare' : 'SKIP (missing on one side)'));
      if (REQUIRE) failed = true;
      continue;
    }

    // Normalise line endings only - the repos disagree about CRLF via .gitattributes, and that
    // is not drift anyone needs to act on.
    const norm = (p) => readFileSync(p, 'utf8').split('\r\n').join('\n');
    const x = norm(a);
    const y = norm(b);
    compared++;

    if (x === y) {
      console.log('  ' + f.padEnd(22) + 'ok');
      continue;
    }

    failed = true;
    const xl = x.split('\n');
    const yl = y.split('\n');
    let i = 0;
    while (i < xl.length && i < yl.length && xl[i] === yl[i]) i++;
    console.log('  ' + f.padEnd(22) + 'DRIFT - first difference at line ' + (i + 1));
    console.log('      this repo : ' + String(xl[i] ?? '(eof)').trim().slice(0, 100));
    console.log('      other repo: ' + String(yl[i] ?? '(eof)').trim().slice(0, 100));
  }
}

if (REQUIRE && compared === 0) {
  console.error('');
  console.error('check-lib-parity: --require was set but ZERO files were actually compared.');
  process.exit(1);
}

if (failed) {
  console.error('');
  console.error('Shared engine files have drifted, or could not be compared.');
  console.error('Apply the change to EVERY copy before committing. See the banner at the top of each file.');
  process.exit(1);
}

console.log('');
console.log('All shared engine files are in sync (' + compared + ' compared).');
