/* nfqws2 WebUI - core: utilities, locale, module bridge, navigation */

/* Data comes from bin/nfqws2-ctl only; the UI degrades without it */
const MOD = '/data/adb/modules/nfqws2-android', CTL = MOD + '/bin/nfqws2-ctl';
const $ = id => document.getElementById(id);
let S = {}, seq = 0, pkgs = [];
const q = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
const b64 = s => btoa(unescape(encodeURIComponent(s)));
const unb64 = s => { try { return decodeURIComponent(escape(atob(s))); } catch(e) { return atob(s); } };
function b64toBlob(b64Data, contentType){
  contentType = contentType || 'application/x-tar';
  const bin = atob(String(b64Data || '').replace(/\s+/g, ''));
  const len = bin.length;
  const bytes = new Uint8Array(len);
  for(let i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type: contentType });
}
function blobToB64(blob){
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => {
      const s = String(r.result || '');
      resolve(s.includes(',') ? s.split(',')[1] : s);
    };
    r.onerror = reject;
    r.readAsDataURL(blob);
  });
}
async function promptSaveDir(titleKey){
  let targetDir = (typeof store !== 'undefined' && store.get('nfq_save_dir')) || '/sdcard/Download';
  if(typeof window !== 'undefined' && window.ksu && typeof mdPrompt === 'function'){
    const chosen = await mdPrompt(
      t(titleKey),
      t('Укажите папку для сохранения архива:'),
      targetDir,
      t('Папка для сохранения'),
      { ok: t('Сохранить') }
    );
    if(chosen === null) return null;
    targetDir = (chosen || targetDir).trim().replace(/\/+$/, '') || '/sdcard/Download';
    if(!targetDir.startsWith('/')) targetDir = '/sdcard/' + targetDir;
    if(typeof store !== 'undefined') store.set('nfq_save_dir', targetDir);
  }
  return targetDir;
}
async function copyText(text, okMsg, errMsg){
  let ok = false;
  try {
    if(navigator.clipboard && navigator.clipboard.writeText){
      await navigator.clipboard.writeText(text);
      ok = true;
    } else throw new Error();
  } catch(e){
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
    document.body.append(ta);
    ta.select();
    try { ok = document.execCommand('copy'); } catch(e2) {}
    ta.remove();
  }
  toast(ok ? okMsg : (errMsg || t('Не удалось скопировать: выделите текст вручную')));
}
async function exportBlobFile(blob, filename, mimeType, localFilePath, targetDir){
  mimeType = mimeType || 'application/x-tar';
  targetDir = (targetDir || (typeof store !== 'undefined' && store.get('nfq_save_dir')) || '/sdcard/Download').trim().replace(/\/+$/, '');
  if(!targetDir.startsWith('/')) targetDir = '/sdcard/' + targetDir;
  const targetFile = targetDir.endsWith('.tar') ? targetDir : (targetDir + '/' + filename);
  const destFolder = targetFile.substring(0, targetFile.lastIndexOf('/')) || '/sdcard/Download';
  if(!window?.ksu && typeof window !== 'undefined' && window.showSaveFilePicker){
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: filename,
        types: [{ description: filename, accept: { [mimeType]: ['.tar'], 'application/octet-stream': ['.tar'] } }]
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      toast(t('Файл сохранён: {0}', filename));
      return true;
    } catch(e){
      if(e && e.name === 'AbortError') return false;
    }
  }
  if(!window?.ksu && typeof navigator !== 'undefined' && navigator.canShare && typeof File !== 'undefined'){
    try {
      let file = new File([blob], filename, { type: mimeType });
      if(!navigator.canShare({ files: [file] })){
        file = new File([blob], filename, { type: 'application/octet-stream' });
      }
      if(!navigator.canShare({ files: [file] })){
        file = new File([blob], filename, { type: '' });
      }
      if(navigator.canShare({ files: [file] })){
        await navigator.share({ files: [file], title: filename });
        toast(t('Экспорт завершён: {0}', filename));
        return true;
      }
    } catch(e){
      if(e && e.name === 'AbortError') return false;
    }
  }
  try {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { a.remove(); URL.revokeObjectURL(url); }, 2000);
  } catch(e) {}
  if(localFilePath && typeof window !== 'undefined' && window.ksu){
    try {
      const safUri = 'content://com.android.externalstorage.documents/document/primary%3ADownload%2F' + encodeURIComponent(filename);
      const cmd =
        'f=' + q(localFilePath) + '; tf=' + q(targetFile) + '; td=' + q(destFolder) + '; ' +
        'mkdir -p "$td" 2>/dev/null; ' +
        'if [ "$f" != "$tf" ]; then cp -f "$f" "$tf" 2>/dev/null; chmod 666 "$tf" 2>/dev/null; fi; ' +
        'case "$tf" in /sdcard/*) rf="/storage/emulated/0/${tf#/sdcard/}" ;; *) rf="$tf" ;; esac; ' +
        'am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$rf" >/dev/null 2>&1; ' +
        'u=$(content insert --uri content://media/external/file --bind _data:s:"$rf" --bind mime_type:s:"application/octet-stream" 2>/dev/null | grep -o \'content://[^ ]*\'); ' +
        '[ -z "$u" ] && u=$(content query --uri content://media/external/file --projection _id --where "_data=\'$tf\' OR _data=\'$rf\'" 2>/dev/null | grep -o \'_id=[0-9]*\' | head -n1 | sed \'s/_id=/content:\\/\\/media\\/external\\/file\\//\'); ' +
        '[ -z "$u" ] && u=' + q(safUri) + '; ' +
        'am start -a android.intent.action.SEND --user 0 -t "*/*" --eu android.intent.extra.STREAM "$u" --es android.intent.extra.SUBJECT ' + q(filename) + ' --es android.intent.extra.TITLE ' + q(filename) + ' -f 0x10000001 >/dev/null 2>&1';
      await sh(cmd);
    } catch(e) {}
    toast(t('Архив сохранён: {0}', targetFile));
    return true;
  }
  toast(t('Экспорт завершён: {0}', filename));
  return true;
}
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
/* esc() alone is not enough inside onclick: HTML decoding restores &#39; before JS parses it */
const jsArg = v => esc(JSON.stringify(String(v == null ? '' : v)));
const icon = (name, cls) => '<svg aria-hidden="true" class="icon ' + (cls || 's20') + '"><use href="#i-' + name + '"/></svg>';

