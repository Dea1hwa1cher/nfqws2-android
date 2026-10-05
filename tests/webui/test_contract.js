#!/usr/bin/env node
/*
 * Contract tests between the WebUI and bin/nfqws2-ctl.
 *
 * The WebUI is a single file that parses the module's output and sends command
 * names and values back. Nothing in either file knows about the other, so a
 * rename on one side only shows up as a broken UI on a phone. These checks run
 * the *real* ctl in a sandbox and compare it against what index.html expects.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const INDEX = path.join(REPO, 'webroot', 'index.html');
const CTL = path.join(REPO, 'bin', 'nfqws2-ctl');

// The ctl output is produced by tests/run.sh (via tests/lib/dump-ctl.sh) and
// handed over as files: spawning a shell from Node is not portable — on this
// machine every child process is refused with EBUSY — and keeping the shell
// side in shell is simpler anyway.
const statusFile = process.argv[2];
const strategiesFile = process.argv[3];
if (!statusFile || !strategiesFile) {
  process.stdout.write(
    'test_contract.js needs the ctl output as files:\n' +
    '  node test_contract.js <json-status.txt> <list-strategies.txt>\n' +
    'Run it through tests/run.sh instead.\n');
  process.exit(2);
}

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
function empty(list, msg) { eq('', [...new Set(list)].sort().join(','), msg); }

const html = fs.readFileSync(INDEX, 'utf8');
const ctlSrc = fs.readFileSync(CTL, 'utf8');

// ── json-status is parseable and complete ─────────────────────────────────────
sect('json-status');

const raw = fs.readFileSync(statusFile, 'utf8');
const jsonText = raw.slice(raw.indexOf('{'), raw.lastIndexOf('}') + 1);
let status = null;
try {
  status = JSON.parse(jsonText);
  ok('the ctl output is valid JSON');
} catch (e) {
  fail(`the ctl output is not valid JSON: ${e.message}`);
}

if (status) {
  // Keys the script actually reads off the status object.
  const readKeys = new Set();
  for (const m of html.matchAll(/\b(?:j|S)\.([a-z_]+)\b/g)) readKeys.add(m[1]);
  // The switch rows read their field through the KEY map (j[KEY[...]]), so those
  // names never appear as a literal property access.
  const keyMapBody = (html.match(/const KEY = \{([^}]*)\}/) || ['', ''])[1];
  for (const m of keyMapBody.matchAll(/:\s*'([a-z0-9_]+)'/g)) readKeys.add(m[1]);

  const missing = [...readKeys].filter(k => !(k in status));
  empty(missing, `every status key the WebUI reads exists (${readKeys.size} keys checked)`);

  // And the other direction: nothing should be computed and shipped without a
  // consumer. `tls_strategies`/`udp_strategies` used to cost two norm_args
  // pipelines on every single call and were never displayed.
  const unread = Object.keys(status).filter(k => !readKeys.has(k));
  empty(unread, 'no field is emitted without being read');

  // `c` is only the counts object inside stat(); scanning the whole file would
  // also match unrelated `c.something` from CSS rules and event objects.
  const statBody = (html.match(/async function stat\(\)\{[\s\S]*?\n\}/) || [''])[0];
  const countSrc = new Set([...statBody.matchAll(/c\.([a-z_]+)/g)].map(m => m[1]));
  const counts = status.counts || {};
  const missingCounts = [...countSrc].filter(k => !(k in counts) && k !== 'ipset_excl');
  empty(missingCounts, 'every counts key the WebUI reads exists');

  // The KEY map turns config names into status keys; a rename would silently
  // make every switch read `undefined`.
  const keyMap = html.match(/const KEY = \{([^}]*)\}/);
  if (keyMap) {
    const mapped = [...keyMap[1].matchAll(/:\s*'([a-z0-9_]+)'/g)].map(m => m[1]);
    const missingMapped = mapped.filter(k => !(k in status));
    empty(missingMapped, 'every switch maps to a status key that exists');
    truthy(mapped.length >= 5, `${mapped.length} switches are mapped`);
  } else {
    fail('the KEY map was not found in index.html');
  }

  // Fields the WebUI compares or does arithmetic on must be numbers.
  const numeric = ['pkt_limit_out', 'pkt_limit_in', 'block_quic', 'autostart', 'watchdog',
    'wakelock_on', 'ipv6', 'log_level', 'qdrop', 'queue', 'app_uids', 'uptime'];
  const notNumbers = numeric.filter(k => typeof status[k] !== 'number');
  empty(notNumbers, 'every field the WebUI compares numerically is a JSON number');

  truthy(typeof status.running === 'boolean', 'running is a boolean');
  truthy(typeof status.pid === 'string', 'pid is a string');
  truthy(typeof status.version === 'string', 'version is a string');
  truthy(typeof status.mode === 'string', 'mode is a string');
  truthy(Array.isArray(Object.values(status.counts).filter(v => typeof v !== 'number')) === false
    || Object.values(status.counts).every(v => typeof v === 'number'),
    'every counter is a number');

  // Version shown in the app bar must match module.prop.
  const propVersion = (fs.readFileSync(path.join(REPO, 'module.prop'), 'utf8')
    .match(/^version=(.*)$/m) || [])[1];
  eq(propVersion, status.version, 'the reported version matches module.prop');
  const fallback = (html.match(/id="header-version">([^<]*)</) || [])[1];
  eq(propVersion, fallback, 'the hard-coded fallback version in the markup matches module.prop');
}

// ── strategy list ─────────────────────────────────────────────────────────────
sect('strategies');

const strategies = fs.readFileSync(strategiesFile, 'utf8').trim().split('\n').filter(Boolean);
truthy(strategies.length > 5, `the ctl offers ${strategies.length} strategies`);
truthy(!strategies.includes('default'),
  'the ctl does not list "default" (the WebUI prepends it)');
truthy(/const options = \['default', \.\.\.strats/.test(html),
  'the WebUI prepends "default" itself, matching the ctl');
truthy(/STRATEGY_INFO/.test(html), 'the WebUI carries descriptions for the strategies');

// ── command vocabulary ────────────────────────────────────────────────────────
sect('commands the WebUI sends');

const ctlCommands = new Set(
  [...ctlSrc.matchAll(/^\s{2}([a-z][a-z0-9-]*)\)/gm)].map(m => m[1])
);
truthy(ctlCommands.size > 20, `the ctl dispatches ${ctlCommands.size} commands`);

// ctl(['name', ...]) — the array form the WebUI uses for most calls.
const sent = new Set();
for (const m of html.matchAll(/\bctl\(\s*\[\s*'([a-z0-9-]+)'/g)) sent.add(m[1]);
for (const m of html.matchAll(/\bctlx\(\s*\[\s*'([a-z0-9-]+)'/g)) sent.add(m[1]);
for (const m of html.matchAll(/withBusy\(\s*\[\s*'([a-z0-9-]+)'/g)) sent.add(m[1]);
empty([...sent].filter(c => !ctlCommands.has(c)),
  `every command the WebUI sends exists in the ctl (${sent.size} checked)`);

// ── set: parameters and their allowed values ──────────────────────────────────
sect('set');

const setParams = new Set();
for (const m of ctlSrc.matchAll(/^\s+([A-Z0-9_|]+)\)\s*case "\$3" in/gm)) {
  for (const p of m[1].split('|')) setParams.add(p);
}
truthy(setParams.size >= 8, `the ctl accepts ${setParams.size} settable parameters`);

const wanted = new Set();
for (const m of html.matchAll(/setp\(\s*'([A-Z_]+)'/g)) wanted.add(m[1]);
for (const m of html.matchAll(/set',\s*'([A-Z_]+)'/g)) wanted.add(m[1]);
for (const m of html.matchAll(/'([A-Z_]+)',\s*this\.checked/g)) wanted.add(m[1]);
empty([...wanted].filter(p => !setParams.has(p)),
  `every parameter the WebUI sets is allowed (${wanted.size} checked)`);

// The mode segmented control maps to set-mode.
const modes = (html.match(/\['auto',\s*'list',\s*'all'\]/) || [])[0];
truthy(!!modes, 'the WebUI offers the auto/list/all modes');
truthy(/set-mode\)\s*case "\$2" in list\|auto\|all\)/.test(ctlSrc),
  'set-mode accepts exactly list/auto/all');

// Application filter modes.
const appModes = [...html.matchAll(/<option value="(off|include|exclude)"/g)].map(m => m[1]);
truthy(appModes.length === 3, 'the WebUI offers off/include/exclude for the app filter');
truthy(/APP_MODE\)\s*case "\$3" in off\|include\|exclude\)/.test(ctlSrc),
  'the ctl accepts off/include/exclude for APP_MODE');

// ── lists ─────────────────────────────────────────────────────────────────────
sect('lists');

const listKeys = [...html.matchAll(/^\s*\['([a-z_]+)',\s*'[^']*'\]/gm)].map(m => m[1]);
truthy(listKeys.length >= 6, `the WebUI offers ${listKeys.length} lists`);
const listFileCases = new Set();
for (const m of ctlSrc.matchAll(/^\s*([a-z_|.]+)\)\s*echo "\$LISTS_DIR/gm)) {
  for (const k of m[1].split('|')) listFileCases.add(k.replace(/\.list$/, ''));
}
empty(listKeys.filter(k => !listFileCases.has(k)), 'every list the WebUI offers is known to the ctl');

// ── log sources ───────────────────────────────────────────────────────────────
sect('log sources');

const ltSelect = (html.match(/<select id="lt"[\s\S]*?<\/select>/) || [''])[0];
const logSources = [...ltSelect.matchAll(/value="([a-z]+)"/g)].map(m => m[1]);
truthy(logSources.length >= 4, `the WebUI offers ${logSources.length} log sources`);
// The case ends at `esac`, not at the first `;;` — the branches are on shared lines.
const logCase = (ctlSrc.match(/cmd_get_logs\(\)[\s\S]*?case "\$1" in([\s\S]*?)esac/) || [])[1] || '';
for (const src of logSources) {
  // `service` is deliberately the fallback branch (`*)`); the rest must be named.
  const named = new RegExp(`(^|[\\s;])${src}\\)`).test(logCase);
  truthy(named || src === 'service', `the ctl handles the "${src}" log source`);
}
truthy(/\*\)[^;]*SERVICE_LOG/.test(logCase), 'the unnamed log source falls back to service.log');

// ── summary ───────────────────────────────────────────────────────────────────
process.stdout.write('\n----------------------------------------\n');
if (failures.length === 0) {
  process.stdout.write(`PASS  ${pass} checks\n`);
  process.exit(0);
}
process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
for (const f of failures) process.stdout.write(`   - ${f}\n`);
process.exit(1);
