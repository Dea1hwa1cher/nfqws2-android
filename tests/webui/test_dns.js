#!/usr/bin/env node
/**
 * test_dns.js — экран «DNS по профилям» (только версия extended).
 *
 * Страница открывается в Chromium с заглушкой ksu.exec, которая держит профили
 * в памяти и отвечает на dns-* так же, как nfqws2-ctl (формат dns-state и
 * dns-save-b64 — из lib/dns.sh). Проходятся основные сценарии: включение,
 * пресет, свой профиль с сервером и доменами, DNS по умолчанию, удаление,
 * предупреждение о «Частном DNS».
 */
'use strict';

const fs = require('fs');
const path = require('path');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  process.stdout.write('SKIP  playwright is not installed (set NODE_PATH to a workspace that has it)\n');
  process.exit(0);
}

const REPO = path.resolve(__dirname, '..', '..');
if (!fs.existsSync(path.join(REPO, 'webroot', 'js', 'dns.js'))) {
  process.stdout.write('SKIP  dns.js only exists in the extended build\n');
  process.exit(0);
}
const INDEX = 'file:///' + path.join(REPO, 'webroot', 'index.html').replace(/\\/g, '/');
const PRESETS = fs.readdirSync(path.join(REPO, 'defaults', 'dns-presets')).filter(f => f.endsWith('.conf'))
  .map(f => ({ id: f.replace(/\.conf$/, ''), text: fs.readFileSync(path.join(REPO, 'defaults', 'dns-presets', f), 'utf8') }));
const SHOTS = process.env.NFQWS_SHOTS || '';

const STATUS = JSON.stringify({
  running: true, pid: '4710', uptime: 52, strategy: 'alt13', version: 'v1.9.6-extended', mode: 'auto',
  limiter: 'connbytes', pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off',
  autostart: 1, watchdog: 1, wakelock_on: 0, ipv6: 1, log_level: 0, qdrop: 0, queue: 300, app_uids: 0,
  counts: { user: 381, auto: 25, exclude: 2839, ipset: 28420, ipset_exclude: 637, apps: 0 },
});

// Заглушка модуля: ksu.exec разбирает команду nfqws2-ctl и отвечает из памяти.
const STUB = `
window.__dns = { enabled: false, def: 'net', priv: 'off', privHost: '', standalone: false, service: true, profiles: {}, calls: [] };
window.__presets = ${JSON.stringify(PRESETS)};
(function(){
  const st = window.__dns;
  const args = cmd => { const out = []; const re = /'((?:[^']|'\\\\'')*)'/g; let m;
    while ((m = re.exec(cmd))) out.push(m[1].replace(/'\\\\''/g, "'")); return out; };
  const dec = s => decodeURIComponent(escape(atob(s)));
  function norm(text){
    let name = '', desc = '', en = 0; const sv = [], dm = [];
    text.split('\\n').forEach(l => {
      if (l.startsWith('NAME=')) name = l.slice(5).trim();
      else if (l.startsWith('DESC=')) desc = l.slice(5);
      else if (l.startsWith('ENABLED=')) en = l.slice(8) === '1' ? 1 : 0;
      else if (l.startsWith('SERVER=') && !sv.includes(l.slice(7))) sv.push(l.slice(7));
      else if (l.startsWith('DOMAIN=') && !dm.includes(l.slice(7))) dm.push(l.slice(7));
    });
    if (!name) throw 'Нужно название профиля';
    if (sv.some(s => /\\s/.test(s))) throw 'Неверный адрес сервера';
    return ['NAME=' + name].concat(desc ? ['DESC=' + desc] : [], ['ENABLED=' + en], sv.map(s => 'SERVER=' + s), dm.map(d => 'DOMAIN=' + d)).join('\\n');
  }
  function state(){
    const any = Object.values(st.profiles).some(t => /ENABLED=1/.test(t) && /DOMAIN=/.test(t) && /SERVER=/.test(t));
    const on = st.enabled && (st.service || st.standalone) && (any || st.def !== 'net');
    let out = ['#status', 'enabled=' + (st.enabled ? 1 : 0), 'default=' + st.def,
      'service=' + (st.service ? 'running' : 'stopped'), 'standalone=' + (st.standalone ? 1 : 0),
      'proxy=' + (on ? 'running' : 'stopped'), 'rules=' + (on ? 'on' : 'off'), 'ipv6=redirect',
      'private=' + st.priv, 'private_host=' + st.privHost, 'net_dns=192.168.1.1', 'hits=' + (on ? 1234 : 0), 'error=',
      'max_profiles=32', 'max_servers=8', 'max_domains=1000'];
    Object.keys(st.profiles).forEach(id => { out.push('#profile ' + id); out = out.concat(st.profiles[id].split('\\n')); });
    window.__presets.forEach(p => { out.push('#preset ' + p.id); out = out.concat(p.text.trim().split('\\n')); });
    return out.join('\\n');
  }
  function dns(a){
    st.calls.push(a.join(' '));
    switch (a[0]) {
      case 'dns-state': return [0, state()];
      case 'dns-set-enabled': st.enabled = a[1] === '1'; return [0, 'OK'];
      case 'dns-set-standalone': st.standalone = a[1] === '1'; return [0, 'OK'];
      case 'dns-set-default': if (a[1] !== 'net' && !st.profiles[a[1]]) return [1, '', 'Профиль не найден'];
        st.def = a[1]; return [0, 'OK'];
      case 'dns-save-b64': try { st.profiles[a[1]] = norm(dec(a[2])); return [0, 'OK']; } catch (e) { return [1, '', String(e)]; }
      case 'dns-profile-enable': st.profiles[a[1]] = st.profiles[a[1]].replace(/ENABLED=\\d/, 'ENABLED=' + a[2]); return [0, 'OK'];
      case 'dns-delete': delete st.profiles[a[1]]; if (st.def === a[1]) st.def = 'net'; return [0, 'OK'];
      case 'dns-test': return [0, '57.144.154.34\\t' + (Object.keys(st.profiles).find(id => st.profiles[id].includes('DOMAIN=' + a[1])) || '')];
    }
    return [1, '', 'unknown'];
  }
  window.ksu = { exec: function(cmd, opts, cb){
    var id = typeof cb === 'string' ? cb : opts;
    var rc = 0, out = 'OK', err = '';
    if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(STATUS)};
    else if (cmd.indexOf('list-strategies') >= 0) out = 'default\\talt13';
    else if (cmd.indexOf('get-strategy') >= 0) out = 'default';
    else if (cmd.indexOf("'dns-") >= 0) { const a = args(cmd); const r = dns(a.slice(a.findIndex(x => x.startsWith('dns-'))));
      rc = r[0]; out = r[1] || ''; err = r[2] || ''; }
    setTimeout(function(){ if (window[id]) window[id](rc, out, err); }, 0);
    return 'job';
  }};
})();
`;