/* localStorage can be unavailable */
const store = {
  get(k){ try { return localStorage.getItem(k); } catch(e) { return null; } },
  set(k, v){ try { localStorage.setItem(k, v); } catch(e) {} },
  del(k){ try { localStorage.removeItem(k); } catch(e) {} }
};

/* Keys are the Russian strings themselves; EN maps them. data-t / data-ta mark static nodes */
let LANG = store.get('nfq_lang') === 'en' ? 'en' : 'ru';
let EN = {};
function t(s){
  let r = (LANG === 'en' && EN[s] != null) ? EN[s] : s;
  for(let i = 1; i < arguments.length; i++) r = r.split('{' + (i - 1) + '}').join(arguments[i]);
  return r;
}
function translateStatic(){
  document.documentElement.lang = LANG;
  document.querySelectorAll('[data-t]').forEach(el => {
    if(el.dataset.ru == null) el.dataset.ru = el.textContent.trim();
    const key = el.getAttribute('data-t') || el.dataset.ru;
    el.textContent = (LANG === 'en' && EN[key] != null) ? EN[key] : el.dataset.ru;
  });
  document.querySelectorAll('[data-ta]').forEach(el => el.dataset.ta.split(',').forEach(a => {
    const k = 'ru_' + a.replace(/-/g, '_');
    if(el.dataset[k] == null) el.dataset[k] = el.getAttribute(a) || '';
    el.setAttribute(a, t(el.dataset[k]));
  }));
}
const fmtCount = n => Number(n).toLocaleString(LANG === 'en' ? 'en-US' : 'ru-RU');

/* Ripple, delegated so it survives innerHTML */
document.addEventListener('pointerdown', e => {
  if(typeof isAnimationsDisabled === 'function' && isAnimationsDisabled()) return;
  let el = e.target.closest && e.target.closest('.state, .nav-dest');
  if(el && el.classList.contains('nav-dest')) el = el.querySelector('.nav-ind');
  if(!el || el.classList.contains('is-disabled') || el.disabled) return;
  const r = el.getBoundingClientRect();
  const size = Math.max(r.width, r.height) * 2.2;
  const s = document.createElement('span');
  s.className = 'ripple';
  s.style.cssText = 'width:' + size + 'px;height:' + size + 'px;left:' +
    ((e.clientX || r.left + r.width / 2) - r.left - size / 2) + 'px;top:' +
    ((e.clientY || r.top + r.height / 2) - r.top - size / 2) + 'px';
  el.append(s);
  setTimeout(() => s.remove(), 520);
}, {passive: true});

