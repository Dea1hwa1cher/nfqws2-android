/* nfqws2 WebUI · editor.js — редактор и подсветка синтаксиса
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ Подсветка синтаксиса ════════════════════════════════════════════════
   Порт токенайзеров nfqws-keenetic-web (CodeMirror StreamLanguage для
   nfqws.conf, *.list и журналов) без самого CodeMirror: тот же разбор,
   результатом — span-ы с классами tk-*. */
class SStream {
  constructor(s){ this.string = s; this.pos = 0; this.start = 0; }
  eol(){ return this.pos >= this.string.length; }
  sol(){ return this.pos === 0; }
  peek(){ return this.pos < this.string.length ? this.string.charAt(this.pos) : undefined; }
  next(){ if(this.pos < this.string.length) return this.string.charAt(this.pos++); }
  eat(m){
    const ch = this.string.charAt(this.pos);
    if(!ch) return undefined;
    const ok = typeof m === 'string' ? ch === m : m.test(ch);
    if(ok){ this.pos++; return ch; }
  }
  eatWhile(m){ const s = this.pos; while(this.eat(m) !== undefined); return this.pos > s; }
  eatSpace(){ const s = this.pos; while(this.pos < this.string.length && /[\s ]/.test(this.string.charAt(this.pos))) this.pos++; return this.pos > s; }
  skipToEnd(){ this.pos = this.string.length; }
  match(re){ const m = this.string.slice(this.pos).match(re); if(m && m.index === 0){ this.pos += m[0].length; return m; } return null; }
  current(){ return this.string.slice(this.start, this.pos); }
}
const HL = (() => {
  const wordRe = w => new RegExp('^(?:' + w.join('|') + ')$', 'i');
  /* ── nfqws2.conf ── */
  const ops = wordRe(['iptables', 'ip', 'tc', 'route', 'sysctl', 'echo']);
  const builtin = wordRe(['ROOT', 'BIN', 'SBIN', 'ETC', 'VAR', 'LOG', 'TMP', 'PID', 'LOCK', 'RUN', 'SYS', 'PROC', 'DEV', 'OPT']);
  const isOperatorChar = /[+\-*&%=<>!?|]/;
  const chain = (st, s, f) => { s.tokenize = f; return f(st, s); };
  const resetDq = s => { s.dqAtCmdStart = true; s.dqLastFlag = ''; s.dqInFlagValue = false; s.dqInParamValue = false; s.dqAfterColon = false; };
  function tokenString(quote){
    return function(st, s){
      let escaped = false, next, end = false;
      while((next = st.next()) !== undefined){
        if(next === quote && !escaped){ end = true; break; }
        escaped = !escaped && next === '\\';
      }
      if(end || !escaped) s.tokenize = tokenBase;
      return 'string';
    };
  }
  function tokenDQuote(st, s){
    if(st.eat('"')){ s.tokenize = tokenBase; return 'string'; }
    if(st.eat('\\')){ st.next(); return 'string'; }
    if(st.eatSpace()){ resetDq(s); return 'string'; }
    if(st.eat('$')){
      if(st.eat('{')){ st.eatWhile(/[\w_]/); st.eat('}'); return 'variable-2'; }
      st.eatWhile(/[\w_]/); return 'variable-2';
    }
    if(st.peek() === '-' && st.string.charAt(st.pos + 1) === '-'){
      st.next(); st.next(); st.eatWhile(/[\w-]/);
      s.dqLastFlag = st.current().slice(2); s.dqAtCmdStart = false;
      s.dqInFlagValue = false; s.dqInParamValue = false; s.dqAfterColon = false;
      return 'keyword';
    }
    const p = st.peek();
    if(p === ':'){ st.next(); s.dqAfterColon = true; s.dqInParamValue = false; return 'operator'; }
    if(p === ','){ st.next(); return 'operator'; }
    if(p === '='){
      st.next();
      if(s.dqLastFlag && !s.dqInFlagValue){ s.dqInFlagValue = true; s.dqInParamValue = false; s.dqAfterColon = false; }
      else if(s.dqInFlagValue){ s.dqInParamValue = true; s.dqAfterColon = false; }
      return 'operator';
    }
    if(st.eat('@')){
      if(st.peek() === '/' || st.peek() === '$'){ st.eatWhile(/[\w\-./$]/); return 'string-2'; }
      st.eatWhile(/[^$"\\\s]/); return 'string';
    }
    if(st.peek() === '/'){ st.next(); st.eatWhile(/[\w\-./]/); return 'string-2'; }
    if(st.peek() === '-' && /\d/.test(st.string.charAt(st.pos + 1))){ st.next(); st.eatWhile(/[0-9,._\-+]/); return 'number'; }
    if(st.peek() && /\d/.test(st.peek())){ st.next(); st.eatWhile(/[A-Za-z0-9,._\-+]/); return 'number'; }
    if(st.peek() && /[A-Za-z_]/.test(st.peek())){
      st.eatWhile(/[\w.-]/);
      if(s.dqAfterColon && st.peek() === '='){ s.dqAfterColon = false; return 'typeName'; }
      if(s.dqAfterColon){ s.dqAfterColon = false; return 'typeName'; }
      if(s.dqInParamValue) return 'string';
      return 'typeName';
    }
    if(st.peek() === '-' && (s.dqInFlagValue || s.dqInParamValue)){ st.next(); st.eatWhile(/[A-Za-z0-9._\-+]/); return 'typeName'; }
    if(st.peek() === '-'){ st.next(); st.eatWhile(/[A-Za-z0-9]/); return 'keyword'; }
    const start = st.pos;
    st.eatWhile(/[^$"\\\s]/);
    if(st.pos === start) st.next();
    return 'string';
  }
  function tokenVariable(st, s){ st.eatWhile(/[\w_]/); if(st.eat('}')) s.tokenize = tokenBase; return 'variable-2'; }
  function tokenComment(st, s){
    let maybeEnd = false, ch;
    while((ch = st.next()) !== undefined){ if(ch === '/' && maybeEnd){ s.tokenize = tokenBase; break; } maybeEnd = ch === '*'; }
    return 'comment';
  }
  function tokenBase(st, s){
    const ch = st.next();
    if(ch === undefined) return null;
    if(ch === '#'){ st.skipToEnd(); return 'comment'; }
    if(ch === '\\' && st.eol()) return 'operator';
    if(ch === "'") return chain(st, s, tokenString(ch));
    if(ch === '"'){ resetDq(s); s.tokenize = tokenDQuote; return 'string'; }
    if(ch === '=') return 'operator';
    if(ch === '$' && st.eat('{')) return chain(st, s, tokenVariable);
    if(ch === '$'){ st.eatWhile(/[\w_]/); return 'variable-2'; }
    if(/\d/.test(ch)){
      st.eatWhile(/[A-Za-z0-9,:._-]/);
      const num = st.current();
      if(/^0x[0-9a-fA-F]+$/.test(num) || /^\d+(?:[,:-]\d+)*$/.test(num)) return 'number';
      return 'variable';
    }
    if(ch === '.' && st.eat('.')) return 'operator';
    if(ch === '/' && st.eat('*')) return chain(st, s, tokenComment);
    if(ch === '/' && st.peek() && /[\w\-./]/.test(st.peek())){ st.eatWhile(/[\w\-./]/); return 'string-2'; }
    if(ch === '@' && st.peek() === '/'){ st.eatWhile(/[\w\-./]/); return 'string-2'; }
    if(ch === '-' && st.peek() === '-'){ st.eatWhile(/[\w\-:]/); return 'keyword'; }
    if(isOperatorChar.test(ch)){ st.eatWhile(isOperatorChar); return 'operator'; }
    if(/[A-Za-z_]/.test(ch)){
      st.eatWhile(/[\w_]/);
      if(st.peek() === '=' || st.peek() === ':') return 'def';
    }
    st.eatWhile(/[\w$_]/);
    const cur = st.current();
    if(ops.test(cur)) return 'builtin';
    if(builtin.test(cur)) return 'variable-2';
    return 'variable';
  }
  const conf = {start: () => { const s = {tokenize: tokenBase}; resetDq(s); return s; }, token: (st, s) => s.tokenize(st, s)};

  /* ── *.list: только комментарии ── */
  const list = {start: () => ({}), token: st => {
    if(st.sol()){ st.eatSpace(); if(st.peek() === '#'){ st.skipToEnd(); return 'comment'; } }
    st.skipToEnd(); return null;
  }};

  /* ── журналы ── */
  const logLevels = wordRe(['ERROR', 'WARN', 'WARNING', 'INFO', 'DEBUG', 'TRACE', 'FATAL', 'CRITICAL', 'SEVERE', 'NOTICE']);
  const logKeywords = wordRe(['started', 'stopped', 'restarted', 'failed', 'success', 'connection', 'packet', 'rule', 'match',
    'drop', 'accept', 'forward', 'queue', 'process', 'thread', 'memory', 'cpu', 'timeout', 'retry', 'attempt', 'session',
    'client', 'server', 'profile', 'proto', 'udp_in', 'udp_out', 'fail', 'counter', 'retrans', 'threshold', 'reached',
    'src', 'dst', 'sport', 'dport', 'ttl', 'flags', 'seq', 'ack', 'ack_seq', 'len', 'id', 'mark', 'ifin', 'ifout',
    'hostname', 'ssid', 'icmp', 'l7proto', 'track_direction', 'fixed_direction', 'connection_proto', 'payload_type']);
  const logProtocols = wordRe(['tls', 'quic', 'http', 'https', 'tcp', 'udp', 'ip4', 'ip6']);
  const logWarnWords = wordRe(['retrans', 'threshold', 'reached', 'timeout', 'retry', 'watchdog', 'netwatch']);
  const logErrorWords = wordRe(['failed', 'error', 'fatal', 'critical', 'ошибка', 'ошибки', 'упал', 'отсутствуют']);
  const looksLikeDomain = s => /[A-Za-z]/.test(s) && s.includes('.') && !s.includes('..');
  const log = {start: () => ({}), token: st => {
    if(st.peek() === ':' || st.peek() === '='){ st.next(); return 'operator'; }
    if(st.sol()){
      if(st.match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/)) return 'atom';
      if(st.match(/^\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}:\d{2}/)) return 'atom';
      if(st.match(/^\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?/)) return 'atom';
      if(st.match(/^\d{2}:\d{2}:\d{2}/)) return 'atom';
    }
    if(st.peek() === '['){ st.next(); st.eatWhile(/[^\]]/); if(st.peek() === ']') st.next(); return 'bracket'; }
    if(st.peek() === '('){ st.next(); st.eatWhile(/[^)]/); if(st.peek() === ')') st.next(); return 'comment'; }
    if(st.match(/^(<==|==>|<=>|<=|>=|=>|=<)/)) return 'operator';
    if(st.match(/^\d+\.\d+\.\d+\.\d+(?::\d+)?/)) return 'number';
    if(st.match(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)) return 'string-2';
    if(st.match(/^[0-9a-f]{12,}(?![A-Za-z0-9_.-])/i)) return 'string-2';
    if(st.match(/^\d+\/\d+/)) return 'number';
    if(st.match(/^\d+(?![A-Za-z0-9_.-])/)) return 'number';
    if(st.match(/^0x[0-9a-f]+/i)) return 'number';
    const ch = st.next();
    if(ch === undefined) return null;
    st.eatWhile(/[\w\-./Ѐ-ӿ]/);
    const cur = st.current();
    if(st.peek() === '=') return 'def';
    if(logLevels.test(cur)){
      if(/^(ERROR|FATAL|CRITICAL)$/i.test(cur)) return 'error';
      if(/^WARN/i.test(cur)) return 'warning';
      if(/^(DEBUG|TRACE)$/i.test(cur)) return 'comment';
      return 'tag';
    }
    if(logProtocols.test(cur)) return 'typeName';
    if(logErrorWords.test(cur)) return 'error';
    if(logWarnWords.test(cur)) return 'warning';
    if(logKeywords.test(cur)) return 'def';
    if(looksLikeDomain(cur)) return 'string-2';
    return null;
  }};
  return {conf, list, log};
})();
function highlight(text, lang){
  const mode = HL[lang];
  if(!mode) return esc(text);
  const state = mode.start();
  let out = '';
  for(const line of text.split('\n')){
    const st = new SStream(line);
    let guard = 0;
    while(!st.eol() && guard++ < 4000){
      st.start = st.pos;
      if(st.eatSpace()){ out += esc(st.current()); continue; }
      const style = mode.token(st, state);
      if(st.pos === st.start) st.next();
      const txt = esc(st.current());
      out += style ? '<span class="tk-' + style + '">' + txt + '</span>' : txt;
    }
    if(!st.eol()) out += esc(line.slice(st.pos));
    out += '\n';
  }
  return out;
}

