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
       "$MODPATH/.git" "$MODPATH/.github" "$MODPATH/.gitattributes"
rm -f "$MODPATH"/*.zip

[ -f "$MODPATH/binaries/$BIN/nfqws2" ] || abort "! Нет бинарника $BIN"
cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2" || abort "! Не удалось скопировать nfqws2"
rm -rf "$MODPATH/binaries"

CONF=/data/adb/nfqws2
mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies"

if [ -f "$CONF/nfqws2.conf" ]; then
  ui_print "- Конфиг сохранён: $CONF/nfqws2.conf"
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf.dist"
else
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf"
  ui_print "- Создан конфиг: $CONF/nfqws2.conf"
fi
for f in user exclude ipset ipset_exclude auto probe_hosts; do
  [ -f "$CONF/lists/$f.list" ] || cp -f "$MODPATH/lists/$f.list" "$CONF/lists/$f.list"
done
[ -f "$CONF/apps.list" ] || echo "# Пакеты для фильтра приложений (APP_MODE=include|exclude), по одному на строку" > "$CONF/apps.list"
rm -f "$CONF/state/caps"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for x in service.sh action.sh uninstall.sh bin/nfqws2 bin/nfqws2-ctl; do
  set_perm "$MODPATH/$x" 0 0 0755
done
chmod 0700 "$CONF" 2>/dev/null

ui_print "- Готово. Перезагрузите устройство или запустите модуль кнопкой Action / через WebUI."
ui_print "- WebUI: KernelSU/APatch — из менеджера; Magisk — через приложение KsuWebUI или MMRL."