document.addEventListener('keydown', e => {
  if(e.key !== 'Enter' && e.key !== ' ') return;
  const el = e.target && e.target.closest && e.target.closest('[role="button"]:not(button)');
  if(el && !el.classList.contains('is-disabled')){ e.preventDefault(); el.click(); }
});

/* Menu opens under the anchor, flips up when there is no room; outside click only closes */
let openMenuEntry = null;
function closeMenu(){ if(openMenuEntry) openMenuEntry.close(); }
function openMenu(anchor, items){
  if(openMenuEntry && openMenuEntry.anchor === anchor){ closeMenu(); return null; }
  closeMenu();
  const viaKeyboard = anchor.matches(':focus-visible');
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.setAttribute('role', 'menu');
  for(const it of items){
    if(it === '-'){ const sep = document.createElement('div'); sep.className = 'sep'; sep.setAttribute('role', 'separator'); menu.append(sep); continue; }
    const mi = document.createElement('button');
    mi.className = 'mi state';
    mi.type = 'button';
    mi.setAttribute('role', 'menuitem');
    mi.innerHTML = ('icon' in it ? '<span class="mi-icon">' + (it.icon ? icon(it.icon, 's24') :
        '<span style="display:block;width:24px;height:24px"></span>') + '</span>' : '') +
      '<span class="mi-text">' + esc(it.label) + '</span>';
    mi.onclick = () => { close(); if(it.onClick) it.onClick(); };
    menu.append(mi);
  }
  const back = document.createElement('div');
  back.className = 'menu-back';
  back.addEventListener('click', e => { e.preventDefault(); close(); });
  $('layer').append(back, menu);
  const r = anchor.getBoundingClientRect(), mw = menu.offsetWidth, mh = menu.offsetHeight;
  let top = r.bottom + 4;
  if(top + mh > innerHeight - 8){ top = Math.max(8, r.top - mh - 4); menu.classList.add('up'); }
  const end = r.left + r.width / 2 > innerWidth / 2;
  if(end) menu.classList.add('end');
  menu.style.left = Math.max(8, Math.min(end ? r.right - mw : r.left, innerWidth - mw - 8)) + 'px';
  menu.style.top = top + 'px';
  anchor.setAttribute('aria-expanded', 'true');
  const itemsEls = () => [...menu.querySelectorAll('.mi')];
  const onKey = e => {
    if(e.key === 'Escape'){ e.stopPropagation(); e.preventDefault(); close(); anchor.focus(); return; }
    if(e.key === 'ArrowDown' || e.key === 'ArrowUp'){
      e.preventDefault();
      const els = itemsEls(), i = els.indexOf(document.activeElement);
      const n = e.key === 'ArrowDown' ? (i + 1) % els.length : (i - 1 + els.length) % els.length;
      els[i < 0 ? 0 : n].focus();
    }
    if(e.key === 'Tab') close();
  };
  addEventListener('keydown', onKey, true);
  if(viaKeyboard){ const f = itemsEls()[0]; if(f) f.focus(); }
  let closed = false;
  const entry = { close, anchor };
  openMenuEntry = entry;
  scheduleSync();
  function close(){
    if(closed) return; closed = true;
    removeEventListener('keydown', onKey, true);
    back.remove();
    menu.classList.add('closing');
    setTimeout(() => menu.remove(), 110);
    anchor.setAttribute('aria-expanded', 'false');
    if(openMenuEntry === entry) openMenuEntry = null;
    scheduleSync();
  }
  return entry;
}