/* ══ Full-screen dialog: редактор ════════════════════════════════════════
   Ошибка сохранения не закрывает редактор: правки остаются на месте.
   Закрытие с несохранёнными правками спрашивает подтверждение.
   Подсветка — слой <pre> под прозрачным текстом textarea; для больших
   файлов (ipset.list и т. п.) она выключается, чтобы не тормозил ввод. */
const HL_LIMIT = 150000;
let editorCtx = null, editorReturnFocus = null, hlFrame = 0;
function highlightEditor(){
  hlFrame = 0;
  const ta = $('panel-editor-text'), pre = $('ce-hl'), box = $('code-edit');
  const lang = editorCtx && editorCtx.lang;
  const on = !!lang && !ta.readOnly && ta.value.length <= HL_LIMIT;
  box.classList.toggle('plain', !on);
  if(!on){ pre.textContent = ''; return; }
  pre.innerHTML = highlight(ta.value, lang) + ' ';
  pre.scrollTop = ta.scrollTop; pre.scrollLeft = ta.scrollLeft;
}
$('panel-editor-text').addEventListener('input', () => { if(!hlFrame) hlFrame = requestAnimationFrame(highlightEditor); });
$('panel-editor-text').addEventListener('scroll', () => {
  const ta = $('panel-editor-text'), pre = $('ce-hl');
  pre.scrollTop = ta.scrollTop; pre.scrollLeft = ta.scrollLeft;
}, {passive: true});

