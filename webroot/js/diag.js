/* nfqws2 WebUI · diag.js — диагностика
   Скрипты подключаются из index.html обычными <script> по порядку и делят одну
   глобальную область: функции и let/const одного файла видны в остальных. */

/* ══ ДИАГНОСТИКА ═════════════════════════════════════════════════════════ */
function diagInit(){ doctor(); loadArgs(); }
async function doctor(){
  setHTML('doc', '<div class="list-item"><span class="spinner"></span>' +
    '<span class="li-text"><span class="li-secondary">' + esc(t('Проверка ядра и правил…')) + '</span></span></div>', false);
  const r = await ctlx(['doctor'], 30000);
  setHTML('doc', statusRows(r.code ? '' : r.out) || '<div class="list-item"><span class="li-text"><span class="li-secondary">' +
    esc(r.code ? errText(r, 'Проверка не удалась') : t('Нет данных')) + '</span></span></div>');
}
async function loadArgs(){
  $('args').textContent = t('Загрузка…');
  const r = await ctlx(['get-logs', 'args', '5']);
  const pidInfo = (S && S.running && S.pid) ? 'PID ' + S.pid + '\n\n' : '';
  $('args').textContent = pidInfo + ((r.code ? errText(r, 'Нет данных') : r.out).trim() || t('Служба ещё не запускалась'));
}
async function copyArgs(){
  const text = $('args').textContent;
  let ok = false;
  try { await navigator.clipboard.writeText(text); ok = true; }
  catch(e){
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
    document.body.append(ta);
    ta.select();
    try { ok = document.execCommand('copy'); } catch(e2) {}
    ta.remove();
  }
  toast(ok ? t('Аргументы скопированы') : t('Не удалось скопировать: выделите текст вручную'));
}