/* ksu.exec blocks the page thread and stutters transitions; use spawn when it answers correctly, exec as fallback */
let spawnOK = false;
function makeEmitter(){
  const h = {};
  return {
    on(ev, fn){ (h[ev] = h[ev] || []).push(fn); return this; },
    emit(ev){ const a = [].slice.call(arguments, 1); (h[ev] || []).forEach(f => { try { f.apply(null, a); } catch(e) {} }); }
  };
}
/* spawn stdout arrives inconsistently, so output frames itself: each line ends with \x1e, exit code last */
const REC = '\x1e', RC_TAG = '__nfq_rc=';
const frameCmd = cmd => '{ ' + cmd + '\nprintf \'\\n' + RC_TAG + '%s\\n\' "$?"; } | awk \'{ printf "%s\\036\\n", $0; fflush() }\'';
function spawnRun(cmd, ms, onLine){
  return new Promise(res => {
    const id = '__sp' + (++seq), out = [], err = [];
    let done = 0, tm = 0, buf = '', rc = null;
    const child = makeEmitter();
    child.stdout = makeEmitter();
    child.stderr = makeEmitter();
    const fin = (c, extraErr) => {
      if(done) return; done = 1; clearTimeout(tm);
      setTimeout(() => { delete window[id]; }, 1000);
      if(buf.replace(/[\r\n]/g, '')) take(buf.replace(/[\r\n]/g, ''));
      if(extraErr) err.push(extraErr);
      while(out.length && out[out.length - 1] === '') out.pop();   // trailing blank before the exit code
      res({code: rc != null ? rc : (+c || 0), out: out.join('\n'), err: err.join('\n')});
    };
    const take = rec => {
      if(rec.indexOf(RC_TAG) === 0){ rc = parseInt(rec.slice(RC_TAG.length), 10) || 0; return; }
      out.push(rec);
      if(onLine) try { onLine(rec); } catch(e) {}
    };
    child.stdout.on('data', d => {
      buf += String(d).replace(/[\r\n]/g, '');
      let i;
      while((i = buf.indexOf(REC)) >= 0){ take(buf.slice(0, i)); buf = buf.slice(i + 1); }
    });
    child.stderr.on('data', d => err.push(String(d)));
    child.on('exit', c => fin(rc == null && c != null ? c : rc));
    child.on('error', e => fin(1, String(e)));
    window[id] = child;
    tm = setTimeout(() => fin(-1, t('Таймаут')), ms);
    // KernelSU joins args with spaces and adds no quoting: send one command string, empty arg list
    try { window.ksu.spawn(frameCmd(cmd), '[]', '{}', id); } catch(e) { fin(1, String(e)); }
  });
}
function execRun(cmd, ms){
  return new Promise(res => {
    const k = window.ksu;
    if(!k || !k.exec){ res({code: 1, out: '', err: t('Нет моста ksu.exec')}); return; }
    const id = '__cb' + (++seq); let done = 0;
    const fin = (c, o, e) => { if(done) return; done = 1; clearTimeout(tm); delete window[id]; res({code: +c || 0, out: String(o || ''), err: String(e || '')}); };
    const tm = setTimeout(() => fin(-1, '', t('Таймаут')), ms);
    window[id] = fin;
    try { k.exec(cmd, '{}', id); } catch(e) { try { k.exec(cmd, id); } catch(e2) { fin(1, '', String(e2)); } }
  });
}
async function sh(cmd, ms, onLine){
  ms = ms || 15000;
  if(spawnOK) return spawnRun(cmd, ms, onLine);
  const r = await execRun(cmd, ms);
  if(onLine) r.out.split('\n').forEach(l => { try { onLine(l); } catch(e) {} });
  return r;
}
async function detectSpawn(){
  if(!window.ksu || typeof window.ksu.spawn !== 'function') return;
  const r = await spawnRun("printf 'nfq_a\\n\\nnfq_b\\n'; (exit 3)", 3000);
  spawnOK = r.code === 3 && r.out === 'nfq_a\n\nnfq_b';
}
const ctlCmd = a => (LANG === 'en' ? 'NFQWS_LANG=en ' : '') + 'sh ' + q(CTL) + ' ' + a.map(q).join(' ');
async function ctl(a, ms){
  const r = await sh(ctlCmd(a), ms);
  if(r.code && r.err && !r.out) toast(r.err.slice(0, 160));
  return r.out + (r.code && r.err ? '\n' + r.err : '');
}
async function ctlx(a, ms, onLine){ return await sh(ctlCmd(a), ms, onLine); }
const errText = (r, fallback) => ((r.err || '').trim() || (r.out || '').trim().split('\n').pop() || t(fallback));

/* Snackbar */
let snackAction = null;
function toast(m, action){
  $('prompt-msg').textContent = m;
  const b = $('prompt-action');
  snackAction = action || null;
  b.hidden = !action;
  if(action) b.textContent = action.label || t('Повторить');
  const pc = $('prompt-container');
  pc.classList.add('show');
  clearTimeout(pc._t);
  pc._t = setTimeout(() => pc.classList.remove('show'), action ? 8000 : 4000);
}
$('prompt-action').onclick = () => {
  $('prompt-container').classList.remove('show');
  const a = snackAction; snackAction = null;
  if(a && a.fn) a.fn();
};

