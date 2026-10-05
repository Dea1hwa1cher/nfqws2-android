#!/usr/bin/env node
/*
 * Static checks on webroot/index.html — no browser, no dependencies.
 *
 * These guard the invariants that are easy to break by hand and hard to notice:
 * a dangling icon reference, an id the script looks up but nobody renders, an
 * icon set that silently went back to strokes, or an accessible name that got
 * dropped from an icon-only button.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..');
const INDEX = path.join(REPO, 'webroot', 'index.html');

let pass = 0;
const failures = [];
let section = '';

function sect(name) { section = name; process.stdout.write(`\n== ${name}\n`); }
function ok(msg) { pass++; process.stdout.write(`   ok   ${msg}\n`); }
function fail(msg) { failures.push(`[${section}] ${msg}`); process.stdout.write(`   FAIL ${msg}\n`); }
function eq(expected, actual, msg) {
  if (expected === actual) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function truthy(cond, msg) { cond ? ok(msg) : fail(msg); }

const html = fs.readFileSync(INDEX, 'utf8');
const script = (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1] || '';
// The document without the stylesheet and the script — class attributes live here.
const markup = html.replace(/<style>[\s\S]*?<\/style>/, '').replace(/<script>[\s\S]*?<\/script>/, '');

// ── script syntax ─────────────────────────────────────────────────────────────
sect('script');
truthy(script.length > 1000, 'the inline script was found');
try {
  new vm.Script(script, { filename: 'index.html<script>' });
  ok('the inline script parses');
} catch (e) {
  fail(`the inline script does not parse: ${e.message}`);
}
truthy(!/<\/script>/i.test(script), 'the script contains no nested </script>');
truthy(/<script>\s*[\s\S]*?<\/script>\s*<\/body>/.test(html), 'the script is the last thing in body');

// ── icon sprite ───────────────────────────────────────────────────────────────
sect('icon sprite');

const symbols = [...html.matchAll(/<symbol id="([^"]+)"/g)].map(m => m[1]);
truthy(symbols.length > 20, `the sprite defines ${symbols.length} symbols`);
eq(symbols.length, new Set(symbols).size, 'symbol ids are unique');

const refs = new Set();
for (const m of html.matchAll(/href="#(i-[A-Za-z0-9-]+)"/g)) refs.add(m[1]);
for (const m of html.matchAll(/icon:\s*'([A-Za-z0-9-]+)'/g)) refs.add('i-' + m[1]);

// Icon names also arrive as arguments to icon(...) — including ternaries such as
// icon(j.running ? 'stop' : 'play'). Scan the call with balanced parentheses and
// take every quoted string inside, ignoring the size class ('s16'…'s24').
// A plain ternary regex would be wrong here: `? 'light' : 'dark'` is a theme
// mode, not an icon.
function iconCallNames(src) {
  const found = new Set();
  let i = 0;
  while ((i = src.indexOf('icon(', i)) !== -1) {
    let depth = 1, j = i + 5;
    while (j < src.length && depth > 0) {
      const c = src[j];
      if (c === '(') depth++;
      else if (c === ')') depth--;
      j++;
    }
    const arg = src.slice(i + 5, j - 1);
    for (const m of arg.matchAll(/'([A-Za-z0-9_-]+)'/g)) {
      if (!/^s\d+$/.test(m[1])) found.add('i-' + m[1]);
    }
    i = j;
  }
  return found;
}
for (const n of iconCallNames(script)) refs.add(n);

const dangling = [...refs].filter(r => !symbols.includes(r)).sort();
eq('', dangling.join(','), 'every icon reference resolves to a symbol');

// A symbol nothing points at is dead weight; keep the sprite honest.
const unused = symbols.filter(s => {
  if (refs.has(s)) return false;
  const short = s.replace(/^i-/, '');
  return !new RegExp(`['"]${short}['"]`).test(html);
});
eq('', unused.join(','), 'no unused symbols are shipped');

sect('icon rendering');
const iconRule = (html.match(/svg\.icon\s*\{[^}]*\}/) || [''])[0];
truthy(/fill:\s*currentColor/.test(iconRule), 'svg.icon paints with currentColor');
truthy(!/stroke:/.test(iconRule), 'svg.icon does not fall back to strokes');
truthy(/viewBox="0 -960 960 960"/.test(html), 'symbols use the Material Symbols viewBox');
truthy(!/viewBox="0 0 24 24"/.test(html), 'no symbol is left on the old 24x24 viewBox');

// ── colour roles have exactly one source ──────────────────────────────────────
sect('colour roles');

// The palette is generated from a seed at runtime (roles() -> applyTheme()), so
// it cannot live in CSS as well: two copies of the same value, and the CSS one
// would silently lose to the generated rule. That is exactly how the palette
// ended up dead once. Only roles applyTheme() does not write may be styled here.
const styleBlock = (html.match(/<style>([\s\S]*?)<\/style>/) || ['', ''])[1];
const roleVarsInCss = [...new Set([...styleBlock.matchAll(/--md-sys-color-([a-z-]+)\s*:/g)].map(m => m[1]))].sort();
eq('scrim', roleVarsInCss.join(','), 'CSS defines only the roles applyTheme does not write');
truthy(/<style id="theme-vars"><\/style>/.test(html), 'the generated palette has its own <style> element');
truthy(/\$\('theme-vars'\)\.textContent\s*=/.test(script), 'applyTheme writes the palette into #theme-vars');
truthy(!/documentElement\.style\.setProperty\(\s*'--md-sys-color/.test(script),
  'no colour role is written as an inline style (inline cannot be overridden from CSS)');
truthy(!/style\.setProperty\(\s*ROLE_VAR/.test(script), 'the ROLE_VAR map is not applied inline');
// The status trio follows the same rule.
truthy(!/^\s*--status-ok:/m.test(styleBlock), 'the status colours are not duplicated in CSS either');

// ── every CSS class is reachable ──────────────────────────────────────────────
sect('css classes are used');

// Dead rules pile up silently: ~90 lines of chips/kv/pill/empty CSS sat unused
// until the 2026-10-05 review, because nothing ever looked. A class counts as
// used if the markup, a class string in the script, or a classList call names it.
const usedClasses = new Set();
for (const m of markup.matchAll(/class="([^"]*)"/g)) m[1].split(/\s+/).forEach(c => c && usedClasses.add(c));
for (const m of script.matchAll(/class=\\?"([^"]*)/g)) m[1].split(/[\s'+]+/).forEach(c => c && usedClasses.add(c));
for (const m of script.matchAll(/className\s*=\s*'([^']*)'/g)) m[1].split(/\s+/).forEach(c => c && usedClasses.add(c));
for (const m of script.matchAll(/classList\.(?:add|remove|toggle)\(([^)]*)\)/g)) {
  for (const q of m[1].matchAll(/'([\w-]+)'/g)) usedClasses.add(q[1]);
}

// The type scale is a deliberate utility layer: not every step is in use yet.
const CLASS_WHITELIST = /^t-/;
// Only class names, not pseudo-elements (::after) or decimal values.
const cssClasses = new Set(
  [...styleBlock.matchAll(/(?<![:\w])\.([a-z][a-z0-9-]*)/gi)].map(m => m[1]));
const deadClasses = [...cssClasses]
  .filter(c => !usedClasses.has(c) && !CLASS_WHITELIST.test(c)).sort();
eq('', deadClasses.join(','), `every CSS class is reachable (${cssClasses.size} classes checked)`);

// ── ids the script looks up ───────────────────────────────────────────────────
sect('element ids');

const htmlIds = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
// ids created by the script's own innerHTML templates
for (const m of script.matchAll(/\bid="([A-Za-z0-9_-]+)"/g)) htmlIds.add(m[1]);
for (const m of script.matchAll(/id="'\s*\+\s*[A-Za-z0-9_]+/g)) { /* dynamic, skip */ }

