#!/system/bin/sh
# Установщик модуля (Magisk / KernelSU / APatch)
SKIPUNZIP=1
umask 022

ui_print "*******************************************"
ui_print " nfqws2 for Android "
ui_print " порт nfqws/nfqws2-keenetic + bol-van/zapret2"
ui_print "*******************************************"

ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
case "$ABI" in
  arm64*|aarch64*) BIN=android-arm64 ;;
  armeabi*|arm*)   BIN=android-arm ;;
  x86_64*)         BIN=android-x86_64 ;;
  x86*)            BIN=android-x86 ;;
  *) abort "! Неподдерживаемая архитектура: $ABI" ;;
esac
ui_print "- Архитектура: $ABI -> $BIN"

ui_print "- Распаковка..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 || abort "! Не удалось распаковать модуль"

# Разработческие каталоги не должны оставаться на устройстве, даже если архив
# собран вручную — например, простым zip из корня репозитория, куда попадают и
# tests/, и tools/, и логи работы. Штатная сборка (tools/build.py) их не кладёт
# вовсе, а здесь — вторая линия защиты.
#
# Именно удаление, а не `unzip -x`: в unzip '*' не пересекает '/', поэтому
# шаблон 'tests/*' отсекает только файлы верхнего уровня, а вложенные
# (tests/module/*, .workbuddy-ai/memory/*) распаковываются как обычно —
# проверено на Info-ZIP 6.00. Удаляем целиком, до set_perm_recursive.
rm -rf "$MODPATH/tests" "$MODPATH/tools" "$MODPATH/.workbuddy-ai" \
       "$MODPATH/.git" "$MODPATH/.github" "$MODPATH/.gitattributes" \
       "$MODPATH/CONTRIBUTING.md"
rm -f "$MODPATH"/*.zip

[ -f "$MODPATH/binaries/$BIN/nfqws2" ] || abort "! Нет бинарника $BIN"
cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2" || abort "! Не удалось скопировать nfqws2"
rm -rf "$MODPATH/binaries"

CONF=/data/adb/nfqws2
# Каталоги и конфиг проверяем: без них модуль не заработает, а раньше провал
# проходил молча — установка сообщала «Готово» на пустом месте. Остальные шаги
# ниже самовосстанавливающиеся (load_conf допишет конфиг и списки сам), эти два —
# нет: если /data/adb недоступен, дальше писать некуда.
mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies" \
  || abort "! Не удалось создать $CONF — проверьте доступ к /data/adb"

if [ -f "$CONF/nfqws2.conf" ]; then
  ui_print "- Конфиг сохранён: $CONF/nfqws2.conf"
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf.dist" \
    || abort "! Не удалось положить $CONF/nfqws2.conf.dist"
else
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf" \
    || abort "! Не удалось создать $CONF/nfqws2.conf"
  ui_print "- Создан конфиг: $CONF/nfqws2.conf"
fi
# Списки из релиза. Правки пользователя при обновлении не затираются:
#   - списка ещё нет                       → кладём новый;
#   - список не трогали (= прошлый релиз)  → тихо обновляем;
#   - список правили, а в релизе он новый  → новая версия ждёт в .pending,
#     WebUI отмечает такой список «!» и предлагает заменить его вручную.
# .dist хранит версию последнего релиза — по ней и видно, правил ли пользователь.
# auto.list — исключение: он выученный, его всегда оставляем как есть.
# Сервисные списки (google, youtube, ipset_* …) WebUI не редактирует: без
# истории в .dist (обновление с версии, где её не было) их просто заменяем.
# reset-lists в nfqws2-ctl намеренно НЕ трогает auto.list — сброс стёр бы
# наработку. Списки обязаны различаться ровно на auto, это проверяет test_data.sh.
DIST="$CONF/lists/.dist"; PEND="$CONF/lists/.pending"
mkdir -p "$DIST" "$PEND"
for src in "$MODPATH"/lists/*.list; do
  [ -f "$src" ] || continue
  f="${src##*/}"; dst="$CONF/lists/$f"
  if [ "$f" = "auto.list" ]; then
    [ -f "$dst" ] || cp -f "$src" "$dst"
    continue
  fi
  if [ ! -f "$dst" ] || cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst"; rm -f "$PEND/$f"
  elif [ -f "$DIST/$f" ] && cmp -s "$dst" "$DIST/$f"; then
    cp -f "$src" "$dst"; rm -f "$PEND/$f"
  elif [ ! -f "$DIST/$f" ] && case " user exclude ipset ipset_exclude probe_hosts " in *" ${f%.list} "*) false ;; *) true ;; esac; then
    cp -f "$src" "$dst"; rm -f "$PEND/$f"
  elif [ -f "$DIST/$f" ] && cmp -s "$src" "$DIST/$f"; then
    :   # в релизе список не менялся — правкам пользователя предлагать нечего
  else
    cp -f "$src" "$PEND/$f"
    ui_print "- $f изменён вами: новая версия ждёт подтверждения в WebUI"
  fi
  cp -f "$src" "$DIST/$f"
done
[ -f "$CONF/apps.list" ] || echo "# Пакеты для фильтра приложений (APP_MODE=include|exclude), по одному на строку" > "$CONF/apps.list"
[ -f "$CONF/home_wifi.list" ] || echo "# Домашние сети Wi-Fi (SSID по одному на строку): в них обход ставится на паузу" > "$CONF/home_wifi.list"
# Файл caps писали старые версии модуля; сам механизм больше не существует, но
# уборку оставляем: при обновлении со старой версии файл должен исчезнуть.
# Переменная CAPS_FILE из lib/common.sh удалена ревью 2026-10-06 как мёртвая —
# здесь путь намеренно литералом, читать его больше неоткуда.
rm -f "$CONF/state/caps"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for x in service.sh action.sh uninstall.sh bin/nfqws2 bin/nfqws2-ctl; do
  set_perm "$MODPATH/$x" 0 0 0755
done
chmod 0700 "$CONF" 2>/dev/null

ui_print "- Готово. Перезагрузите устройство."