/* Busy indicator under the app bar */
let busyCount = 0;
function busy(on){
  busyCount = Math.max(0, busyCount + (on ? 1 : -1));
  const idle = busyCount === 0;
  $('progress-top').hidden = idle;
  $('content').setAttribute('aria-busy', idle ? 'false' : 'true');
}
async function withBusy(a, ms){
  busy(true);
  try { return await ctlx(a, ms); } finally { busy(false); }
}

/* Repaint only when the content really differs */
function setHTML(el, html, animate){
  if(typeof el === 'string') el = $(el);
  if(!el || el._html === html) return false;
  el._html = html;
  el.innerHTML = html;
  if(animate !== false){ el.classList.remove('appear'); void el.offsetWidth; el.classList.add('appear'); }
  return true;
}

/* Dialog replacing native confirm/prompt: focus stays inside and returns to the opener */
let dialogCb = null, dialogReturnFocus = null;
function dialogResolve(val){
  if(!$('dialog-wrap').classList.contains('open')) return;
  const cb = dialogCb; dialogCb = null;
  $('dialog-wrap').classList.remove('open');
  const back = dialogReturnFocus; dialogReturnFocus = null;
  if(back && document.contains(back)) try { back.focus({preventScroll: true}); } catch(e) {}
  scheduleSync();
  if(cb) cb(val);
}
function mdDialog(opts){
  if(dialogCb) dialogResolve(false);
  return new Promise(res => {
    dialogCb = res;
    dialogReturnFocus = document.activeElement;
    const dlg = $('dialog');
    $('d-title').textContent = opts.title || '';
    $('d-body').textContent = opts.text || '';
    $('d-body').hidden = !opts.text;
    const showIcon = opts.icon !== false;
    const ic = $('d-icon');
    ic.hidden = !showIcon;
    ic.className = 'd-icon' + (opts.danger ? ' danger' : '');
    ic.innerHTML = icon(opts.iconName || (opts.danger ? 'error' : 'warn'), 's24');
    dlg.classList.toggle('has-icon', showIcon);
    const ok = $('d-ok');
    ok.className = 'btn text state' + (opts.danger ? ' danger' : '');
    ok.textContent = opts.ok || t('ОК');
    const cancel = $('d-cancel');
    cancel.hidden = opts.cancel === false;
    cancel.textContent = typeof opts.cancel === 'string' ? opts.cancel : t('Отмена');
    const f = $('d-field');
    f.hidden = !opts.input;
    if(opts.input){
      const di = $('d-input');
      di.type = opts.input.type || 'text';
      di.inputMode = opts.input.inputmode || '';
      di.value = opts.input.value || '';
      $('d-label').textContent = opts.input.label || t('Значение');
    }
    /* alertdialog for interrupting confirmations only; an input is a plain dialog */
    dlg.setAttribute('role', opts.input ? 'dialog' : 'alertdialog');
    $('dialog-wrap').classList.add('open');
    scheduleSync();
    setTimeout(() => { (opts.input ? $('d-input') : dlg).focus(); }, 80);
  });
}
const mdConfirm = (title, text, o) => mdDialog(Object.assign({title, text}, o || {})).then(v => !!v);
async function mdPrompt(title, text, value, label, extra){
  extra = extra || {};
  return mdDialog({title, text, ok: extra.ok || t('Сохранить'), icon: false,
    input: {value, label, type: extra.type, inputmode: extra.inputmode}})
    .then(v => (v === false ? null : v));
}
$('d-ok').onclick = () => dialogResolve($('d-field').hidden ? true : $('d-input').value.trim());
$('d-input').onkeydown = e => { if(e.key === 'Enter') dialogResolve($('d-input').value.trim()); };
$('dialog-wrap').addEventListener('keydown', e => {
  if(e.key !== 'Tab') return;
  const els = [...$('dialog').querySelectorAll('button, input')].filter(el => el.offsetParent !== null && !el.disabled);
  if(!els.length) return;
  const first = els[0], last = els[els.length - 1], a = document.activeElement;
  if(e.shiftKey && (a === first || a === $('dialog'))){ e.preventDefault(); last.focus(); }
  else if(!e.shiftKey && a === last){ e.preventDefault(); first.focus(); }
});

