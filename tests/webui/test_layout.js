#!/usr/bin/env node
/*
 * Browser tests for webroot/index.html: rendered geometry, plus the handful of
 * interactions whose cost or correctness only shows up in a real page (the
 * package search, which must not shell out per keystroke).
 *
 * The page is a KernelSU WebUI: it renders its lists from `ksu.exec` output, so
 * opening the file in a browser shows an empty skeleton and every visual
 * conclusion drawn from it is wrong. This test stubs the bridge, renders the
 * page in headless Chromium at real device widths and asserts the geometry —
 * which is how the layout regressions fixed on 2026-10-04 were found, and what
 * keeps them from coming back.
 *
 * Needs playwright + a chromium build; exits 0 with SKIP when absent.
 */
'use strict';

const path = require('path');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  process.stdout.write('SKIP  playwright is not installed (set NODE_PATH to a workspace that has it)\n');
  process.exit(0);
}

const REPO = path.resolve(__dirname, '..', '..');
const INDEX = 'file:///' + path.join(REPO, 'webroot', 'index.html').replace(/\\/g, '/');

const STATUS = JSON.stringify({
  running: true, pid: '4710', uptime: 52, strategy: 'alt13', version: 'v1.3.6', mode: 'auto',
  limiter: 'connmark_out', pkt_limit_out: 2, pkt_limit_in: 2, block_quic: 0, app_mode: 'off',
  autostart: 1, watchdog: 1, wakelock_on: 0, ipv6: 1, log_level: 0, qdrop: 0, queue: 300,
  app_uids: 1,
  counts: { user: 381, auto: 25, exclude: 2839, ipset: 28420, ipset_exclude: 637, apps: 1 },
});
const STRATEGIES = 'default\nalt\nalt2\nalt3\nalt13\nfake_tls_auto\nsimple_fake\nhardcorp74\nkrushaaa\nMartinBacker\nUvvi2\neduncey\nexp';

const STUB = `
window.__calls = [];
window.ksu = { exec: function(cmd, opts, cb){
  var args = [opts, cb], id = null;
  for (var i = args.length - 1; i >= 0; i--) {
    if (typeof args[i] === 'string') { id = args[i]; break; }
  }
  window.__calls.push(cmd);
  var out = 'OK';
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)};
  else if (cmd.indexOf('list-strategies') >= 0) out = ${JSON.stringify(STRATEGIES)};
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt13';
  else if (cmd.indexOf('get-list') >= 0 && cmd.indexOf('apps') >= 0) out = 'com.termux\\ncom.example.one';
  else if (cmd.indexOf('get-list') >= 0) out = 'example.com';
  else if (cmd.indexOf('list-apps') >= 0) out = 'com.termux\\ncom.example.one\\ncom.example.two\\ncom.other';
  else if (cmd.indexOf('get-conf') >= 0) out = 'A=1';
  setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 0);
  return 'job';
}};
`;

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

const VIEWPORTS = [
  { w: 360, dpr: 2.75, label: '360px' },
  { w: 400, dpr: 2.7, label: '400px' },
  { w: 467, dpr: 2.31, label: '467px (owner device)' },
];