function openSlideEditor(type, key){
  if(type === 'conf') openEditorWith({target: 'conf', title: 'nfqws2.conf', lang: 'conf',
    hint: t('Конфиг проверяется на устройстве: при ошибке сохранение отклоняется. Изменения вступят в силу после перезапуска службы.'),
    load: ['get-conf']});
  else if(type === 'list') openEditorWith({target: 'list', key, title: key + '.list', lang: 'list',
    hint: t('По одной записи на строку. Строки с # игнорируются.'), load: ['get-list', key]});
  else if(type === 'apps') openEditorWith({target: 'list', key: 'apps', title: 'apps.list', lang: 'list',
    hint: t('Имена пакетов по одному на строку, например com.example.app.'), load: ['get-list', 'apps']});
}
async function openEditorWith(o){
  editorCtx = o;
  const ta = $('panel-editor-text');
  $('panel-title-text').textContent = o.title;
  $('panel-hint').textContent = o.hint;
  $('panel-hint').className = 'helper';
  $('panel-save-btn').disabled = !!o.load;
  $('panel-save-btn').textContent = o.saveLabel || t('Сохранить');
  $('panel-pending').hidden = !(o.target === 'list' && pendingLists().includes(o.key));
  ta.placeholder = o.target === 'list' ? '' : t('# Конфигурация…');
  ta.value = o.load ? t('Загрузка…') : o.text;
  ta.readOnly = !!o.load;
  ta.scrollTop = 0; ta.scrollLeft = 0;
  highlightEditor();
  editorReturnFocus = document.activeElement;
  $('code-edit').style.display = '';
  $('editor-panel').classList.add('open');
  setBackgroundInert(true);
  scheduleSync();
  if(o.load){
    const r = await ctlx(o.load, 30000);
    if(editorCtx !== o) return;
    if(r.code){
      teardownEditor(true);
      editorCtx = null;
      scheduleSync();
      toast(errText(r, 'Не удалось открыть файл'));
      return;
    }
    ta.value = o.b64 ? unb64(r.out.replace(/\s+/g, '')) : r.out;
    ta.readOnly = false;
    $('panel-save-btn').disabled = false;
    highlightEditor();
  }
  o.original = o.dirty ? null : ta.value;
  // Большой файл (ipset.list и т. п.) не фокусируем: клавиатура тянет весь текст
  // в контекст ввода, и Android ловит TransactionTooLargeException.
  if(ta.value.length < LARGE_FILE) ta.focus({ preventScroll: true });
}
/* Закрытие редактора с огромным файлом: если оставить текст в DOM на время
   анимации, Chromium пытается растрировать слой высотой в сотни тысяч пикселей
   и роняет процесс WebView (RenderProcessGone) вместе с менеджером. Поэтому
   текст убирается до закрытия, а для больших файлов анимация отключается. */