/* Top-level sections live in the navigation bar; settings and below are child screens */
const PAGE_META = {
  control:  {title: 'Состояние', init: () => { renderStatus(); stat(); initStrategySelector(); }},
  lists:    {title: 'Списки', init: () => { renderMode(); renderListFiles(); stat(); }},
  logs:     {title: 'Журналы', init: () => loadLog(),
             actions: [{icon: 'refresh', label: 'Обновить журнал', fn: () => loadLog()}]},
  config:   {title: 'Конфиг', init: () => confInit()},
  settings: {title: 'Настройки', child: true, init: () => renderSettings()},
  smart:    {title: 'Умный режим', child: true, parent: 'settings', init: () => smartInit()},
  wifi:     {title: 'Домашняя Wi‑Fi', child: true, parent: 'settings', init: () => wifiInit()},
  apps:     {title: 'Фильтр приложений', child: true, parent: 'settings', init: () => appsInit(),
             actions: [{icon: 'refresh', label: 'Обновить список приложений', fn: () => loadPk(true)}]},
  test:     {title: 'Проверка доступности', child: true, parent: 'settings', init: () => testInit()},
  diag:     {title: 'Диагностика', child: true, parent: 'settings', init: () => diagInit(),
             actions: [{icon: 'refresh', label: 'Проверить снова', fn: () => diagInit()}]}
};
let currentPage = 'control', lastTop = 'control', transitionCleanup = null;
const pageDepth = p => { const m = PAGE_META[p]; return !m.child ? 0 : (m.parent ? pageDepth(m.parent) + 1 : 1); };

function renderAppBar(page, animate){
  const m = PAGE_META[page];
  $('back-btn').hidden = !m.child;
  $('settings-btn').hidden = !!m.child;
  const tEl = $('app-title');
  tEl.textContent = t(m.title);
  if(animate !== false && !isAnimationsDisabled()){ tEl.classList.remove('swap'); void tEl.offsetWidth; tEl.classList.add('swap'); }
  const box = $('bar-actions');
  box.innerHTML = '';
  (m.actions || []).forEach(a => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'icon-btn state';
    b.title = t(a.label);
    b.setAttribute('aria-label', t(a.label));
    b.innerHTML = icon(a.icon, 's24');
    b.onclick = a.fn;
    box.append(b);
  });
}
function renderNavBar(page){
  document.querySelectorAll('.nav-dest').forEach(b => {
    if(b.dataset.page === page) b.setAttribute('aria-current', 'page');
    else b.removeAttribute('aria-current');
  });
  document.body.classList.toggle('nav-hidden', !!PAGE_META[page].child);
}
/* End the screen animation on animationend: a timer can fire before the first frame while the thread is busy */
function showPage(page, mode){
  if(transitionCleanup) transitionCleanup();
  const from = document.querySelector('.page.active');
  const to = document.querySelector('.page[data-page="' + page + '"]');
  if(!to || from === to) return;
  const animate = !matchMedia('(prefers-reduced-motion: reduce)').matches && !isAnimationsDisabled();
  if(from){
    if(animate){
      const r = from.getBoundingClientRect();
      from.style.cssText = 'position:fixed;top:' + r.top + 'px;left:' + r.left + 'px;width:' + r.width + 'px';
      from.classList.add('leaving', 'leave-' + mode);
    }
    from.classList.remove('active');
  }
  to.classList.add('active');
  if(animate) to.classList.add('enter-' + mode);
  scrollTo(0, 0);
  $('app-bar').classList.remove('scrolled');
  let timer = 0;
  const onEnd = e => { if(e.target === to && e.animationName === 'fade-in') cleanup(); };
  const cleanup = () => {
    clearTimeout(timer);
    to.removeEventListener('animationend', onEnd);
    if(from){ from.classList.remove('leaving', 'leave-' + mode); from.style.cssText = ''; }
    to.classList.remove('enter-' + mode);
    if(transitionCleanup === cleanup) transitionCleanup = null;
  };
  transitionCleanup = cleanup;
  if(animate){ to.addEventListener('animationend', onEnd); timer = setTimeout(cleanup, 1200); }
  else cleanup();
}
/* Load data after the animation starts, so a blocking exec does not freeze the first frame */
function afterTransition(fn){
  if(typeof isAnimationsDisabled === 'function' && isAnimationsDisabled()){ fn(); return; }
  requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(fn, spawnOK ? 0 : 320)));
}
function navigate(page){
  if(page === currentPage){
    if(!PAGE_META[page].child) scrollTo({top: 0, behavior: (typeof isAnimationsDisabled === 'function' && isAnimationsDisabled()) ? 'auto' : 'smooth'});
    return;
  }
  closeMenu();
  const d0 = pageDepth(currentPage), d1 = pageDepth(page);
  const mode = d1 > d0 ? 'forward' : (d1 < d0 ? 'back' : 'fade');
  currentPage = page;
  if(!PAGE_META[page].child) lastTop = page;
  renderNavBar(page);
  renderAppBar(page);
  showPage(page, mode);
  const target = page;
  afterTransition(() => { if(currentPage === target) PAGE_META[target].init(); });
  scheduleSync();
}
function goBack(){ navigate(PAGE_META[currentPage].parent || lastTop); }
document.querySelectorAll('.nav-dest').forEach(b => { b.onclick = () => navigate(b.dataset.page); });

