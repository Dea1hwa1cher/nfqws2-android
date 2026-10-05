#!/system/bin/sh
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
# Снимаем partial wakelock: в ядре это именованный лок, не привязанный к процессу, поэтому он
# переживает удаление модуля — без этой строки телефон после uninstall не заснёт до перезагрузки.
# Снимаем оба имени: nfqws2-android — текущее (совпадает с id в module.prop), nfqws2-magisk —
# прежнее, лок от него иначе остался бы висеть.
if [ -w /sys/power/wake_unlock ] 2>/dev/null; then
  echo nfqws2-android > /sys/power/wake_unlock 2>/dev/null
  echo nfqws2-magisk > /sys/power/wake_unlock 2>/dev/null
fi
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
# Без проверки на пустой pidfile получается `kill ""` — ошибка подавлена, но поведение неявное.
wpid=$(cat /data/adb/nfqws2/state/watchdog.pid 2>/dev/null)
if [ -n "$wpid" ]; then kill "$wpid" 2>/dev/null; fi
sh "$MODDIR/service.sh" stop >/dev/null 2>&1
sh "$MODDIR/service.sh" firewall_stop >/dev/null 2>&1
killall -9 nfqws2 2>/dev/null
# Настройки и списки в /data/adb/nfqws2 сохраняются. Полное удаление: rm -rf /data/adb/nfqws2
rm -rf /data/adb/nfqws2/state
exit 0
