#!/system/bin/sh
# lifecycle hook called by Magisk, KernelSU, or APatch
umask 077
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/nfqws2-android
. "$MODDIR/lib/common.sh"
load_conf >/dev/null 2>&1

log_msg "boot-completed: запуск хука (sys.boot_completed=1)"

# restore the service after boot if it should be running
if [ "$AUTOSTART" = "1" ] || [ -f "$DESIRED_FILE" ]; then
  if ! is_running; then
    log_msg "boot-completed: nfqws2 не активен после старта системы — восстанавливаю..."
    sh "$MODDIR/service.sh" start >/dev/null 2>&1
  else
    protect_process "$(cat "$PIDFILE" 2>/dev/null)"
    if ! firewall_ok; then
      log_msg "boot-completed: восстановление правил файрвола"
      firewall_start
    fi
  fi
fi

# ensure watchdog and netwatch are running
sh "$MODDIR/service.sh" ensure_watchdog >/dev/null 2>&1

exit 0