/* Long press on the settings button toggles developer mode; the click after it is swallowed */
let devMode = store.get('nfq_dev') === '1';
(function bindSettingsPress(){
  const b = $('settings-btn');
  let tm = 0, fired = false;
  const cancel = () => { clearTimeout(tm); tm = 0; };
  b.addEventListener('pointerdown', () => {
    cancel(); fired = false;
    tm = setTimeout(() => {
      tm = 0; fired = true;
      devMode = !devMode;
      store.set('nfq_dev', devMode ? '1' : '0');
      renderParams(S);
      if(currentPage === 'settings') renderSettings();
      toast(devMode ? t('Режим разработчика включён') : t('Режим разработчика выключен'));
    }, 650);
  });
  ['pointerup', 'pointerleave', 'pointercancel'].forEach(ev => b.addEventListener(ev, cancel));
  b.addEventListener('contextmenu', e => e.preventDefault());
  b.addEventListener('click', () => { if(fired){ fired = false; return; } navigate('settings'); });
})();

/* Elevation on scroll */
addEventListener('scroll', () => $('app-bar').classList.toggle('scrolled', scrollY > 8), {passive: true});

/* Modal bottom sheets share one scrim */
let openSheetId = null, sheetReturnFocus = null;
/* Hide the background from tab order and AT (inert is Chromium 102+) */
function setBackgroundInert(on){
  if(!('inert' in HTMLElement.prototype)) return;
  ['#content', '.app-bar', '.nav-bar'].forEach(sel => {
    const el = document.querySelector(sel);
    if(el) el.inert = on;
  });
}
function openSheet(id){
  if(openSheetId && openSheetId !== id) closeSheet();
  openSheetId = id;
  const el = $(id);
  sheetReturnFocus = document.activeElement;
  el.tabIndex = -1;
  el.classList.add('open');
  $('sheet-scrim').classList.add('show');
  setBackgroundInert(true);
  setTimeout(() => el.focus({ preventScroll: true }), 60);
  scheduleSync();
}
function closeSheet(){
  if(!openSheetId) return;
  const el = $(openSheetId);
  el.classList.remove('open');
  el.style.transform = '';
  $('sheet-scrim').classList.remove('show');
  setBackgroundInert(false);
  if(sheetReturnFocus && sheetReturnFocus.focus) sheetReturnFocus.focus({ preventScroll: true });
  sheetReturnFocus = null;
  openSheetId = null;
  scheduleSync();
}
function openMonetModal(){ drawThemeUI(); openSheet('monet-modal'); }

/* Back: overlays, then child screen, then home, then exit */
function handleBack(allowExit){
  if(openMenuEntry){ closeMenu(); return true; }
  if($('dialog-wrap').classList.contains('open')){ dialogResolve(false); return true; }
  if($('editor-panel').classList.contains('open')){ closeSlideEditor(); return true; }
  if(openSheetId){ closeSheet(); return true; }
  if(PAGE_META[currentPage].child){ goBack(); return true; }
  if(allowExit && currentPage !== 'control'){ navigate('control'); return true; }
  return false;
}
/* config.json: backInterceptor = javascript - the manager calls this handler itself */
window.onBackKeyPressed = function(){
  if(handleBack(true)) return;
  try { window.ksu && window.ksu.exit && window.ksu.exit(); } catch(e) {}
};
document.addEventListener('keydown', e => { if(e.key === 'Escape') handleBack(false); });

/* The manager's back gesture is webView.goBack(), closing the WebUI when history is empty.
      Chromium skips entries pushed without user activation, so keep one entry per open layer plus
      a spare, pushed only while the page has fresh activation: no layers means no entries. */
