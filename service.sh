#!/system/bin/sh
# nfqws2-android — управление службой (C-Level Native Daemon)
MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
umask 077
. "$MODDIR/lib/common.sh"
load_conf

STARTED_FILE="$STATE_DIR/started_at"

# Обе ветки отказа в start() кончаются одинаково — причиной и хвостом лога
# запуска, — поэтому хвост живёт здесь, а не копией в каждой ветке.
start_failed() { # <причина>
  log_msg "$1"
  log_msg "Последние строки лога:"
  tail -n 8 "$NFQWS_LOG" 2>/dev/null | while IFS= read -r l; do log_msg "  $l"; done
}

start() {
  if is_running; then
    echo "Служба nfqws2 уже запущена (PID $(cat "$PIDFILE"))"
    return 0
  fi
  if [ ! -x "$NFQWS_BIN" ]; then
    chmod 0755 "$NFQWS_BIN" 2>/dev/null
    [ -x "$NFQWS_BIN" ] || { log_msg "Ошибка: нет исполняемого $NFQWS_BIN"; return 1; }
  fi
  local err
  err=$(validate_args_conf) || { log_msg "$err"; return 1; }

  log_msg "Запуск nfqws2..."
  kernel_modules
  rotate_logs start

  local args
  args=$(_startup_args)
  printf '%s\n' "$args" > "$ARGS_FILE"

  cd "$MODDIR/bin" || return 1
  set -f

  # Запуск со встроенным --daemon: nfqws2 сам отрывается от родителя под init (PID 1)
  # и пишет свой настоящий PID в $PIDFILE
  rm -f "$PIDFILE"
  "$NFQWS_BIN" --daemon --pidfile="$PIDFILE" $args >> "$NFQWS_LOG" 2>&1
  local res=$?
  set +f

  if [ "$res" -ne 0 ]; then
    start_failed "Ошибка: nfqws2 завершился с кодом $res."
    return 1
  fi


  sleep 1.2
  local pid=""
  [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || pid=$(pidof nfqws2 2>/dev/null | awk '{print $1}')

  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    start_failed "Ошибка: nfqws2 не запустился."
    return 1
  fi

  echo "$pid" > "$PIDFILE"
  protect_process "$pid"
  date +%s > "$STARTED_FILE"

  firewall_start
  system_config
  acquire_wakelock
  echo 1 > "$DESIRED_FILE"
  log_msg "nfqws2 запущен (PID $pid, Native Daemon)"
  ensure_watchdog
  return 0
}

stop() {
  rm -f "$DESIRED_FILE" "$STARTED_FILE"
  release_wakelock
  firewall_stop
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      sleep 0.8
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
  fi
  pidof nfqws2 >/dev/null 2>&1 && killall -9 nfqws2 2>/dev/null
  log_msg "nfqws2 остановлен"
  return 0
}

reload_lists() {
  is_running || { echo "Служба не запущена"; return 1; }
  kill -HUP "$(cat "$PIDFILE")" 2>/dev/null
  log_msg "Списки перечитаны (SIGHUP)"
}

ensure_watchdog() {
  [ "$WATCHDOG" = "1" ] || return 0
  if [ -f "$WD_PIDFILE" ] && kill -0 "$(cat "$WD_PIDFILE" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  (
    exec 0</dev/null
    exec >/dev/null 2>&1
    exec sh "$MODDIR/service.sh" watchdog
  ) &
  ensure_netwatch
}

# Правила нужно перестраивать по событию, а не по таймеру: на роутере за это отвечает хук
# прошивки (netfilter.d), который вызывается каждый раз при перестройке mangle/nat. У Android
# аналогичного хука для сторонних модулей нет, но netlink-поток `ip monitor` даёт почти то же
# самое — события интерфейсов и маршрутов в реальном времени. Watchdog остаётся подстраховкой
# (и единственным механизмом там, где ip monitor не поддерживается прошивкой).
ensure_netwatch() {
  [ "$WATCHDOG" = "1" ] || return 0
  command -v ip >/dev/null 2>&1 || return 0
  if [ -f "$WN_PIDFILE" ] && kill -0 "$(cat "$WN_PIDFILE" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  (
    exec 0</dev/null
    exec >/dev/null 2>&1
    exec sh "$MODDIR/service.sh" netwatch
  ) &
}

