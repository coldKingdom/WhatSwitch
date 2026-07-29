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
 * So this looks. Point it at the sibling checkout and it diffs the shared files.
 *
 * Usage:
 *   node scripts/check-lib-parity.mjs                      # auto-detect the sibling repo
 *   node scripts/check-lib-parity.mjs <path-to-other-repo> # explicit
 *
 * Exit 0 = in sync (or the sibling isn't present locally, which is not a failure - CI on a
 * single repo can't see the other one). Exit 1 = drift, with a diff summary.
 *
 * NOT CHECKED: catalog.ts. It legitimately diverges - the marketing copy carries catalogSlug()
 * for its /switchhunt/<slug> routes and the public copy has no such pages. Entry PARITY there is
 * a different question; compare CATALOG.md counts instead.
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');

/** Files that MUST be byte-identical everywhere. Pure engine code, no repo-specific logic. */
const SHARED = ['msi.ts', 'installerDetect.ts', 'burn.ts', 'intunewin.ts', 'psadt.ts'];

/** Where the other copy might live. Extend when a third home lands. */
const CANDIDATES = [
  resolve(repoRoot, '..', 'rff-marketing'),
  resolve(repoRoot, '..', 'SwitchHunt'),
  'C:/temp/rff-marketing',
  'C:/Temp/SwitchHunt',
];

const explicit = process.argv[2];
const others = explicit
  ? [resolve(explicit)]
  : CANDIDATES.filter((p) => resolve(p) !== repoRoot && existsSync(join(p, 'src', 'lib')));

if (others.length === 0) {
  console.log('check-lib-parity: no sibling checkout found locally - skipping (not a failure).');
  process.exit(0);
}

let failed = false;
for (const other of others) {
  console.log(`\nComparing against ${other}`);
  for (const f of SHARED) {
    const a = join(repoRoot, 'src', 'lib', f);
    const b = join(other, 'src', 'lib', f);
    if (!existsSync(a) || !existsSync(b)) {
      console.log(`  ${f.padEnd(22)} SKIP (missing on one side)`);
      continue;
    }
    // Normalise line endings only - the repos disagree about CRLF via .gitattributes, and that
    // is not drift anyone needs to act on.
    const norm = (p) => readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
    const [x, y] = [norm(a), norm(b)];
    if (x === y) {
      console.log(`  ${f.padEnd(22)} ok`);
      continue;
    }
    failed = true;
    const xl = x.split('\n');
    const yl = y.split('\n');
    let firstDiff = 0;
    while (firstDiff < xl.length && firstDiff < yl.length && xl[firstDiff] === yl[firstDiff]) firstDiff++;
    console.log(`  ${f.padEnd(22)} DRIFT - first difference at line ${firstDiff + 1}`);
    console.log(`      this repo : ${(xl[firstDiff] ?? '(eof)').trim().slice(0, 100)}`);
    console.log(`      other repo: ${(yl[firstDiff] ?? '(eof)').trim().slice(0, 100)}`);
  }
}

if (failed) {
  console.error(
    '\nShared engine files have drifted. Apply the change to EVERY copy before committing.\n' +
    'See the banner at the top of each file for the list of homes.',
  );
  process.exit(1);
}
console.log('\nAll shared engine files are in sync.');
