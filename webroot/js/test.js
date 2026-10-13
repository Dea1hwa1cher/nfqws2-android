/* nfqws2 WebUI - DPI detector and availability check */

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
  quic_unsupported: 'QUIC не поддерживается',
  other: 'Ошибка'
};

const PROTO_NAMES = {
  1: 'HTTP',
  2: 'TLS 1.2',
  3: 'TLS 1.3',
  4: 'QUIC'
};

let testRunning = false;
let testCancelled = false;
let webViewAbortCtrl = null;
let currentTestTab = 'all';
let netInfoData = null;
let webResults = {};
let tcp16Results = {};
let dnsResults = {};
let tgResults = {};
let tgMediaSpeed = null;
let lastRecommendation = null;
let benchResults = {};
let benchTotalStrats = 0;
let benchBestStrat = null;

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
    d.textContent = t('Каждый адрес из probe_hosts.list проверяется по 4 протоколам (HTTP, TLS 1.2, TLS 1.3, QUIC). Анализируются активные сбросы (TLS RST), инжекции TLS Alert, тихий дроп и блокировки UDP/QUIC.');
  } else if(currentTestTab === 'tcp16'){
    d.textContent = t('Тестирование соединений к зарубежным CDN и хостингам (Cloudflare, Hetzner, DO, OVH) с нарастающим объёмом данных до 32 КБ для выявления фильтра TCP 16-20KB.');
  } else if(currentTestTab === 'dns'){
    d.textContent = t('Проверка резолверов по UDP:53 и DoH для обнаружения перехвата портов провайдером и подмены IP адресов на заглушки РКН.');
  } else if(currentTestTab === 'tg'){
    d.textContent = t('Проверка доступности датацентров Telegram (DC1-DC5) и скорости загрузки медиа.');
  } else if(currentTestTab === 'bench'){
    d.textContent = t('Автоподбор: последовательное тестирование всех доступных стратегий через контрольный набор сайтов (probe_bench.list). Определяет стратегию с наивысшей проходимостью и минимальной задержкой.');
  } else {
    d.textContent = t('Комплексный анализ цензуры DPI: проверка доступности сайтов (HTTP/TLS/QUIC), детекция блокировок TCP 16-20KB, перехват DNS и датацентры Telegram.');
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
  const showBench = tab === 'bench';

  if($('test-sec-web')) $('test-sec-web').hidden = !showWeb;
  if($('test-sec-tcp16')) $('test-sec-tcp16').hidden = !showTcp;
  if($('test-sec-dns')) $('test-sec-dns').hidden = !showDns;
  if($('test-sec-tg')) $('test-sec-tg').hidden = !showTg;
  if($('test-sec-bench')) $('test-sec-bench').hidden = !showBench;

  const tb = $('tb');
  if(tb && !testRunning){
    const span = tb.querySelector('span');
    if(span) span.textContent = tab === 'bench' ? t('Запустить автоподбор') : t('Запустить проверку');
  }

  updateTestDesc();
}

/* net-info returns one TAB-separated line: NET ip loc isp asn iface gw dns status strategy; unknown is "-" */
const NET_FIELDS = ['ip', 'loc', 'isp', 'asn', 'iface', 'gw', 'dns', 'status', 'strategy'];
function parseNetInfo(out){
  const data = {};
  const line = (out || '').split('\n').find(l => l.startsWith('NET\t'));
  if(!line) return data;
  const p = line.split('\t');
  NET_FIELDS.forEach((k, i) => {
    const v = (p[i + 1] || '').trim();
    if(v && v !== '—') data[k] = v;
  });
  return data;
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
  const data = parseNetInfo(r.out);
  netInfoData = data;
  ipEl.textContent = data.ip ? `${data.ip} (${data.loc || '?'})` : t('Локальная сеть');
  const ispText = [data.isp, data.asn, data.dns ? `DNS: ${data.dns}` : ''].filter(Boolean).join(' · ');
  ispEl.textContent = ispText || t('Информация о провайдере отсутствует');

  if(badgeEl){
    const active = data.status === 'running';
    badgeEl.innerHTML = `<span class="status ${active ? 'ok' : 'info'}">${icon(active ? 'shield' : 'wifi', 's16')}</span>`;
  }
}