let histDepth = (history.state && history.state.nfq) || 0, histPending = false, syncTimer = 0;
function uiLayers(){
  let n = pageDepth(currentPage) + (PAGE_META[currentPage].child ? (lastTop !== 'control' ? 1 : 0) : (currentPage !== 'control' ? 1 : 0));
  if(openSheetId) n++;
  if(editorCtx) n++;
  if($('dialog-wrap').classList.contains('open')) n++;
  if(openMenuEntry) n++;
  return n;
}
const canPush = () => !navigator.userActivation || navigator.userActivation.isActive;
function syncHistory(){
  syncTimer = 0;
  updateScrollLock();
  if(histPending) return;
  const layers = uiLayers(), target = layers ? layers + 1 : 0;
  try {
    if(target > histDepth){
      if(!canPush()) return;
      while(histDepth < target) history.pushState({nfq: ++histDepth}, '');
    } else if(target < histDepth){
      histPending = true;
      history.go(target - histDepth);
    }
  } catch(e) { histPending = false; }
}
/* Defer a tick: closing a menu and opening a screen must settle in one state */
function scheduleSync(){ if(!syncTimer) syncTimer = setTimeout(syncHistory, 0); }
addEventListener('popstate', e => {
  const d = (e.state && e.state.nfq) || 0;
  if(histPending){ histPending = false; histDepth = d; scheduleSync(); return; }
  const was = histDepth;
  histDepth = d;
  if(d < was) handleBack(true);
  scheduleSync();
});
/* Touch and key give user activation: the moment to add entries */
['pointerdown', 'keydown'].forEach(ev => addEventListener(ev, () => setTimeout(syncHistory, 0), true));

/* Lock background scrolling while an overlay is open */
function updateScrollLock(){
  const lock = !!(openSheetId || editorCtx || openMenuEntry || $('dialog-wrap').classList.contains('open'));
  document.documentElement.classList.toggle('scroll-locked', lock);
}

/* adjustResize pushes the fixed nav bar above the keyboard, so hide it while typing */
const isTextInput = el => !!el && (el.tagName === 'TEXTAREA' ||
  (el.tagName === 'INPUT' && !/^(checkbox|radio|range|button|submit|file|color)$/i.test(el.type)));
const vpHeight = () => (window.visualViewport ? visualViewport.height : innerHeight);
let vpBase = vpHeight(), kbPendingUntil = 0;
function updateKeyboard(){
  const h = vpHeight(), focused = isTextInput(document.activeElement);
  if(!focused) vpBase = Math.max(vpBase, h);
  const open = focused && (vpBase - h > 120 || Date.now() < kbPendingUntil);
  document.body.classList.toggle('kb-open', open);
}
document.addEventListener('focusin', e => {
  if(!isTextInput(e.target)) return;
  kbPendingUntil = Date.now() + 700;
  updateKeyboard();
  setTimeout(updateKeyboard, 750);
});
document.addEventListener('focusout', () => setTimeout(updateKeyboard, 60));
(window.visualViewport || window).addEventListener('resize', updateKeyboard);
addEventListener('orientationchange', () => { vpBase = 0; setTimeout(updateKeyboard, 300); });

/* Sheet drag handle: swipe down or tap closes */
function initSheetDrag(sheet){
  const zone = sheet.querySelector('.sheet-drag');
  let y0 = null, dy = 0, dragged = false;
  zone.addEventListener('pointerdown', e => {
    y0 = e.clientY; dy = 0; dragged = false;
    sheet.style.transition = 'none';
    zone.setPointerCapture(e.pointerId);
  });
  zone.addEventListener('pointermove', e => {
    if(y0 == null) return;
    dy = Math.max(0, e.clientY - y0);
    if(dy > 4) dragged = true;
    sheet.style.transform = 'translateY(' + dy + 'px)';
  });
  const end = () => {
    if(y0 == null) return;
    y0 = null;
    sheet.style.transition = '';
    if(dy > Math.min(120, sheet.offsetHeight * .25)) requestAnimationFrame(() => closeSheet());
    else sheet.style.transform = '';
  };
  zone.addEventListener('pointerup', end);
  zone.addEventListener('pointercancel', end);
  zone.addEventListener('click', () => { if(dragged){ dragged = false; return; } closeSheet(); });
}
document.querySelectorAll('.sheet').forEach(initSheetDrag);
