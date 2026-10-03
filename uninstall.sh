#!/system/bin/sh
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
kill "$(cat /data/adb/modules/nfqws2-android/state/watchdog.pid 2>/dev/null)" 2>/dev/null
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
sh "$MODDIR/service.sh" firewall_stop >/dev/null 2>&1
killall -9 nfqws2 2>/dev/null
exit 0