const looked = new Set();
for (const m of script.matchAll(/\$\(\s*'([^']+)'\s*\)/g)) looked.add(m[1]);
for (const m of script.matchAll(/getElementById\(\s*'([^']+)'\s*\)/g)) looked.add(m[1]);

const missing = [...looked].filter(id => !htmlIds.has(id) && !/^[a-z]+\d*$/.test(id)).sort();
eq('', missing.join(','), 'every id the script looks up exists in the markup');
truthy(looked.size > 40, `the script looks up ${looked.size} ids`);

// ── accessibility invariants ──────────────────────────────────────────────────
sect('accessibility');

const viewport = (html.match(/<meta name="viewport" content="([^"]+)"/) || [])[1] || '';
truthy(viewport.length > 0, 'a viewport meta tag is present');
truthy(!/user-scalable\s*=\s*no/.test(viewport), 'zoom is not disabled (WCAG 1.4.4)');
truthy(/viewport-fit=cover/.test(viewport), 'viewport-fit=cover is kept for insets');

const layerTag = (html.match(/<div id="layer"[^>]*>/) || [''])[0];
truthy(layerTag.length > 0, 'the overlay layer exists');
truthy(!/aria-hidden/.test(layerTag), 'the overlay layer is not aria-hidden (menus render into it)');

let unlabelled = 0;
for (const m of html.matchAll(/<button\b[^>]*>([\s\S]*?)<\/button>/g)) {
  const tag = m[0].slice(0, m[0].indexOf('>'));
  const body = m[1].replace(/<[^>]+>/g, '').trim();
  if (!body && !/aria-label=/.test(tag)) { unlabelled++; fail(`an icon-only button has no aria-label: ${tag.slice(0, 90)}`); }
}
if (!unlabelled) ok('every button has text or an aria-label');

let switches = 0;
for (const m of html.matchAll(/<input[^>]*role="switch"[^>]*>/g)) {
  switches++;
  truthy(/aria-label=/.test(m[0]), 'a role="switch" input carries an aria-label');
}
truthy(switches > 0, `found ${switches} switch inputs`);

truthy(/prefers-reduced-motion/.test(html), 'reduced motion is honoured');
truthy(/:focus-visible/.test(html), 'a focus-visible style is defined');
truthy(/role="status"/.test(html) && /aria-live="polite"/.test(html), 'the snackbar is a polite live region');

// ── markup hygiene ────────────────────────────────────────────────────────────
sect('markup hygiene');
truthy(!/\son[a-z]+\s*=\s*"/i.test(html.replace(/on(click|change|input|keydown|blur|submit|pointerdown)="/g, '')), 'no stray inline handlers');
truthy((html.match(/<html/g) || []).length === 1, 'exactly one <html> element');
truthy(/<meta charset="utf-8">/.test(html), 'the document declares utf-8');
truthy(/lang="ru"/.test(html), 'the document declares its language');
truthy(!/\t/.test(html.split('\n').filter(l => l.includes('<')).join('\n')), 'no tabs inside markup lines');

// ── summary ───────────────────────────────────────────────────────────────────
process.stdout.write('\n----------------------------------------\n');
if (failures.length === 0) {
  process.stdout.write(`PASS  ${pass} checks\n`);
  process.exit(0);
}
process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
for (const f of failures) process.stdout.write(`   - ${f}\n`);
process.exit(1);
