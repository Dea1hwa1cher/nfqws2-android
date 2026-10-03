#!/system/bin/sh
# Кнопка «Действие» в менеджере: переключает службу и показывает статус
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
CTL="$MODDIR/bin/nfqws2-ctl"
if sh "$CTL" is-running >/dev/null 2>&1; then
  echo "Служба запущена -> останавливаю"
  sh "$CTL" stop
else
  echo "Служба остановлена -> запускаю"
  sh "$CTL" start
fi
echo
sh "$CTL" status