let pass = 0;
const failures = [];
let section = '';
function sect(name) { section = name; process.stdout.write(`\n== ${name}\n`); }
function ok(msg) { pass++; process.stdout.write(`   ok   ${msg}\n`); }
function fail(msg) { failures.push(`[${section}] ${msg}`); process.stdout.write(`   FAIL ${msg}\n`); }
function eq(expected, actual, msg) {
  if (JSON.stringify(expected) === JSON.stringify(actual)) ok(msg);
  else fail(`${msg} -- expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function truthy(cond, msg) { cond ? ok(msg) : fail(msg); }

(async () => {
  const browser = await chromium.launch();
  for (const mode of ['light', 'dark']) {
    const ctx = await browser.newContext({ viewport: { width: 400, height: 900 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    await ctx.addInitScript(`try{localStorage.setItem('m3_mode','${mode}');}catch(e){}`);
    await ctx.addInitScript(STUB);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(INDEX, { waitUntil: 'load' });
    await page.waitForTimeout(500);
    const idle = () => page.waitForTimeout(450);
    // Диалоги: подставить значение в поле и нажать ОК / выбрать пункт меню
    const answer = async value => {
      await page.waitForSelector('#dialog-wrap.open');
      if (value !== undefined && await page.isVisible('#d-input')) await page.fill('#d-input', value);
      await page.click('#d-ok');
      await idle();
    };
    const menuPick = async label => { await page.waitForSelector('.menu .mi'); await page.click(`.menu .mi:has-text("${label}")`); await idle(); };
    const shot = async name => { if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${mode}-${name}.png`), fullPage: true }); };

    sect(`${mode}: settings → tools → DNS`);
    await page.evaluate(() => navigate('settings')); await idle();
    const row = await page.$('#settings-body .list-item:has-text("DNS по профилям")');
    truthy(!!row, 'the DNS row is in the settings');
    const group = await page.evaluate(() => {
      const r = [...document.querySelectorAll('#settings-body .list-item')].find(e => e.textContent.includes('DNS по профилям'));
      return r && r.closest('.stack').querySelector('.subhead').textContent;
    });
    eq('Инструменты', group, 'in the Tools group');
    truthy((await page.textContent('#settings-body')).includes('Версия v1.9.6 extended'), 'the version reads "v1.9.6 extended", with a space');
    await row.click(); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'it opens the DNS screen');
    eq(true, await page.evaluate(() => $('dns-body').classList.contains('is-disabled')), 'the body is greyed out while the feature is off');

    sect(`${mode}: switching on`);
    // Пресеты в профили кладёт модуль при первом запуске (test_dns.sh); у заглушки их нет
    truthy(await page.isVisible('#dns-profiles .empty'), 'an empty state is shown without profiles');
    await page.click('#dns-main'); await idle();
    eq(true, await page.evaluate(() => window.__dns.enabled), 'the main switch turns the feature on');
    eq(false, await page.evaluate(() => $('dns-body').classList.contains('is-disabled')), 'and enables the body');
    truthy((await page.textContent('#dns-general')).includes('Не активно'), 'the state says nothing is applied yet');

    sect(`${mode}: a preset`);
    await page.click('#dns-add'); await menuPick('Из пресетов');
    await page.waitForSelector('#dns-preset-sheet.open');
    eq(['Comss.one DNS', 'GeoHide DNS', 'XBox DNS'],
      await page.$$eval('#dns-preset-list .li-primary', l => l.map(e => e.textContent)), 'exactly the three presets');
    await shot('presets');
    await page.click('#dns-preset-list .list-item:has-text("XBox DNS")'); await idle();
    const xbox = await page.evaluate(() => window.__dns.profiles.xbox || '');
    eq(['https://xbox-dns.ru/dns-query', 'tls://xbox-dns.ru', '111.88.96.54', '111.88.96.55'],
      xbox.split('\n').filter(l => l.startsWith('SERVER=')).map(l => l.slice(7)), 'the preset is saved with DoH, DoT and both IPs');
    truthy(xbox.includes('ENABLED=0'), 'a preset without domains is added switched off');
    await page.click('#dns-profiles .list-item:has-text("XBox DNS")'); await idle();
    eq(['DoH (HTTPS)', 'DoT (TLS)', 'Обычный DNS', 'Обычный DNS'],
      await page.$$eval('#dnsp-servers .li-secondary', l => l.map(e => e.textContent)), 'plain IPs are shown as one plain DNS type');
    await page.evaluate(() => goBack()); await idle();

    sect(`${mode}: a new profile`);
    await page.click('#dns-add'); await menuPick('Новый профиль');
    await answer('Игры');
    eq('dnsprof', await page.evaluate(() => currentPage), 'a new profile opens its own screen');
    eq('Игры', await page.textContent('#app-title'), 'titled with the profile name');
    truthy(await page.isVisible('#dnsp-servers .empty'), 'it asks for a server first');
    // сервер DoT: тип из меню, затем адрес; имя без схемы
    await page.click('#dnsp-add-server'); await menuPick('DoT (TLS)');
    await answer('dns.google');
    // DoH: только имя — допишется /dns-query
    await page.click('#dnsp-add-server'); await menuPick('DoH (HTTPS)');
    await answer('dns.comss.one');
    // неверный адрес — повторный запрос, затем отмена
    const types = await page.evaluate(async () => { addDnsServer($('dnsp-add-server')); await new Promise(r => setTimeout(r, 200));
      const l = [...document.querySelectorAll('.menu .mi-text')].map(e => e.textContent); closeMenu(); return l; });
    await idle();
    truthy(types.includes('Обычный DNS') && !types.some(x => /UDP|TCP/.test(x)), 'one plain DNS type, no UDP/TCP split');
    await page.click('#dnsp-add-server'); await menuPick('Обычный DNS');
    await answer('dns.google');
    truthy(await page.isVisible('#dialog-wrap.open'), 'a plain DNS server by name is refused and asked again');
    await page.click('#d-cancel'); await idle();
    const gid = () => Object.keys(window.__dns.profiles).find(k => k !== 'xbox');
    let prof = await page.evaluate(`window.__dns.profiles[(${gid})()]`);
    truthy(prof.includes('SERVER=tls://dns.google'), 'DoT is stored as tls://');
    truthy(prof.includes('SERVER=https://dns.comss.one/dns-query'), 'DoH gets /dns-query');
    eq(2, await page.$$eval('#dnsp-servers .list-item', l => l.length), 'two servers are listed');
    // домены: несколько за раз, мусор отбрасывается, кириллица -> punycode
    await page.click('#dnsp-add-domain');
    await answer('https://www.Roblox.com/games, *.rbxcdn.com пример.рф bad..name');
    prof = await page.evaluate(`window.__dns.profiles[(${gid})()]`);
    truthy(prof.includes('DOMAIN=www.roblox.com') && prof.includes('DOMAIN=rbxcdn.com'), 'URLs and wildcards become plain domains');
    truthy(prof.includes('DOMAIN=xn--e1afmkfd.xn--p1ai'), 'a Cyrillic domain is stored in punycode');
    truthy(!prof.includes('bad..name'), 'an invalid domain is skipped');
    eq(3, await page.$$eval('#dnsp-domains .list-item', l => l.length), 'three domains are listed');
    // включение и выбор по умолчанию
    await page.click('#dnsp-head label.list-item'); await idle();
    truthy((await page.evaluate(() => window.__dns.profiles[dnsCur])).includes('ENABLED=1'), 'the profile is switched on from its screen');
    await page.click('#dnsp-head .list-item:has-text("DNS по умолчанию")'); await idle();
    eq(await page.evaluate(() => dnsCur), await page.evaluate(() => window.__dns.def), 'it can become the default DNS');
    await shot('profile');
    // правка доменов списком
    await page.click('button:has-text("Редактировать списком")'); await idle();
    await page.fill('#panel-editor-text', 'a.example\nb.example  # second\n# comment line\n');
    await page.click('#panel-save-btn'); await idle();
    prof = await page.evaluate(() => window.__dns.profiles[dnsCur]);
    truthy(/DOMAIN=a\.example\nDOMAIN=b\.example$/.test(prof), 'the list editor replaces the domains');
    await page.click('#panel-save-btn').catch(() => {});

    sect(`${mode}: back and delete`);
    await page.evaluate(() => goBack()); await idle();
    eq('dns', await page.evaluate(() => currentPage), 'back returns to the DNS screen');
    truthy((await page.textContent('#dns-general .list-item')).includes('Игры'), 'the default DNS row names the profile');
    let state = await page.textContent('#dns-general');
    truthy(state.includes('Перехвачено запросов'), 'the state shows interception working');
    truthy(state.includes('остальное — через «Игры»'), 'and names the profile everything else goes to');
    truthy(!state.includes('192.168.1.1'), 'the network DNS is not shown while it is not used');
    await shot('main');
    await page.click('#dns-profiles .list-item:has-text("Игры")'); await idle();
    await page.click('button:has-text("Удалить профиль")');
    await answer();
    eq('dns', await page.evaluate(() => currentPage), 'deleting returns to the list');
    eq('net', await page.evaluate(() => window.__dns.def), 'the default falls back to the network DNS');

    sect(`${mode}: standalone`);
    // профиль с доменами, чтобы было что применять
    await page.evaluate(() => { window.__dns.profiles.xbox = window.__dns.profiles.xbox.replace('ENABLED=0', 'ENABLED=1') + '\nDOMAIN=chatgpt.com'; });
    await page.evaluate(() => { window.__dns.service = false; }); await page.evaluate(() => dnsInit()); await idle();
    truthy((await page.textContent('#dns-warn')).includes('Без службы обхода'), 'with the service stopped the screen points at the standalone switch');
    truthy((await page.textContent('#dns-general')).includes('Ожидает запуска службы'), 'and waits for the service');
    await page.click('#dns-general label:has-text("Без службы обхода")'); await idle();
    eq(true, await page.evaluate(() => window.__dns.standalone), 'the standalone switch is saved');
    state = await page.textContent('#dns-general');
    truthy(state.includes('Работает без службы обхода'), 'DNS works with the service stopped');
    truthy(state.includes('остальное — через DNS сети (192.168.1.1)'), 'the network DNS is shown when it is the default');
    truthy(!(await page.textContent('#dns-warn')).includes('Служба не запущена'), 'no "service stopped" warning in standalone mode');
    await shot('standalone');
    await page.evaluate(() => { window.__dns.service = true; });

    sect(`${mode}: Private DNS`);
    await page.evaluate(() => { window.__dns.priv = 'hostname'; window.__dns.privHost = 'dns.google'; });
    await page.evaluate(() => dnsInit()); await idle();
    const warn = await page.textContent('#dns-warn');
    truthy(warn.includes('Частный DNS') && warn.includes('dns.google'), 'Private DNS with a host is flagged');
    truthy((await page.textContent('#dns-general')).includes('Не применяется'), 'and the state does not claim to work');
    const btn = await page.$eval('#dns-warn .btn', b => b.scrollWidth <= b.clientWidth + 1);
    truthy(btn, 'the Open button is not squeezed');
    await shot('private');

    sect(`${mode}: English`);
    await page.evaluate(() => setLanguage('en')); await idle();
    const txt = await page.textContent('[data-page="dns"]');
    truthy(!/[А-Яа-яЁё]/.test(txt), 'no Russian text left on the screen in English');
    await page.evaluate(() => setLanguage('ru')); await idle();

    eq([], errors, 'no page errors');
    await ctx.close();
  }
  await browser.close();
  process.stdout.write('\n----------------------------------------\n');
  if (!failures.length) { process.stdout.write(`PASS  ${pass} checks\n`); process.exit(0); }
  process.stdout.write(`FAIL  ${failures.length} of ${pass + failures.length} checks failed\n`);
  for (const f of failures) process.stdout.write(`   - ${f}\n`);
  process.exit(1);
})();