function renderTestWarn(){
  let w = '';
  if(S.running === false) w += banner('', 'info', S.paused
    ? (S.paused === 'vpn'
        ? t('Служба на паузе из-за активного VPN: проверяется прямое соединение, без обхода.')
        : t('Служба на паузе в домашней Wi‑Fi: проверяется прямое соединение, без обхода.'))
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
  const active = res.filter(x => !x.skip);
  const ok = active.filter(x => x.ok), n = active.length;
  const badge = $('ti' + i);
  if(!badge) return;
  badge.className = 'status ' + (ok.length === n && n > 0 ? 'ok' : (ok.length ? 'warn' : 'bad'));
  badge.innerHTML = icon(ok.length === n && n > 0 ? 'check' : (ok.length ? 'warn' : 'close'), 's16');
  const tr = $('tr' + i);
  if(tr) tr.textContent = ok.length + '/' + n;

  const failedProtos = res.filter(x => !x.ok && !x.skip).map(x => {
    const pName = PROTO_NAMES[x.proto];
    const rName = t(PROBE_REASON[x.reason] || PROBE_REASON.other);
    return pName ? `${pName}: ${rName}` : rName;
  });
  const reasons = [...new Set(failedProtos)];

  const ts = $('ts' + i);
  if(ts) {
    const avg = ok.length ? t('{0} мс в среднем', Math.round(ok.reduce((a, x) => a + x.ms, 0) / ok.length)) : '';
    ts.textContent = avg + (avg && reasons.length ? ' · ' : '') + reasons.join(', ');
  }
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
      '<span class="li-primary truncate">' + esc(provider.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
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
      '<span class="li-primary truncate">' + esc(name.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + esc(sub) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isHijacked ? 't-label-medium bad' : 'li-value') + '">' + esc(trail) + '</span>' +
  '</div>';
}

function renderTgRow(i, name, ip, status, ping){
  const isOk = status === 'ok';
  const stClass = isOk ? 'ok' : 'bad';
  const icName = isOk ? 'check' : 'close';
  const trail = isOk ? (ping || 'OK') : t('СБОЙ');
  return '<div class="list-item two-line" id="tgrow' + i + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(name.replace(/_/g, ' ')) + ' <span class="muted li-mono">(' + esc(ip) + ')</span></span>' +
      '<span class="li-secondary">' + (isOk ? t('Соединение установлено') : t('Нет ответа (таймаут / сброс)')) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isOk ? 'li-value' : 't-label-medium bad') + '">' + esc(trail) + '</span>' +
  '</div>';
}

function renderBenchRow(idx, name, ok, total, avg_ms, top_fail, isRunning){
  const stratTitle = typeof strategyName === 'function' ? strategyName(name) : name;
  if(isRunning){
    return '<div class="list-item two-line" id="benchrow' + idx + '">' +
      '<span class="status info"><span class="spinner" style="width:14px;height:14px;"></span></span>' +
      '<span class="li-text">' +
        '<span class="li-primary truncate">' + esc(stratTitle) + ' <span class="muted li-mono">(' + esc(name) + ')</span></span>' +
        '<span class="li-secondary">' + esc(t('Тестирование соединений…')) + '</span>' +
      '</span>' +
      '<span class="li-trail li-value">…</span>' +
    '</div>';
  }
  const isAllOk = total > 0 && ok === total;
  const isPartOk = ok > 0;
  const stClass = isAllOk ? 'ok' : (isPartOk ? 'warn' : 'bad');
  const icName = isAllOk ? 'check' : (isPartOk ? 'warn' : 'close');
  let sub = '';
  if(total === 0){
    sub = t('Не запустилась');
  } else {
    sub = t('Успешно: {0}/{1}', ok, total);
    if(ok > 0) sub += ` · ${avg_ms} ` + t('мс');
    if(top_fail && top_fail !== '-'){
      const failReason = t(PROBE_REASON[top_fail] || top_fail);
      sub += ` · ${failReason}`;
    }
  }
  const pct = total > 0 ? Math.round((ok / total) * 100) + '%' : '0%';
  return '<div class="list-item two-line" id="benchrow' + idx + '">' +
    '<span class="status ' + stClass + '">' + icon(icName, 's16') + '</span>' +
    '<span class="li-text">' +
      '<span class="li-primary truncate">' + esc(stratTitle) + ' <span class="muted li-mono">(' + esc(name) + ')</span></span>' +
      '<span class="li-secondary">' + esc(sub) + '</span>' +
    '</span>' +
    '<span class="li-trail ' + (isAllOk || isPartOk ? 'li-value' : 't-label-medium bad') + '">' + esc(pct) + '</span>' +
  '</div>';
}

function renderBenchBest(name, ok, total, avg_ms){
  const el = $('test-bench-best');
  if(!el) return;
  if(!name || ok <= 0){
    el.hidden = false;
    el.innerHTML = banner('danger', 'error', '<b>' + esc(t('Ни одна стратегия не сработала')) + '</b><br>' +
      esc(t('Все протестированные стратегии потерпели неудачу на контрольном наборе сайтов.')));
    return;
  }
  el.hidden = false;
  const stratTitle = typeof strategyName === 'function' ? strategyName(name) : name;
  const cur = (typeof currentStrategy !== 'undefined' && currentStrategy) ? currentStrategy : 'default';
  const isCurrent = cur === name;

  el.innerHTML = '<div class="subhead-row" style="margin-top:0;">' +
    '<span class="subhead plain">' + esc(t('Лучшая стратегия по результатам прохода')) + '</span>' +
    '<span class="pill tonal">' + esc(t('{0}/{1} хостов ({2} мс)', ok, total, avg_ms)) + '</span>' +
  '</div>' +
  '<div class="t-body-medium">' +
    esc(t('Стратегия «{0}» показала максимальную проходимость и скорость на контрольных ресурсах.', stratTitle)) +
  '</div>' +
  '<div class="row" style="margin-top:12px; gap:8px;">' +
    '<button class="btn with-icon state ' + (isCurrent ? 'tonal' : '') + '" onclick="applyRecommendedStrategy(' + jsArg(name) + ')"' + (isCurrent ? ' disabled' : '') + '>' +
      icon(isCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isCurrent ? esc(t('Стратегия «{0}» уже действует', stratTitle)) : esc(t('Применить «{0}»', stratTitle))) + '</span>' +
    '</button>' +
  '</div>';
}

function sortBenchList(){
  const listEl = $('test-bench-list');
  if(!listEl) return;
  const sorted = Object.values(benchResults).sort((a, b) => b.ok - a.ok || a.avg_ms - b.avg_ms);
  listEl.innerHTML = sorted.map(it => renderBenchRow(it.idx, it.name, it.ok, it.total, it.avg_ms, it.top_fail, false)).join('');
}

function startBenchFromRec(){
  selectTestTab('bench');
  runTest();
}

function resetTestResults(){
  ['tr', 'test-tcp16-list', 'test-dns-list', 'test-tg-list', 'test-bench-list'].forEach(id => {
    const el = $(id);
    if(el){ el.innerHTML = ''; el._html = ''; }
  });
  webResults = {}; tcp16Results = {}; dnsResults = {}; tgResults = {}; tgMediaSpeed = null; lastRecommendation = null;
  benchResults = {}; benchTotalStrats = 0; benchBestStrat = null;
  const recEl = $('test-recommendation');
  if(recEl){ recEl.hidden = true; recEl.innerHTML = ''; }
  const tgBadge = $('test-tg-media-badge');
  if(tgBadge){ tgBadge.hidden = true; tgBadge.textContent = ''; }
  const benchBadge = $('test-bench-badge');
  if(benchBadge){ benchBadge.hidden = true; benchBadge.textContent = ''; }
  const benchBest = $('test-bench-best');
  if(benchBest){ benchBest.hidden = true; benchBest.innerHTML = ''; }
}

async function stopTest(){
  if(!testRunning) return;
  testCancelled = true;
  if(webViewAbortCtrl){
    try { webViewAbortCtrl.abort(); } catch(_){}
  }
  const tb = $('tb');
  if(tb){
    tb.disabled = true;
    tb.innerHTML = '<span class="spinner"></span><span>' + esc(t('Остановка…')) + '</span>';
  }
  await ctlx(['probe-cancel']);
  toast(t('Проверка остановлена'));
}

async function runTest(){
  if(testRunning){
    await stopTest();
    return;
  }
  testRunning = true;
  testCancelled = false;
  webViewAbortCtrl = new AbortController();

  const tb = $('tb');
  if(tb){
    tb.disabled = false;
    tb.classList.add('danger');
    tb.innerHTML = icon('stop', 's18') + '<span>' + esc(t('Остановить')) + '</span>';
  }
  if($('test-empty')) $('test-empty').hidden = true;

  resetTestResults();

  await stat(true);
  renderTestWarn();
  await refreshNetInfo();

  const hosts = [];
  let tool = '';

  const onLine = l => {
    if(testCancelled) return;
    const p = l.split('\t');
    if(p[0] === 'tool') {
      tool = p[1];
    } else if(p[0] === 'H') {
      hosts[+p[1]] = p[2];
      webResults[p[1]] = {host: p[2], list: []};
      $('tr').insertAdjacentHTML('beforeend', testRow(p[1], p[2]));
    } else if(p[0] === 'R' && webResults[p[1]]) {
      const v = (p[3] || '').split(' ');
      const proto = +p[2] || (webResults[p[1]].list.length + 1);
      const isOk = v[0] === 'ok';
      const isSkip = v[0] === 'skip';
      const resItem = isOk
        ? { ok: true, ms: +v[1] || 0, proto }
        : (isSkip
            ? { ok: false, skip: true, reason: v[1] || 'skip', proto }
            : { ok: false, reason: v[1] || 'other', proto });
      webResults[p[1]].list.push(resItem);
      const active = webResults[p[1]].list.filter(x => !x.skip);
      const rowEl = $('tr' + p[1]);
      if(rowEl) rowEl.textContent = active.filter(x => x.ok).length + '/' + active.length;
      if(webResults[p[1]].list.length === 4) finishTestRow(p[1], webResults[p[1]].list);
    } else if(p[0] === 'T16') {
      const idx = p[1], provider = p[2], ip = p[3], port = p[4], st = p[5], detail = p[6];
      tcp16Results[idx] = {provider, ip, port, status: st, detail};
      const existing = $('tcprow' + idx);
      const rowHtml = renderTcp16Row(idx, provider, ip, port, st, detail);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-tcp16-list')) $('test-tcp16-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'DNS') {
      const idx = p[1], name = p[2], ip = p[3], udp = p[4], doh = p[5], hijacked = p[6], detail = p[7];
      dnsResults[idx] = {name, ip, udp, doh, hijacked, detail};
      const existing = $('dnsrow' + idx);
      const rowHtml = renderDnsRow(idx, name, ip, udp, doh, hijacked, detail);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-dns-list')) $('test-dns-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'TG') {
      const idx = p[1], name = p[2], ip = p[3], st = p[4], ping = p[5];
      tgResults[idx] = {name, ip, status: st, ping};
      const existing = $('tgrow' + idx);
      const rowHtml = renderTgRow(idx, name, ip, st, ping);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-tg-list')) $('test-tg-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'TG_MEDIA') {
      const st = p[1], spd = p[2];
      tgMediaSpeed = {status: st, speed: spd};
      const badge = $('test-tg-media-badge');
      if(badge){
        badge.hidden = false;
        badge.textContent = st === 'ok' ? `${spd}` : t('Медиа: сбой');
        badge.className = 'pill tonal';
      }
    } else if(p[0] === 'BENCH_START') {
      benchTotalStrats = +p[1] || 0;
      const badge = $('test-bench-badge');
      if(badge){
        badge.hidden = false;
        badge.className = 'pill tonal';
        badge.textContent = t('Проверка 0/{0}', benchTotalStrats);
      }
    } else if(p[0] === 'BENCH_RUN') {
      const idx = p[1], strat = p[2], total = p[3];
      const badge = $('test-bench-badge');
      if(badge){
        badge.hidden = false;
        badge.className = 'pill tonal';
        badge.textContent = t('Тест {0}/{1}: {2}', +idx + 1, total, typeof strategyName === 'function' ? strategyName(strat) : strat);
      }
      const existing = $('benchrow' + idx);
      const rowHtml = renderBenchRow(idx, strat, null, null, null, null, true);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-bench-list')) $('test-bench-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'BENCH_RES') {
      const idx = p[1], strat = p[2], ok = +p[3] || 0, total = +p[4] || 0, avg_ms = +p[5] || 0, top_fail = p[6] || '-';
      benchResults[strat] = { idx, name: strat, ok, total, avg_ms, top_fail };
      const existing = $('benchrow' + idx);
      const rowHtml = renderBenchRow(idx, strat, ok, total, avg_ms, top_fail, false);
      if(existing) existing.outerHTML = rowHtml;
      else if($('test-bench-list')) $('test-bench-list').insertAdjacentHTML('beforeend', rowHtml);
    } else if(p[0] === 'BENCH_BEST') {
      const strat = p[1], ok = +p[2] || 0, total = +p[3] || 0, avg_ms = +p[4] || 0;
      benchBestStrat = { name: strat, ok, total, avg_ms };
      sortBenchList();
      renderBenchBest(strat, ok, total, avg_ms);
      const badge = $('test-bench-badge');
      if(badge){
        badge.hidden = false;
        badge.className = 'pill tonal';
        badge.textContent = t('Завершено ({0} стратегий)', benchTotalStrats);
      }
    }
  };

  try {
    if(currentTestTab === 'bench'){
      await ctlx(['bench-strategies'], 300000, onLine);
    } else {
      const r = await ctlx(['probe-dpi', currentTestTab], 180000, onLine);
      if(!testCancelled){
        if(tool === 'none' || (r.code && !hosts.length && currentTestTab === 'web')) {
          await runTestWebView();
        } else {
          Object.keys(webResults).forEach(i => {
            if(webResults[i].list.length < 4) {
              finishTestRow(i, webResults[i].list.length ? webResults[i].list : [{ok: false, reason: 'timeout'}]);
            }
          });
        }
      }
    }
  } finally {
    testRunning = false;
    if(testCancelled){
      if(currentTestTab === 'bench'){
        const badge = $('test-bench-badge');
        if(badge){
          badge.className = 'pill tonal';
          badge.textContent = t('Проверка остановлена');
        }
        document.querySelectorAll('#test-bench-list .list-item').forEach(el => {
          if(el.querySelector('.spinner')){
            const liSec = el.querySelector('.li-secondary');
            if(liSec) liSec.textContent = t('Прервано');
            const liTrail = el.querySelector('.li-trail');
            if(liTrail) liTrail.textContent = '—';
            const st = el.querySelector('.status');
            if(st){
              st.className = 'status warn';
              st.innerHTML = icon('close', 's16');
            }
          }
        });
      } else {
        document.querySelectorAll('#tr .list-item, #test-tcp16-list .list-item, #test-dns-list .list-item, #test-tg-list .list-item').forEach(el => {
          if(el.querySelector('.spinner')){
            const liSec = el.querySelector('.li-secondary');
            if(liSec) liSec.textContent = t('Прервано');
            const liTrail = el.querySelector('.li-trail');
            if(liTrail) liTrail.textContent = '—';
            const st = el.querySelector('.status');
            if(st){
              st.className = 'status warn';
              st.innerHTML = icon('close', 's16');
            }
          }
        });
      }
    }
    if(tb){
      tb.classList.remove('danger');
      tb.disabled = false;
      const btnLabel = currentTestTab === 'bench' ? t('Запустить автоподбор') : t('Проверить снова');
      tb.innerHTML = icon('play', 's18') + '<span>' + esc(btnLabel) + '</span>';
    }
    if(currentTestTab !== 'bench' && !testCancelled){
      renderRecommendation();
    }
  }
}

/* Fallback: fetch from the WebView */
async function probeFetch(u, signal){
  const t0 = performance.now();
  try {
    await fetch('https://' + u + (u.includes('?') ? '&' : '?') + '_=' + Date.now() + Math.random(),
      {mode: 'no-cors', cache: 'no-store', credentials: 'omit', signal});
    return {ok: true, ms: performance.now() - t0};
  } catch(e) {
    return {ok: false, reason: signal && signal.aborted ? 'timeout' : 'reset'};
  }
}

async function runTestWebView(){
  setHTML('test-warn', $('test-warn').innerHTML + banner('', 'warn',
    t('На устройстве нет curl или busybox wget с TLS — проверка идёт через WebView и показывает лишь приблизительную картину.')), false);
  const r = await ctlx(['get-list', 'probe_hosts']);
  const hosts = (r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#');
  setHTML('tr', hosts.map((h, i) => testRow(i, h)).join(''), false);
  if(!hosts.length){
    if($('test-empty')) $('test-empty').hidden = false;
    if($('test-empty-title')) $('test-empty-title').textContent = t('probe_hosts.list пуст');
    return;
  }
  for(let i = 0; i < hosts.length; i++){
    if(testCancelled) break;
    const h = hosts[i];
    const out = [];
    for(let k = 0; k < 3; k++){
      if(testCancelled) break;
      const subCtrl = new AbortController();
      const onParentAbort = () => subCtrl.abort();
      if(webViewAbortCtrl) webViewAbortCtrl.signal.addEventListener('abort', onParentAbort);
      const tm = setTimeout(() => subCtrl.abort(), 6000);
      try {
        out.push(await probeFetch(h, subCtrl.signal));
      } finally {
        clearTimeout(tm);
        if(webViewAbortCtrl) webViewAbortCtrl.signal.removeEventListener('abort', onParentAbort);
      }
    }
    finishTestRow(i, out);
  }
}

/* Result analysis and strategy recommendation */
function analyzeProbeResults(webRes, tcp16Res, dnsRes){
  const webKeys = Object.keys(webRes || {});
  const tcpKeys = Object.keys(tcp16Res || {});
  const dnsKeys = Object.keys(dnsRes || {});

  if(!webKeys.length && !tcpKeys.length && !dnsKeys.length) return null;

  let totalWeb = webKeys.length;
  let okWeb = 0;
  let rstCount = 0;
  let alertCount = 0;
  let dropCount = 0;
  let otherFailWeb = 0;

  webKeys.forEach(k => {
    const list = (webRes[k].list || []).filter(x => !x.skip);
    const oks = list.filter(x => x.ok);
    if(oks.length >= 2 || (list.length > 0 && oks.length === list.length)) {
      okWeb++;
    } else {
      const reasons = list.filter(x => !x.ok).map(x => x.reason);
      if(reasons.some(r => r === 'tls_alert')) alertCount++;
      else if(reasons.some(r => r === 'tls_rst' || r === 'reset')) rstCount++;
      else if(reasons.some(r => r === 'drop' || r === 'timeout')) dropCount++;
      else otherFailWeb++;
    }
  });

  let tcp16Detected = 0;
  let tcp16Clean = 0;
  tcpKeys.forEach(k => {
    const st = tcp16Res[k].status;
    if(st === 'detected') tcp16Detected++;
    else if(st === 'clean') tcp16Clean++;
  });

  let dnsHijacked = 0;
  let dnsUdpBlocked = 0;
  dnsKeys.forEach(k => {
    if(dnsRes[k].hijacked === 'yes') dnsHijacked++;
    if(dnsRes[k].udp === 'fail') dnsUdpBlocked++;
  });

  const failWeb = totalWeb - okWeb;
  const isClean = (failWeb === 0 && tcp16Detected === 0);

  let strategy = 'fake_tls_auto';
  let altStrategies = ['alt4_mod', 'alt11'];
  let summaryTitle = '';
  let reason = '';

  if(isClean){
    const cur = (typeof currentStrategy !== 'undefined' && currentStrategy) ? currentStrategy : 'default';
    strategy = cur;
    altStrategies = cur === 'default' ? ['fake_tls_auto', 'alt4_mod'] : ['default', 'fake_tls_auto'];
    summaryTitle = t('Блокировок не обнаружено');
    reason = t('Все проверенные сайты и соединения к CDN работают стабильно без вмешательства DPI.');
  } else if(tcp16Detected > 0){
    if(alertCount > 0 || rstCount > 0){
      strategy = 'fake_tls_auto_alt2';
      altStrategies = ['fake_tls_auto_alt3', 'alt4_mod'];
      summaryTitle = t('Обнаружены TCP 16-20KB и фильтрация TLS');
      reason = t('DPI разрывает сессии после 16-20 КБ данных и блокирует ClientHello. Рекомендуется стратегия со сплитом пакетов и маскировкой перекрытиями (multisplit + seqovl).');
    } else {
      strategy = 'alt4_mod';
      altStrategies = ['alt4', 'fake_tls_auto_alt2'];
      summaryTitle = t('Обнаружен фильтр TCP 16-20KB');
      reason = t('Соединения к зарубежным CDN (Cloudflare/Hetzner) обрываются после 16-20 КБ данных. Рекомендуется сегментация TCP пакетов.');
    }
  } else if(alertCount > 0){
    strategy = 'fake_tls_auto';
    altStrategies = ['fake_tls_auto_alt', 'simple_fake_alt2'];
    summaryTitle = t('Обнаружена блокировка по SNI (TLS Alert)');
    reason = t('DPI перехватывает имя хоста в ClientHello и посылает TLS Alert. Рекомендуется стратегия с поддельным SNI и рандомизацией.');
  } else if(rstCount > 0){
    strategy = 'fake_tls_auto';
    altStrategies = ['simple_fake_alt2', 'alt8'];
    summaryTitle = t('Обнаружен активный сброс (TLS RST)');
    reason = t('DPI инжектирует пакеты TCP RST при попытке установить защищенное соединение. Рекомендуется отправка фейкового ClientHello со сдвигом окна.');
  } else if(dropCount > 0){
    strategy = 'alt11';
    altStrategies = ['alt12', 'exp'];
    summaryTitle = t('Обнаружен тихий сброс (Drop / Timeout)');
    reason = t('DPI молча отбрасывает пакеты без ответа. Рекомендуется стратегия с повышенным числом повторов (repeats=8) и модификацией TCP Timestamps.');
  } else {
    strategy = 'eduncey';
    altStrategies = ['hardcorp74', 'fake_tls_auto'];
    summaryTitle = t('Смешанный профиль цензуры');
    reason = t('Обнаружен нестандартный профиль блокировок. Рекомендуется адаптивная стратегия с циклическим самоподбором методов (circular).');
  }

  let dnsWarning = '';
  if(dnsHijacked > 0 || dnsUdpBlocked > 0){
    dnsWarning = t('Внимание: обнаружен перехват или подмена DNS провайдером. Рекомендуется включить «Частный DNS» (DoH) в настройках системы.');
  }

  return {
    strategy,
    altStrategies,
    title: summaryTitle,
    reason,
    dnsWarning,
    isClean,
    stats: { totalWeb, okWeb, failWeb, tcp16Detected, tcp16Clean, dnsHijacked }
  };
}

function renderRecommendation(){
  const el = $('test-recommendation');
  if(!el) return;
  const rec = analyzeProbeResults(webResults, tcp16Results, dnsResults);
  lastRecommendation = rec;
  if(!rec){
    el.hidden = true;
    el.innerHTML = '';
    return;
  }
  el.hidden = false;

  const cur = (typeof currentStrategy !== 'undefined' && currentStrategy) ? currentStrategy : 'default';
  const isCurrent = cur === rec.strategy;
  const stratTitle = typeof strategyName === 'function' ? strategyName(rec.strategy) : rec.strategy;

  let html = '<div class="subhead-row" style="margin-top:0;">' +
    '<span class="subhead plain">' + esc(t('Автоподбор стратегии')) + '</span>' +
    '<span class="pill tonal">' + esc(rec.title) + '</span>' +
  '</div>' +
  '<div class="t-body-medium">' + esc(rec.reason) + '</div>';

  if(rec.dnsWarning){
    html += '<div class="helper err" style="margin-top:8px;">' + icon('warn', 's16') + ' ' + esc(rec.dnsWarning) + '</div>';
  }

  html += '<div class="row" style="margin-top:12px; flex-wrap:wrap; gap:8px;">' +
    '<button class="btn with-icon state ' + (isCurrent ? 'tonal' : '') + '" onclick="applyRecommendedStrategy(' + jsArg(rec.strategy) + ')"' + (isCurrent ? ' disabled' : '') + '>' +
      icon(isCurrent ? 'check' : 'tune', 's18') +
      '<span>' + (isCurrent ? esc(t('Стратегия «{0}» уже действует', stratTitle)) : esc(t('Применить «{0}»', stratTitle))) + '</span>' +
    '</button>';

  if(rec.altStrategies && rec.altStrategies.length > 0){
    rec.altStrategies.forEach(altName => {
      const isAltCur = cur === altName;
      const altTitle = typeof strategyName === 'function' ? strategyName(altName) : altName;
      html += '<button class="btn tonal sm state" onclick="applyRecommendedStrategy(' + jsArg(altName) + ')"' + (isAltCur ? ' disabled' : '') + '>' +
        '<span>' + esc(isAltCur ? altTitle + ' (' + t('действует') + ')' : altTitle) + '</span>' +
      '</button>';
    });
  }

  html += '<button class="btn text sm with-icon state" onclick="startBenchFromRec()">' +
    icon('tune', 's16') +
    '<span>' + esc(t('Полный автоподбор по всем стратегиям')) + '</span>' +
  '</button>';

  html += '</div>';

  el.innerHTML = html;
}

async function applyRecommendedStrategy(name){
  if(typeof applyStrategy === 'function'){
    await applyStrategy(name);
    renderRecommendation();
    if(benchBestStrat){
      renderBenchBest(benchBestStrat.name, benchBestStrat.ok, benchBestStrat.total, benchBestStrat.avg_ms);
    }
  }
}

function copyTestReport(){
  let rep = '### DPI Detector (nfqws2-android)\n\n';
  if(netInfoData){
    rep += `**Сеть:** IP: ${netInfoData.ip || '—'} (${netInfoData.loc || '—'}), Провайдер: ${netInfoData.isp || '—'} (${netInfoData.asn || '—'})\n`;
    rep += `**Обход:** ${netInfoData.status === 'running' ? 'Активен' : 'Остановлен'}, Стратегия: ${netInfoData.strategy || '—'}, DNS: ${netInfoData.dns || '—'}\n\n`;
  }
  const rec = lastRecommendation || analyzeProbeResults(webResults, tcp16Results, dnsResults);
  if(rec){
    rep += `#### Анализ и автоподбор стратегии:\n`;
    rep += `- Вердикт: ${rec.title}\n`;
    rep += `- Рекомендованная стратегия: ${rec.strategy}\n`;
    rep += `- Обоснование: ${rec.reason}\n`;
    if(rec.dnsWarning) rep += `- DNS: ${rec.dnsWarning}\n`;
    rep += '\n';
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
    rep += '#### Telegram датацентры:\n';
    if(tgMediaSpeed && tgMediaSpeed.status === 'ok'){
      rep += `*Скорость загрузки медиа:* ${tgMediaSpeed.speed}\n`;
    }
    for(const k of Object.keys(tgResults)){
      const it = tgResults[k];
      rep += `- ${it.name} (${it.ip}): ${it.status === 'ok' ? 'OK (' + it.ping + ')' : 'FAIL (' + it.ping + ')'}\n`;
    }
    rep += '\n';
  }
  if(Object.keys(benchResults).length > 0){
    rep += '#### Результаты полного автоподбора стратегий:\n';
    if(benchBestStrat){
      rep += `*Победитель:* ${benchBestStrat.name} (${benchBestStrat.ok}/${benchBestStrat.total}, ${benchBestStrat.avg_ms} мс)\n`;
    }
    const sorted = Object.values(benchResults).sort((a, b) => b.ok - a.ok || a.avg_ms - b.avg_ms);
    for(const it of sorted){
      rep += `- ${it.name}: ${it.ok}/${it.total} (${it.avg_ms} мс)` + (it.top_fail && it.top_fail !== '-' ? ` [сбои: ${it.top_fail}]` : '') + '\n';
    }
    rep += '\n';
  }

  copyText(rep, t('Отчёт скопирован в буфер обмена'), t('Не удалось скопировать: выделите текст вручную'));
}