netwatch() {
  echo $$ > "$WN_PIDFILE"
  protect_process
  command -v ip >/dev/null 2>&1 || { rm -f "$WN_PIDFILE"; return 0; }

  EVFILE="$STATE_DIR/netwatch_events"
  rm -f "$EVFILE"
  local prev="" acted="" backoff=2 saw=0 sz mon
  # Монитор пишет события прямо в файл, реакция — на изменение его размера. Никакого пайпа со
  # вспомогательным циклом: в таком виде kill -TERM снимает именно ip monitor, а не обёртку,
  # за которой остаётся сирота, и не нужны ни `read -t` (нет в dash), ни `date +%s%N` (нет в
  # toybox). Опрос 2 с, а не 1: лишняя пробудка CPU каждый телефон держит на весу всю ночь.
  while :; do
    ip monitor route link 2>/dev/null >> "$EVFILE" &
    mon=$!
    saw=0
    while :; do
      sleep 2
      load_conf >/dev/null 2>&1
      [ "$WATCHDOG" = "1" ] || break 2
      if ! kill -0 "$mon" 2>/dev/null; then
        # монитор умер сам. Если он не написал ни байта с момента запуска — на этой прошивке
        # ip monitor, похоже, не работает: растущая пауза вместо бесконечного рестарта.
        if [ "$saw" = 0 ]; then
          sleep "$backoff"
          [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
        else
          backoff=2
        fi
        break
      fi
      sz=$(wc -c < "$EVFILE" 2>/dev/null)
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
      if [ "$sz" != "$prev" ]; then
        # событие только что пришло: ждём ещё один тик тишины, чтобы не пересобирать правила
        # на каждый пакет из пачки событий одной смены сети
        prev="$sz"
        saw=1
        continue
      fi
      if [ "$sz" != "$acted" ] && [ "$sz" != 0 ] && [ -f "$DESIRED_FILE" ] && is_running; then
        log_msg "netwatch: сеть изменилась (ip monitor) — пересобираю правила"
        firewall_start
        acted="$sz"
      fi
      [ "$sz" -gt 262144 ] && { kill -TERM "$mon" 2>/dev/null; : > "$EVFILE"; prev=""; acted=""; }
    done
    kill -TERM "$mon" 2>/dev/null
    wait "$mon" 2>/dev/null
  done
  kill -TERM "$mon" 2>/dev/null
  rm -f "$WN_PIDFILE" "$EVFILE"
}

watchdog() {
  echo $$ > "$WD_PIDFILE"
  protect_process
  local fails=0 tick=0
  while :; do
    sleep 20
    load_conf >/dev/null 2>&1
    [ "$WATCHDOG" = "1" ] || break
    [ -f "$DESIRED_FILE" ] || continue
    tick=$((tick + 1))
    
    if ! is_running; then
      fails=$((fails + 1))
      log_msg "watchdog: nfqws2 упал, автоперезапуск (#$fails)..."
      firewall_stop
      start
      sleep 2
      continue
    fi

    # Если процесс проработал стабильно хотя бы один цикл, сбрасываем счетчик сбоев
    fails=0

    # Быстрое восстановление iptables при смене сети (Wi-Fi <-> 4G)
    if ! firewall_ok; then
      log_msg "watchdog: правила iptables сброшены системой — восстановление"
      firewall_start
    fi
    refresh_connmark_counter
    [ $((tick % 25)) -eq 0 ] && rotate_logs
  done
  rm -f "$WD_PIDFILE"
}

status_service() {
  if is_running; then
    echo "Служба NFQWS2 запущена (PID $(cat "$PIDFILE"))"
  else
    echo "Служба NFQWS2 остановлена"
  fi
}

case "$1" in
  start)              start ;;
  stop)               stop ;;
  restart)            stop; start ;;
  reload)             reload_lists ;;
  status)             status_service ;;
  watchdog)           watchdog ;;
  netwatch)           netwatch ;;
  firewall_iptables)  firewall_iptables ;;
  firewall_apply)     firewall_start ;;
  firewall_ip6tables) firewall_ip6tables ;;
  firewall_stop)      firewall_stop ;;
  *)
    until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 3; done
    sleep 4
    [ -f "$CONFDIR/disable" ] && { log_msg "Найден $CONFDIR/disable — автозапуск пропущен"; exit 0; }
    if [ "$AUTOSTART" = "1" ]; then
      start || log_msg "Автозапуск не удался"
    fi
    ensure_watchdog
    ;;
esac
exit 0