const LARGE_FILE = 50000;
function teardownEditor(large){
  const panel = $('editor-panel'), box = $('code-edit'), ta = $('panel-editor-text'), pre = $('ce-hl');
  if(document.activeElement === ta) ta.blur();
  if(large) panel.style.transition = 'none';
  box.style.display = 'none';
  ta.value = '';
  pre.textContent = '';
  panel.classList.remove('open');
  if(!openSheetId) setBackgroundInert(false);
  if(large){ void panel.offsetHeight; panel.style.transition = ''; box.style.display = ''; }
  else setTimeout(() => { if(!editorCtx) box.style.display = ''; }, 480);
}
async function closeSlideEditor(force){
  const o = editorCtx;
  if(!force && o && o.original !== $('panel-editor-text').value){
    const discard = await mdConfirm(t('Закрыть без сохранения?'), t('Изменения в «{0}» будут потеряны.', o.title),
      {ok: t('Закрыть'), cancel: t('Продолжить правку')});
    if(!discard) return;
  }
  teardownEditor(!o || (o.original || $('panel-editor-text').value || '').length > LARGE_FILE);
  if(editorReturnFocus && editorReturnFocus.focus) try { editorReturnFocus.focus({ preventScroll: true }); } catch(e) {}
  editorReturnFocus = null;
  editorCtx = null;
  scheduleSync();
}
$('panel-save-btn').onclick = async () => {
  const o = editorCtx;
  if(!o) return;
  const val = $('panel-editor-text').value;
  if(o.target === 'import-new'){
    if(!val.trim()){ toast(t('Вставьте текст конфига')); return; }
    const name = await mdPrompt(t('Имя конфига'), t('Можно по-русски. Слэши, кавычки и $ будут убраны.'), 'import', t('Имя'));
    if(!name) return;
    const ri = await withBusy(['import-add-b64', b64(name), b64(val)]);
    if(ri.code){
      $('panel-hint').textContent = errText(ri, 'Конфиг отклонён');
      $('panel-hint').className = 'helper err';
      toast(t('Конфиг отклонён'));
      return;
    }
    closeSlideEditor(true);
    showImportMsg(importRemoved(ri));
    toast(t('Импортировано'));
    loadImports();
    return;
  }
  let r;
  if(o.target === 'conf') r = await withBusy(['save-conf-b64', b64(val)]);
  else if(o.target === 'strategy') r = await withBusy(['strategy-save-b64', o.key, b64(val)]);
  else r = await withBusy(['save-list-b64', o.key, b64(val)], 30000);
  if(r.code){
    $('panel-hint').textContent = errText(r, 'Сохранение отклонено');
    $('panel-hint').className = 'helper err';
    toast(errText(r, 'Сохранение отклонено'));
    return;
  }
  closeSlideEditor(true);
  if(o.target === 'conf'){
    toast(t('Конфиг сохранён'), S.running ? {label: t('Перезапустить'), fn: restartSvc} : null);
    if(currentPage === 'config') checkConfModified();
  } else if(o.target === 'strategy'){
    await loadStrategies();
    renderStrategyRow();
    if(openSheetId === 'strategy-sheet'){ const l = $('strategy-list'), top = l.scrollTop; renderStrategyList(false); l.scrollTop = top; }
    toast(t('Стратегия «{0}» сохранена', strategyName(o.key)),
      o.key === currentStrategy ? {label: t('Применить'), fn: () => applyStrategy(o.key)} : null);
  } else toast(t('{0} сохранён', o.title));
  stat();
  // Список правили вручную мимо togglePkg() — кэш выбранных приложений устарел.
  if(o.key === 'apps') appsCache = null;
  if(o.key === 'apps' && currentPage === 'apps') appsInit();
};
