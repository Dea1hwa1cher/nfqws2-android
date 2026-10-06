/* nfqws2 WebUI · apps.js — фильтр приложений
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ПРИЛОЖЕНИЯ ══════════════════════════════════════════════════════════ */
const APP_MODES = [
  ['off', 'Выключен', 'Обрабатывается трафик всех приложений'],
  ['include', 'Только выбранные', 'Трафик раздачи (hotspot) не обрабатывается'],
  ['exclude', 'Все, кроме выбранных', 'Выбранные приложения идут напрямую']
];
async function appsInit(){
  renderAppModes();
  if(pkgs.length) drawPk(); else loadPk();
  await stat(true);
  renderAppModes();
}
function renderAppModes(){
  const cur = S.app_mode || 'off';
  setHTML('amode-list', APP_MODES.map(([v, label, hint]) =>
    '<label class="list-item two-line clickable state' + (v === cur ? ' selected' : '') + '">' +
      '<input type="radio" class="radio" name="amode" value="' + v + '"' + (v === cur ? ' checked' : '') +
        ' onchange="setAppMode(this.value)">' +
      '<span class="li-text"><span class="li-primary">' + esc(t(label)) + '</span><span class="li-secondary">' + esc(t(hint)) + '</span></span>' +
    '</label>').join(''), false);
  const n = (S.counts || {}).apps || 0;
  $('apps-info').textContent = cur === 'off'
    ? t('Фильтр выключен. Выбрано приложений: {0}.', n)
    : t('Фильтр включён. Выбрано приложений: {0}.', n) + (S.app_uids > 0 ? ' ' + t('UID найдено: {0}.', S.app_uids) : '');
}
async function setAppMode(v){
  const r = await withBusy(['set', 'APP_MODE', v], 30000);
  toast(r.code ? errText(r, 'Не удалось сменить режим') : t('Режим фильтра сохранён'));
  await stat();
  renderAppModes();
}
async function loadPk(){
  clearTimeout(pkTimer);   // отменяем отложенную перерисовку от старого ввода
  $('pk').innerHTML = '<div class="list-item"><span class="spinner"></span>' +
    '<span class="li-text"><span class="li-secondary">' + esc(t('Загрузка списка приложений…')) + '</span></span></div>';
  $('pk')._html = null;
  const r = await ctlx(['list-apps'], 30000);
  pkgs = r.code ? [] : r.out.split('\n').map(s => s.trim()).filter(Boolean);
  if(r.code) toast(errText(r, 'Не удалось получить список приложений'));
  await drawPk(true);
}
/* Список выбранных приложений кэшируется. drawPk() — обработчик oninput у поля
   поиска, и без кэша каждая нажатая буква запускала отдельный шелл: на телефоне
   это заметные рывки при наборе, а результат всё равно не менялся — фильтруется
   только локальный список пакетов. Кэш сбрасывается там, где список мог
   измениться помимо togglePkg(): после ручного редактирования в редакторе. */
let appsCache = null;
async function getAppsList(){
  if(appsCache) return appsCache;
  const r = await ctlx(['get-list', 'apps']);
  appsCache = new Set((r.code ? '' : r.out).split('\n').map(s => s.trim()).filter(s => s && s[0] !== '#'));
  return appsCache;
}
/* Фильтр перерисовывает до 120 строк на каждое нажатие, поэтому ввод
   придерживается: ctl уже не дёргается (кэш выше), а вот innerHTML — дорогой. */
let pkTimer = null;
function pkSearchInput(){
  clearTimeout(pkTimer);
  pkTimer = setTimeout(() => drawPk(false), 180);
}
async function drawPk(animate){
  const f = $('pf').value.toLowerCase();
  const s = await getAppsList();
  const shown = pkgs.filter(p => p.toLowerCase().includes(f));
  $('pk-count').textContent = t('Найдено {0} из {1}, выбрано {2}', shown.length, pkgs.length, s.size) +
    (shown.length > 120 ? '. ' + t('Показаны первые 120, уточните поиск') : '');
  setHTML('pk', shown.slice(0, 120).map(p =>
    '<label class="list-item clickable state' + (s.has(p) ? ' selected' : '') + '">' +
      '<input type="checkbox" class="checkbox" data-pkg="' + esc(p) + '"' + (s.has(p) ? ' checked' : '') + '>' +
      '<span class="li-text"><span class="li-primary li-mono">' + esc(p) + '</span></span>' +
    '</label>').join('') ||
    '<div class="list-item"><span class="li-text"><span class="li-secondary">' + esc(t('Ничего не найдено')) + '</span></span></div>', !!animate);
  $('pk').querySelectorAll('input[data-pkg]').forEach(cb => {
    cb.onchange = () => togglePkg(cb.getAttribute('data-pkg'), cb.checked);
  });
}
async function togglePkg(p, want){
  const s = await getAppsList();
  // s — тот же Set, что лежит в кэше: он мутируется на месте, так что кэш уже
  // актуален и перечитывать список после сохранения не нужно.
  if(want) s.add(p); else s.delete(p);
  const r = await withBusy(['save-list-b64', 'apps', b64([...s].join('\n'))], 30000);
  if(r.code) toast(errText(r, 'Не удалось сохранить'), {label: t('Повторить'), fn: () => togglePkg(p, want)});
  else toast((want ? t('Добавлено: {0}', p) : t('Убрано: {0}', p)));
  await drawPk(false);
  await stat(true);
  renderAppModes();
}