(async () => {
  const browser = await chromium.launch();

  for (const vp of VIEWPORTS) {
    for (const mode of ['dark', 'light']) {
      const ctx = await browser.newContext({
        viewport: { width: vp.w, height: 900 },
        deviceScaleFactor: vp.dpr, isMobile: true, hasTouch: true,
      });
      await ctx.addInitScript(`try{localStorage.setItem('m3_mode','${mode}');}catch(e){}`);
      await ctx.addInitScript(STUB);
      const page = await ctx.newPage();
      const pageErrors = [];
      page.on('pageerror', e => pageErrors.push(e.message));
      await page.goto(INDEX, { waitUntil: 'load' });
      await page.waitForTimeout(700);
      // #mode and the other list-driven controls are built by listsInit(),
      // which only runs when the user opens that page.
      await page.evaluate(() => listsInit());
      await page.waitForTimeout(300);

      const label = `${vp.label} ${mode}`;
      sect(label);

      eq('', pageErrors.join(' | '), 'the page loads without script errors');

      const geo = await page.evaluate(() => {
        const cs = el => getComputedStyle(el);
        const box = el => el.getBoundingClientRect();
        const q = s => document.querySelector(s);
        // borderRadius comes back as a shorthand: one value means all four
        // corners, two mean vertical/horizontal pairs.
        const radii = el => {
          const parts = cs(el).borderRadius.split(/\s+/).map(v => parseFloat(v));
          if (parts.length === 1) return [parts[0], parts[0], parts[0], parts[0]];
          if (parts.length === 2) return [parts[0], parts[1], parts[0], parts[1]];
          if (parts.length === 3) return [parts[0], parts[1], parts[2], parts[1]];
          return parts;
        };
        const out = {};

        out.statusText = q('#st').textContent;
        out.heroCounters = document.querySelectorAll('.hero-metrics, .hero .m').length;
        out.metricTiles = [...document.querySelectorAll('#cnt .metric')].map(m => ({
          label: m.querySelector('.metric-label').textContent,
          value: m.querySelector('.metric-value').textContent,
        }));
        out.metricColumns = cs(q('#cnt')).gridTemplateColumns.split(' ').length;

        const split = q('#act-split');
        out.splitHeight = box(split).height;
        out.splitMainRadius = radii(q('#bt'));
        out.splitMenuRadius = radii(q('.split .seg-menu'));
        out.splitGap = box(q('#bt-menu')).left - box(q('#bt')).right;

        out.cardRadius = radii(q('.card.filled'))[0];
        out.heroRadius = radii(q('.hero'))[0];

        const sws = [...document.querySelectorAll('#sws .list-item')];
        out.swsFirstRadius = radii(sws[0]);
        out.swsLastRadius = radii(sws[sws.length - 1]);
        out.swsMiddleRadius = sws.length > 2 ? radii(sws[1]) : [];
        out.swsRows = sws.length;
        out.swsHasIcons = sws.some(r => r.querySelector('.li-icon'));
        out.swsHasSecondary = sws.some(r => r.querySelector('.li-secondary'));
        out.swsHeight = box(sws[0]).height;

        out.strategyRowRadius = radii(q('#strategy-row'))[0];
        out.doctorRowRadius = radii(q('#doctor-row'))[0];

        out.fieldHeight = box(q('.field input, .field select')).height;
        out.fieldRadius = radii(q('.field input, .field select'));

        const segs = [...document.querySelectorAll('#mode .seg')];
        out.segCount = segs.length;
        if (segs.length) {
          out.segFirst = radii(segs[0]);
          out.segLast = radii(segs[segs.length - 1]);
          out.segGap = segs.length > 1 ? box(segs[1]).left - box(segs[0]).right : 0;
        }

        const icons = [...document.querySelectorAll('svg.icon')];
        out.iconCount = icons.length;
        out.iconFill = icons.length ? cs(icons[0]).fill : '';
        out.iconStroke = icons.length ? cs(icons[0]).stroke : '';
        // Icons inside closed overlays (.fs-dialog, .sheet, .dialog-wrap) have no
        // box at all — only judge the ones that are actually on screen.
        out.zeroSizedIcons = icons
          .filter(i => i.getClientRects().length > 0)
          .filter(i => { const b = box(i); return b.width < 8 || b.height < 8; }).length;
        out.visibleIcons = icons.filter(i => i.getClientRects().length > 0).length;

        // The palette must not be inline: an inline role cannot be overridden
        // from CSS, which is how the CSS palette silently became dead code.
        out.inlineRoleVars = (document.documentElement.getAttribute('style') || '').includes('--md-sys-color-');
        out.themeVarsRule = (document.getElementById('theme-vars').textContent || '').trim().slice(0, 6);

        // Generic overflow check on the containers that must never scroll sideways.
        out.overflow = ['.content', '.hero', '.card.filled'].map(sel => {
          const el = q(sel);
          return el ? el.scrollWidth - el.clientWidth : 0;
        });
        out.docOverflow = document.documentElement.scrollWidth - document.documentElement.clientWidth;

        // Every tappable thing should be at least 40px in one dimension.
        out.tinyTargets = [...document.querySelectorAll('.btn, .icon-btn, .seg, .switch, .checkbox')]
          .filter(el => { const b = box(el); return b.height > 0 && b.height < 32; }).length;

        return out;
      });

      // ── hero / counters ──
      eq('Служба запущена', geo.statusText, 'the service state is rendered from json-status');
      eq(0, geo.heroCounters, 'the hero carries no counters any more (they moved to their own card)');
      eq(7, geo.metricTiles.length, 'the counters card renders all seven tiles');
      eq('user,auto,exclude,ipset,ipset_excl,apps,uid',
        geo.metricTiles.map(t => t.label).join(','), 'the counter tiles are labelled as before');
      eq('381,25,2839,28420,637,1,1',
        geo.metricTiles.map(t => t.value).join(','), 'the counter values come from json-status');
      eq(2, geo.metricColumns, 'the counters grid is two columns');

      // ── split button ──
      eq(56, geo.splitHeight, 'the split button is 56dp tall');
      // Outer radius must be half the height, not 9999px: a huge radius next to
      // the small inner one makes the browser scale *all* radii down, which
      // silently flattened the inner corners.
      eq('28,8,8,28', geo.splitMainRadius.join(','), 'the leading segment keeps its inner radius');
      eq('8,28,28,8', geo.splitMenuRadius.join(','), 'the trailing segment keeps its inner radius');
      eq(2, geo.splitGap, 'the segments are 2dp apart');

      // ── shapes ──
      eq(12, geo.cardRadius, 'cards use the 12dp corner');
      eq(12, geo.heroRadius, 'the hero follows the card corner token (12dp)');
      eq(16, geo.strategyRowRadius, 'a lone list item in a card is rounded (16dp)');
      eq(16, geo.doctorRowRadius, 'the doctor row is rounded too (16dp)');
      eq('16,16,0,0', geo.swsFirstRadius.join(','), 'the first list row has 16dp outer corners');
      eq('0,0,16,16', geo.swsLastRadius.join(','), 'the last list row has 16dp outer corners');
      eq('4,4,4,4', geo.swsMiddleRadius.join(','), 'the middle list rows use the 4dp inner corner');
      eq(5, geo.swsRows, 'the switch list has five rows');
      eq(false, geo.swsHasIcons, 'switch rows carry no leading icons');
      eq(false, geo.swsHasSecondary, 'switch rows carry no descriptions');
      eq(56, geo.swsHeight, 'switch rows are single-line (56dp)');

      // ── fields, slider, segmented ──
      eq(56, geo.fieldHeight, 'filled text fields are 56dp tall');
      eq('4,4,0,0', geo.fieldRadius.join(','), 'filled text fields keep 4dp top corners');
      truthy(geo.segCount === 3, 'the mode control renders three segments');
      eq('9999,0,0,9999', geo.segFirst.join(','), 'the first segment is pill-shaped on the outside');
      eq('0,9999,9999,0', geo.segLast.join(','), 'the last segment is pill-shaped on the outside');
      truthy(Math.abs(geo.segGap) <= 1, 'segments are joined, not separated by a gap');

      // ── icons ──
      truthy(geo.iconCount > 10, `${geo.iconCount} icons are rendered`);
      truthy(/rgb/.test(geo.iconFill) && geo.iconFill !== 'none', 'icons paint with currentColor (Material Symbols)');
      truthy(geo.visibleIcons > 10, `${geo.visibleIcons} icons are visible`);
      eq(0, geo.zeroSizedIcons, 'no visible icon collapsed to zero size');

      // ── colour roles stay themable from CSS ──
      truthy(!geo.inlineRoleVars, 'no colour role is applied as an inline style');
      eq(':root{', geo.themeVarsRule, 'the generated palette lives in its own <style>');
      await page.addStyleTag({ content: ':root{--md-sys-color-primary:rgb(1, 2, 3);}' });
      const overridden = await page.evaluate(() =>
        getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-primary').trim());
      eq('rgb(1, 2, 3)', overridden, 'a plain CSS rule can override a colour role');

      // ── the package search must not shell out per keystroke ──
      // Every ctl call is a process on the device, and drawPk() used to re-read
      // apps.list on each one. ctl() quotes every argument, so match on the
      // pieces rather than on 'get-list apps'.
      const listReads = () => page.evaluate(() =>
        window.__calls.filter(c => c.indexOf('get-list') >= 0 && c.indexOf('apps') >= 0).length);

      // The apps page has to be on screen: a hidden input cannot be typed into.
      await page.evaluate(() => {
        document.querySelectorAll('.page').forEach(s => s.classList.toggle('active', s.dataset.page === 'apps'));
      });
      await page.waitForTimeout(150);

      await page.evaluate(() => { window.__calls = []; });
      await page.evaluate(() => loadPk());
      await page.waitForTimeout(400);
      eq(1, await listReads(), 'opening the package list reads apps.list exactly once');
      const listed = await page.evaluate(() => document.querySelectorAll('#pk input[data-pkg]').length);
      eq(4, listed, 'the package list is rendered');

      await page.evaluate(() => { window.__calls = []; });
      await page.evaluate(() => { document.getElementById('pf').value = ''; });
      await page.evaluate(() => {
        window.__renders = 0;
        new MutationObserver(() => { window.__renders++; })
          .observe(document.getElementById('pk'), { childList: true });
      });
      await page.type('#pf', 'com.example', { delay: 20 });
      await page.waitForTimeout(400);
      eq(0, await listReads(), 'typing in the search does not re-read apps.list');
      const renders = await page.evaluate(() => window.__renders);
      truthy(renders === 1, `eleven keystrokes caused ${renders} re-render(s), not eleven`);
      const filtered = await page.evaluate(() => document.querySelectorAll('#pk input[data-pkg]').length);
      eq(2, filtered, 'the filter still narrows the list to the final query');

      // ── overflow ──
      eq('0,0,0', geo.overflow.join(','), 'no container overflows horizontally');
      eq(0, geo.docOverflow, 'the document does not scroll sideways');
      eq(0, geo.tinyTargets, 'no tappable control is below 32dp tall');

      await ctx.close();
    }
  }

  await browser.close();

  process.stdout.write('\n----------------------------------------\n');
  if (failures.length === 0) {
    process.stdout.write(`PASS  ${pass} checks\n`);
    process.exit(0);
  }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
