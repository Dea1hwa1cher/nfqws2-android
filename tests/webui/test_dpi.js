#!/usr/bin/env node
/**
 * test_dpi.js — Unit tests for ported DPI Detector logic:
 * - Error classification (TLS RST, TLS Alert, Spoof, MITM, Drop, Timeout, ISP Redir)
 * - Protocol parsing: NET, H, R, T16, DNS, TG, TG_MEDIA
 * - Report generator formatting
 * - Tab switching
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..');
const TEST_JS = path.join(REPO, 'webroot', 'js', 'test.js');

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

// Setup sandbox environment simulating WebUI globals
const sandbox = {
  console,
  t: str => str,
  esc: str => String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
  icon: (name, sz) => `<svg class="${sz}"><use href="#i-${name}"/></svg>`,
  banner: (t, kind, msg) => `<div class="banner ${kind}">${msg}</div>`,
  stat: async () => {},
  setHTML: (id, html) => {},
  ctlx: async () => ({ code: 0, out: '' }),
  toast: () => {},
  S: { running: true, paused: false },
  document: {
    querySelectorAll: () => [],
    createElement: () => ({ select: () => {}, appendChild: () => {} }),
    body: { appendChild: () => {}, removeChild: () => {} }
  },
  navigator: {},
  $: id => ({ textContent: '', innerHTML: '', hidden: false, disabled: false, insertAdjacentHTML: () => {} })
};

vm.createContext(sandbox);
const code = fs.readFileSync(TEST_JS, 'utf8');
vm.runInContext(code, sandbox);

// ── 1. Error classification dictionary ─────────────────────────────────────
sect('DPI error classification');
const probeReason = vm.runInContext('PROBE_REASON', sandbox);
truthy(typeof probeReason === 'object', 'PROBE_REASON dictionary is exported');
eq('TLS RST (сброс ClientHello)', probeReason.tls_rst, 'tls_rst maps to ClientHello reset');
eq('TLS Alert (SNI блок)', probeReason.tls_alert, 'tls_alert maps to SNI block');
eq('Тихий сброс (Drop)', probeReason.drop, 'drop maps to silent TSPU drop');
eq('Заглушка провайдера (RKN)', probeReason.isp_redir, 'isp_redir maps to RKN block page');
eq('Подмена сертификата (MITM)', probeReason.tls_mitm, 'tls_mitm maps to MITM');
eq('Подмена ответа (Spoof)', probeReason.tls_spoof, 'tls_spoof maps to response spoof');
eq('Ошибка DNS', probeReason.dns_fail, 'dns_fail maps to DNS failure');

// ── 2. Row renderers ───────────────────────────────────────────────────────
sect('row HTML renderers');
const tcpClean = sandbox.renderTcp16Row(0, 'Cloudflare', '172.67.70.222', 443, 'clean', '42ms');
truthy(tcpClean.includes('status ok') && tcpClean.includes('42ms'), 'TCP16 clean row renders with status ok');

const tcpDetected = sandbox.renderTcp16Row(1, 'Hetzner', '91.98.156.82', 443, 'detected', '16KB');
truthy(tcpDetected.includes('status bad') && tcpDetected.includes('16KB'), 'TCP16 detected row renders with status bad');

const dnsRow = sandbox.renderDnsRow(0, 'Google', '8.8.8.8', 'ok', 'ok', 'no', 'OK');
truthy(dnsRow.includes('status ok') && dnsRow.includes('UDP: OK'), 'DNS clean row renders with status ok');

const dnsHijacked = sandbox.renderDnsRow(1, 'ISP DNS', '192.168.1.1', 'ok', 'none', 'yes', 'Заглушка');
truthy(dnsHijacked.includes('status bad') && dnsHijacked.includes('ПЕРЕХВАТ'), 'DNS hijacked row renders with status bad');

const tgRow = sandbox.renderTgRow(0, 'DC2 (Amsterdam)', '149.154.167.51', 'ok', '35ms');
truthy(tgRow.includes('status ok') && tgRow.includes('35ms'), 'TG row renders with status ok');

// ── 3. Report generation ───────────────────────────────────────────────────
sect('report formatting');
vm.runInContext(`
netInfoData = {
  ip: '5.18.158.84',
  loc: 'RU',
  isp: 'Z-Telecom',
  asn: 'AS41733',
  status: 'running',
  strategy: 'fake_tls_auto',
  dns: '8.8.8.8'
};
webResults = {
  0: { host: 'youtube.com', list: [{ ok: true, ms: 30 }, { ok: true, ms: 32 }] }
};
tcp16Results = {
  0: { provider: 'Hetzner', ip: '91.98.156.82', status: 'detected', detail: '16KB' }
};
dnsResults = {
  0: { name: 'Cloudflare', ip: '1.1.1.1', udp: 'ok', doh: 'ok', hijacked: 'no', detail: 'OK' }
};
tgResults = {
  0: { name: 'DC2', ip: '149.154.167.51', status: 'ok', ms: '35ms' }
};
tgMediaSpeed = '12.5 MB/s';
`, sandbox);

let copiedText = '';
sandbox.navigator.clipboard = {
  writeText: async txt => { copiedText = txt; }
};
sandbox.copyTestReport();

truthy(copiedText.includes('### DPI Detector (nfqws2-android)'), 'report header is present');
truthy(copiedText.includes('5.18.158.84') && copiedText.includes('Z-Telecom'), 'network info is present in report');
truthy(copiedText.includes('youtube.com'), 'web test is present in report');
truthy(copiedText.includes('DETECTED @ 16KB'), 'TCP16 test is present in report');
truthy(copiedText.includes('12.5 MB/s'), 'TG media speed is present in report');

// ── 4. Summary ─────────────────────────────────────────────────────────────
console.log(`\n----------------------------------------\nPASS  ${pass} checks`);
if (failures.length) {
  console.error(`FAIL  ${failures.length} check(s) failed`);
  process.exit(1);
}
process.exit(0);
