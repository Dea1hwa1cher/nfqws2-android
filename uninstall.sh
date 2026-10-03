#!/system/bin/sh
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
kill "$(cat /data/adb/nfqws2/state/watchdog.pid 2>/dev/null)" 2>/dev/null
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
sh "$MODDIR/service.sh" firewall_stop >/dev/null 2>&1
killall -9 nfqws2 2>/dev/null
# Настройки и списки в /data/adb/nfqws2 сохраняются. Полное удаление: rm -rf /data/adb/nfqws2
rm -rf /data/adb/nfqws2/state
exit 0
