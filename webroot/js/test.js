/* nfqws2 WebUI · test.js — проверка доступности
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ПРОВЕРКА ДОСТУПНОСТИ ════════════════════════════════════════════════
   Раньше адреса открывались через fetch() из WebView. Это давало неверную
   картину: (1) три попытки и «Проверить снова» шли по уже открытому
   HTTP/2-соединению из пула браузера — после смены стратегии проверялось
   старое соединение, а не новое; (2) трафик WebView идёт от UID менеджера,
   и при фильтре «только выбранные приложения» он не попадал в обход.
   Теперь проверка выполняется на устройстве (probe-all): каждая попытка —
   новое TLS-соединение, а на время проверки её трафик проходит через обход
   так же, как трафик выбранных приложений. WebView — только запасной путь,
   если на устройстве нет ни curl, ни busybox wget с TLS. */
const PROBE_REASON = {dns: 'DNS не отвечает', reset: 'Соединение сброшено', timeout: 'Нет ответа',
  tls: 'Ошибка TLS', refused: 'Соединение отклонено', other: 'Ошибка'};
let testRunning = false;
function testInit(){
  $('test-desc').textContent = t('Каждый адрес из probe_hosts.list открывается с устройства три раза, каждый раз новым соединением. Зелёный — прошли все попытки, жёлтый — часть, красный — ни одной.');
  stat(true).then(renderTestWarn);
  renderTestWarn();
}
function renderTestWarn(){
  let w = '';
  if(S.running === false) w += banner('', 'info', S.paused
    ? t('Служба на паузе в домашней Wi‑Fi: проверяется прямое соединение, без обхода.')
    : t('Служба остановлена: проверяется прямое соединение, без обхода.'));
  setHTML('test-warn', w, false);
}
function testRow(i, h){
  return '<div class="list-item two-line" id="trow' + i + '">' +
    '<span class="status info" id="ti' + i + '"><span class="spinner" style="width:14px;height:14px;"></span></span>' +
    '<span class="li-text"><span class="li-primary li-mono truncate">' + esc(h) + '</span>' +
      '<span class="li-secondary" id="ts' + i + '">' + esc(t('Проверка…')) + '</span></span>' +
    '<span class="li-trail li-value" id="tr' + i + '">…</span>' +
  '</div>';
}
function finishTestRow(i, res){
  const ok = res.filter(x => x.ok), n = res.length;
  const badge = $('ti' + i);
  if(!badge) return;
  badge.className = 'status ' + (ok.length === n ? 'ok' : (ok.length ? 'warn' : 'bad'));
  badge.innerHTML = icon(ok.length === n ? 'check' : (ok.length ? 'warn' : 'close'), 's16');
  $('tr' + i).textContent = ok.length + '/' + n;
  const reasons = [...new Set(res.filter(x => !x.ok).map(x => t(PROBE_REASON[x.reason] || PROBE_REASON.other)))];
  $('ts' + i).textContent = (ok.length ? t('{0} мс в среднем', Math.round(ok.reduce((a, x) => a + x.ms, 0) / ok.length)) : '') +
    (ok.length && reasons.length ? ' · ' : '') + reasons.join(', ');
}
async function runTest(){
  if(testRunning) return;
  testRunning = true;
  $('tb').disabled = true;
  $('tb').innerHTML = '<span class="spinner"></span><span>' + esc(t('Проверка идёт')) + '</span>';
  $('test-empty').hidden = true;
  setHTML('tr', '', false);
  await stat(true);
  renderTestWarn();
  const hosts = [], res = {};
  let tool = '';
  const onLine = l => {
    const p = l.split('\t');
    if(p[0] === 'tool') tool = p[1];
    else if(p[0] === 'H'){ hosts[+p[1]] = p[2]; res[p[1]] = []; $('tr').insertAdjacentHTML('beforeend', testRow(p[1], p[2])); }
    else if(p[0] === 'R' && res[p[1]]){
      const v = (p[3] || '').split(' ');
      res[p[1]].push(v[0] === 'ok' ? {ok: true, ms: +v[1] || 0} : {ok: false, reason: v[1] || 'other'});
      $('tr' + p[1]).textContent = res[p[1]].filter(x => x.ok).length + '/' + res[p[1]].length;
      if(res[p[1]].length === 3) finishTestRow(p[1], res[p[1]]);
    }
  };
  const r = await ctlx(['probe-all'], 120000, onLine);
  if(tool === 'none' || (r.code && !hosts.length)) await runTestWebView();
  else {
    Object.keys(res).forEach(i => { if(res[i].length < 3) finishTestRow(i, res[i].length ? res[i] : [{ok: false, reason: 'timeout'}]); });
    if(!hosts.length){ $('test-empty').hidden = false; $('test-empty-title').textContent = t('probe_hosts.list пуст'); }
  }
  testRunning = false;
  $('tb').disabled = false;
  $('tb').innerHTML = icon('play', 's18') + '<span>' + esc(t('Проверить снова')) + '</span>';
}
/* Запасной путь: fetch из WebView. Результат приблизительный — об этом
   говорит баннер; уникальный параметр хотя бы обходит кэш. */
async function probeFetch(u){
  const t0 = performance.now(), c = new AbortController(), m = setTimeout(() => c.abort(), 6000);
  try {
    await fetch('https://' + u + (u.includes('?') ? '&' : '?') + '_=' + Date.now() + Math.random(),
      {mode: 'no-cors', cache: 'no-store', credentials: 'omit', signal: c.signal});
    return {ok: true, ms: performance.now() - t0};
  } catch(e) { return {ok: false, reason: c.signal.aborted ? 'timeout' : 'reset'}; } finally { clearTimeout(m); }
}
async function runTestWebView(){
  setHTML('test-warn', $('test-warn').innerHTML + banner('', 'warn',
    t('На устройстве нет curl или busybox wget с TLS — проверка идёт через WebView и показывает лишь приблизительную картину.')), false);
  const r = await ctlx(['get-list', 'probe_hosts']);
  const hosts = (r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#');
  setHTML('tr', hosts.map((h, i) => testRow(i, h)).join(''), false);
  if(!hosts.length){ $('test-empty').hidden = false; $('test-empty-title').textContent = t('probe_hosts.list пуст'); }
  await Promise.all(hosts.map(async (h, i) => {
    const out = [];
    for(let k = 0; k < 3; k++) out.push(await probeFetch(h));
    finishTestRow(i, out);
  }));
}
