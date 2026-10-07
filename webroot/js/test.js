/* nfqws2 WebUI · test.js — DPI Detector & проверка доступности */

const PROBE_REASON = {
  dns: 'DNS не отвечает',
  dns_fail: 'Ошибка DNS',
  reset: 'Соединение сброшено',
  tls_rst: 'TLS RST (сброс ClientHello)',
  tls_alert: 'TLS Alert (SNI блок)',
  tls_spoof: 'Подмена ответа (Spoof)',
  tls_mitm: 'Подмена сертификата (MITM)',
  drop: 'Тихий сброс (Drop)',
  timeout: 'Нет ответа (Timeout)',
  isp_redir: 'Заглушка провайдера (RKN)',
  refused: 'Соединение отклонено',
  tls: 'Ошибка TLS',
  other: 'Ошибка'
};

let testRunning = false;
let currentTestTab = 'all';
let netInfoData = null;
let webResults = {};
let tcp16Results = {};
let dnsResults = {};
let tgResults = {};
let tgMediaSpeed = '';

function testInit(){
  updateTestDesc();
  stat(true).then(renderTestWarn);
  renderTestWarn();
  refreshNetInfo();
}

function updateTestDesc(){
  const d = $('test-desc');
  if(!d) return;
  if(currentTestTab === 'web'){
    d.textContent = t('Каждый адрес из probe_hosts.list открывается с устройства три раза. Анализируются активные сбросы (TLS RST), инжекции TLS Alert, тихий дроп и подмена сертификатов.');
  } else if(currentTestTab === 'tcp16'){
    d.textContent = t('Тестирование соединений к зарубежным CDN и хостингам (Cloudflare, Hetzner, DO, OVH) с нарастающим объёмом данных до 32 КБ для выявления фильтра TCP 16-20KB.');
  } else if(currentTestTab === 'dns'){
    d.textContent = t('Проверка резолверов по UDP:53 и DoH для обнаружения перехвата портов провайдером и подмены IP адресов на заглушки РКН.');
  } else if(currentTestTab === 'tg'){
    d.textContent = t('Проверка прямой связности с датацентрами Telegram (DC1-DC5) и замер скорости загрузки тестового медиа.');
  } else {
    d.textContent = t('Комплексный анализ цензуры DPI: проверка доступности сайтов, детекция блокировок TCP 16-20KB, анализ перехвата DNS и связности с Telegram.');
  }
}

function selectTestTab(tab){
  currentTestTab = tab;
  document.querySelectorAll('#test-tabs .seg').forEach(btn => {
    btn.classList.toggle('on', btn.dataset.tab === tab);
  });
  const showWeb = tab === 'all' || tab === 'web';
  const showTcp = tab === 'all' || tab === 'tcp16';
  const showDns = tab === 'all' || tab === 'dns';
  const showTg = tab === 'all' || tab === 'tg';

  if($('test-sec-web')) $('test-sec-web').hidden = !showWeb;
  if($('test-sec-tcp16')) $('test-sec-tcp16').hidden = !showTcp;
  if($('test-sec-dns')) $('test-sec-dns').hidden = !showDns;
  if($('test-sec-tg')) $('test-sec-tg').hidden = !showTg;

  updateTestDesc();
}

async function refreshNetInfo(){
  const ipEl = $('net-ip'), ispEl = $('net-isp'), badgeEl = $('net-badge');
  if(!ipEl || !ispEl) return;
  ispEl.textContent = t('Загрузка сети…');
  const r = await ctlx(['net-info'], 8000);
  if(r.code && !r.out){
    ispEl.textContent = t('Сетевые данные недоступны');
    return;
  }
  const lines = (r.out || '').split('\n');
  const data = {};
  for(const l of lines){
    const p = l.split('\t');
    if(p.length >= 2) data[p[0]] = p[1];
  }
  netInfoData = data;
  ipEl.textContent = (data.ip && data.ip !== '—' && data.ip !== 'unknown')
    ? `${data.ip} (${data.loc || '?'})`
    : t('Локальная сеть');
  const ispText = [
    data.isp && data.isp !== 'unknown' ? data.isp : '',
    data.asn && data.asn !== 'unknown' ? data.asn : '',
    data.dns && data.dns !== 'none' ? `DNS: ${data.dns}` : ''
  ].filter(Boolean).join(' · ');
  ispEl.textContent = ispText || t('Информация о провайдере отсутствует');

  if(badgeEl){
    const active = data.status === 'running';
    badgeEl.innerHTML = `<span class="status ${active ? 'ok' : 'info'}">${icon(active ? 'shield' : 'wifi', 's16')}</span>`;
  }
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

function renderTcp16Row(i, provider, ip, port, status, detail){
  const isClean = status === 'clean';
  const isDetected = status === 'detected';
  const stClass = isClean ? 'ok' : (isDetected ? 'bad' : 'info');
  const icName = isClean ? 'check' : (isDetected ? 'warn' : 'close');
  const trailText = isClean ? `${detail || 'OK'}` : (isDetected ? `БЛОК @ ${detail}` : t('Недоступен'));
  return '<div class="list-item two-line" id="tcprow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(provider) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + (isClean ? t('Чисто, передача данных стабильна') : (isDetected ? t('Обрыв сессии ТСПУ после {0}', detail) : t('Хост недоступен'))) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isDetected ? 't-label-medium bad' : 'li-value') + '">' + esc(trailText) + '</span>' +
  '</div>';
}

function renderDnsRow(i, name, ip, udp, doh, hijacked, detail){
  const isHijacked = hijacked === 'yes';
  const isUdpOk = udp === 'ok';
  const stClass = isHijacked ? 'bad' : (isUdpOk ? 'ok' : 'warn');
  const icName = isHijacked ? 'warn' : (isUdpOk ? 'check' : 'close');
  let sub = `UDP: ${isUdpOk ? 'OK' : t('Блок')}`;
  if(doh && doh !== 'none') sub += ` · DoH: ${doh === 'ok' ? 'OK' : t('Блок')}`;
  if(isHijacked) sub += ` · ${detail}`;
  const trail = isHijacked ? t('ПЕРЕХВАТ') : (isUdpOk ? 'OK' : t('СБОЙ'));
  return '<div class="list-item two-line" id="dnsrow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(name) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + esc(sub) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isHijacked ? 't-label-medium bad' : 'li-value') + '">' + esc(trail) + '</span>' +
  '</div>';
}

function renderTgRow(i, name, ip, status, ms){
  const isOk = status === 'ok';
  const stClass = isOk ? 'ok' : 'bad';
  const icName = isOk ? 'check' : 'close';
  return '<div class="list-item" id="tgrow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(name) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
    '</span>' +
    '<span class="li-trail li-value">' + esc(isOk ? ms : t('Недоступен')) + '</span>' +
  '</div>';
}

/* Повторная проверка начинается с чистого листа: все списки и результаты всех
   вкладок обнуляются. Через setHTML(id, '') очистить нельзя — строки сюда
   дописываются insertAdjacentHTML мимо его памяти (el._html остаётся ''),
   и очистка молча пропускалась: новые строки вставали под старые с теми же id. */
function resetTestResults(){
  ['tr', 'test-tcp16-list', 'test-dns-list', 'test-tg-list'].forEach(id => {
    const el = $(id);
    if(el){ el.innerHTML = ''; el._html = ''; }
  });
  webResults = {}; tcp16Results = {}; dnsResults = {}; tgResults = {}; tgMediaSpeed = '';
}

async function runTest(){
  if(testRunning) return;
  testRunning = true;
  $('tb').disabled = true;
  $('tb').innerHTML = '<span class="spinner"></span><span>' + esc(t('Проверка идёт')) + '</span>';
  $('test-empty').hidden = true;

  resetTestResults();

  await stat(true);
  renderTestWarn();
  await refreshNetInfo();

  const hosts = [];
  let tool = '';

  const onLine = l => {
    const p = l.split('\t');
    if(p[0] === 'tool') {
      tool = p[1];
    } else if(p[0] === 'H') {
      hosts[+p[1]] = p[2];
      webResults[p[1]] = {host: p[2], list: []};
      $('tr').insertAdjacentHTML('beforeend', testRow(p[1], p[2]));
    } else if(p[0] === 'R' && webResults[p[1]]) {
      const v = (p[3] || '').split(' ');
      const resItem = v[0] === 'ok' ? {ok: true, ms: +v[1] || 0} : {ok: false, reason: v[1] || 'other'};
      webResults[p[1]].list.push(resItem);
      $('tr' + p[1]).textContent = webResults[p[1]].list.filter(x => x.ok).length + '/' + webResults[p[1]].list.length;
      if(webResults[p[1]].list.length === 3) finishTestRow(p[1], webResults[p[1]].list);
    } else if(p[0] === 'T16') {
      const idx = p[1], provider = p[2], ip = p[3], port = p[4], st = p[5], detail = p[6];
      tcp16Results[idx] = {provider, ip, port, status: st, detail};
      const existing = $('tcprow' + idx);
      const rowHtml = renderTcp16Row(idx, provider, ip, port, st, detail);
      if(existing) existing.outerHTML = rowHtml;
      else $('test-tcp16-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'DNS') {
      const idx = p[1], name = p[2], ip = p[3], udp = p[4], doh = p[5], hijacked = p[6], detail = p[7];
      dnsResults[idx] = {name, ip, udp, doh, hijacked, detail};
      const existing = $('dnsrow' + idx);
      const rowHtml = renderDnsRow(idx, name, ip, udp, doh, hijacked, detail);
      if(existing) existing.outerHTML = rowHtml;
      else $('test-dns-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'TG') {
      const idx = p[1], name = p[2], ip = p[3], st = p[4], ms = p[5];
      tgResults[idx] = {name, ip, status: st, ms};
      const existing = $('tgrow' + idx);
      const rowHtml = renderTgRow(idx, name, ip, st, ms);
      if(existing) existing.outerHTML = rowHtml;
      else $('test-tg-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'TG_MEDIA') {
      tgMediaSpeed = p[2] || '';
      const existing = $('tgm0');
      const mediaHtml = '<div class="list-item" id="tgm0">' +
        '<span class="li-icon plain">' + icon('download', 's20') + '</span>' +
        '<span class="li-text"><span class="li-primary">' + esc(t('Скорость медиа')) + '</span></span>' +
        '<span class="li-trail li-value">' + esc(tgMediaSpeed) + '</span>' +
      '</div>';
      if(existing) existing.outerHTML = mediaHtml;
      else $('test-tg-list').insertAdjacentHTML('beforeend', mediaHtml);
    }
  };

  const r = await ctlx(['probe-dpi', currentTestTab], 180000, onLine);
  if(tool === 'none' || (r.code && !hosts.length && currentTestTab === 'web')) {
    await runTestWebView();
  } else {
    Object.keys(webResults).forEach(i => {
      if(webResults[i].list.length < 3) {
        finishTestRow(i, webResults[i].list.length ? webResults[i].list : [{ok: false, reason: 'timeout'}]);
      }
    });
  }

  testRunning = false;
  $('tb').disabled = false;
  $('tb').innerHTML = icon('play', 's18') + '<span>' + esc(t('Проверить снова')) + '</span>';
}

/* Запасной путь: fetch из WebView */
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

function copyTestReport(){
  let rep = '### DPI Detector (nfqws2-android)\n\n';
  if(netInfoData){
    rep += `**Сеть:** IP: ${netInfoData.ip || '—'} (${netInfoData.loc || '—'}), Провайдер: ${netInfoData.isp || '—'} (${netInfoData.asn || '—'})\n`;
    rep += `**Обход:** ${netInfoData.status === 'running' ? 'Активен' : 'Остановлен'}, Стратегия: ${netInfoData.strategy || '—'}, DNS: ${netInfoData.dns || '—'}\n\n`;
  }
  if(Object.keys(webResults).length > 0){
    rep += '#### Сайты и сервисы:\n';
    for(const k of Object.keys(webResults)){
      const item = webResults[k];
      const ok = item.list.filter(x => x.ok);
      const fails = [...new Set(item.list.filter(x => !x.ok).map(x => PROBE_REASON[x.reason] || x.reason))];
      rep += `- ${item.host}: ${ok.length}/${item.list.length}` + (ok.length ? ` (${Math.round(ok.reduce((a,x)=>a+x.ms,0)/ok.length)} мс)` : '') + (fails.length ? ` [${fails.join(', ')}]` : '') + '\n';
    }
    rep += '\n';
  }
  if(Object.keys(tcp16Results).length > 0){
    rep += '#### TCP 16-20KB блокировка (CDN и хостинги):\n';
    for(const k of Object.keys(tcp16Results)){
      const it = tcp16Results[k];
      rep += `- ${it.provider} (${it.ip}): ${it.status === 'clean' ? 'CLEAN (' + it.detail + ')' : (it.status === 'detected' ? 'DETECTED @ ' + it.detail : 'UNREACHABLE')}\n`;
    }
    rep += '\n';
  }
  if(Object.keys(dnsResults).length > 0){
    rep += '#### DNS и перехват:\n';
    for(const k of Object.keys(dnsResults)){
      const it = dnsResults[k];
      rep += `- ${it.name} (${it.ip}): UDP=${it.udp}, DoH=${it.doh}, Перехват=${it.hijacked === 'yes' ? 'ДА (' + it.detail + ')' : 'НЕТ'}\n`;
    }
    rep += '\n';
  }
  if(Object.keys(tgResults).length > 0){
    rep += '#### Telegram:\n';
    for(const k of Object.keys(tgResults)){
      const it = tgResults[k];
      rep += `- ${it.name} (${it.ip}): ${it.status === 'ok' ? it.ms : 'FAIL'}\n`;
    }
    if(tgMediaSpeed) rep += `- Скорость медиа: ${tgMediaSpeed}\n`;
    rep += '\n';
  }

  if(navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(rep).then(() => toast(t('Отчёт скопирован в буфер обмена')));
  } else {
    const ta = document.createElement('textarea');
    ta.value = rep;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    toast(t('Отчёт скопирован в буфер обмена'));
  }
}
