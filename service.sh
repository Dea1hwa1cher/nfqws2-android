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
  update_description stopped
}

# Наблюдатели (watchdog и netwatch) нужны и для автоперезапуска, и для паузы в
# домашней Wi-Fi: живут, пока включено хотя бы одно из двух.
watchers_wanted() { [ "$WATCHDOG" = "1" ] || [ "$HOME_WIFI" = "1" ]; }

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

  # Проверяем результат, а не только код возврата firewall_start(): без правила
  # в POSTROUTING демон работает вхолостую — пакеты не уходят в NFQUEUE и не
  # перехватываются. Снаружи это выглядело как успешный запуск.
  firewall_start
  if ! firewall_ok; then
    log_msg "Ошибка: правила iptables не применились — трафик не перехватывается"
    # Откат: демон без правил бесполезен, а оставленный pidfile показывал бы
    # «служба работает» — ровно то, чего не произошло.
    kill -TERM "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    update_description stopped
    return 1
  fi

  system_config
  acquire_wakelock
  echo 1 > "$DESIRED_FILE"
  log_msg "nfqws2 запущен (PID $pid, Native Daemon)"
  update_description running
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

  # Снятие правил проверяем отдельно: оставленная цепочка хуже работающей. В ней
  # остаётся прыжок в NFQUEUE, слушателя уже нет, и ядро роняет эти пакеты —
  # то есть «остановлено» с оставшимися правилами означает сломанную сеть.
  if firewall_ok; then
    log_msg "Ошибка: правила iptables остались на месте — трафик в NFQUEUE без слушателя"
    return 1
  fi

  log_msg "nfqws2 остановлен"
  update_description stopped
  return 0
}

reload_lists() {
  is_running || { echo "Служба не запущена"; return 1; }
  kill -HUP "$(cat "$PIDFILE")" 2>/dev/null
  log_msg "Списки перечитаны (SIGHUP)"
}

# Поднимает помощника, если он ещё не работает.
#
#   ensure_helper <pidfile> <подкоманда> [команда-предусловие…]
#
# Возвращает 0, если помощник **только что запущен**, и 1, если запускать нечего:
# уже работает или не выполнено предусловие. Такой знак выбран не для красоты —
# вызывающему нужно отличать эти случаи: ensure_watchdog поднимает netwatch ровно
# в тот момент, когда поднял watchdog, а не при каждом вызове.
ensure_helper() {
  local pf="$1" sub="$2"; shift 2
  # [ $# -eq 0 ] явно, хотя голое `"$@"` без аргументов — тоже no-op (проверено
  # в dash): опираться на это молча не стоит.
  [ $# -eq 0 ] || { "$@" || return 1; }
  if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  (
    exec 0</dev/null
    exec >/dev/null 2>&1
    exec sh "$MODDIR/service.sh" "$sub"
  ) &
  return 0
}

ensure_watchdog() {
  [ "$WATCHDOG" = "1" ] || return 0
  ensure_helper "$WD_PIDFILE" watchdog || return 0
  ensure_netwatch
}

# Правила нужно перестраивать по событию, а не по таймеру: на роутере за это отвечает хук
# прошивки (netfilter.d), который вызывается каждый раз при перестройке mangle/nat. У Android
# аналогичного хука для сторонних модулей нет, но netlink-поток `ip monitor` даёт почти то же
# самое — события интерфейсов и маршрутов в реальном времени. Watchdog остаётся подстраховкой
# (и единственным механизмом там, где ip monitor не поддерживается прошивкой).
ensure_netwatch() {
  [ "$WATCHDOG" = "1" ] || return 0
  ensure_helper "$WN_PIDFILE" netwatch command -v ip || return 0
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
      watchers_wanted || break 2
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
      if [ "$sz" != "$acted" ] && [ "$sz" != 0 ]; then
        if [ -f "$DESIRED_FILE" ] && is_running; then
          log_msg "netwatch: сеть изменилась (ip monitor) — пересобираю правила"
          firewall_start
        fi
        home_check
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
    watchers_wanted || break
    tick=$((tick + 1))
    # Домашняя сеть проверяется и здесь — на прошивках, где ip monitor не
    # работает, это единственный способ её заметить. Раз в минуту, а не каждый
    # тик: `cmd wifi` заметно дороже остальной проверки.
    [ "$HOME_WIFI" = "1" ] && [ $((tick % 3)) -eq 0 ] && home_check
    [ "$WATCHDOG" = "1" ] || continue
    [ -f "$DESIRED_FILE" ] || continue

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

# ---------------------------------------------------------------- домашняя Wi-Fi
# В сети из home_wifi.list служба останавливается и сама поднимается, когда
# телефон из неё уходит. Ручной запуск в домашней сети запоминается
# (home_override) и действует, пока телефон в этой же сети.
home_check() {
  # Два наблюдателя могут прийти сюда одновременно: каталог-замок не даёт им
  # остановить и запустить службу дважды.
  # Замок старше двух минут — след убитого процесса, а не идущая проверка.
  [ -n "$(find "$STATE_DIR/home.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$STATE_DIR/home.lock" 2>/dev/null
  mkdir "$STATE_DIR/home.lock" 2>/dev/null || return 0
  local ssid=""
  if [ "$HOME_WIFI" = "1" ]; then
    ssid=$(current_ssid)
    if [ -f "$HOME_OVERRIDE_FILE" ] && [ "$(cat "$HOME_OVERRIDE_FILE" 2>/dev/null)" != "$ssid" ]; then
      rm -f "$HOME_OVERRIDE_FILE"
    fi
  fi
  if [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid"; then
    if [ ! -f "$HOME_OVERRIDE_FILE" ] && is_running && [ ! -f "$HOME_PAUSED_FILE" ]; then
      log_msg "Домашняя Wi-Fi «$ssid» — обход приостановлен"
      stop >/dev/null 2>&1
      printf '%s' "$ssid" > "$HOME_PAUSED_FILE"
      update_description paused "$ssid"
    fi
  elif [ -f "$HOME_PAUSED_FILE" ]; then
    rm -f "$HOME_PAUSED_FILE"
    log_msg "Домашняя Wi-Fi больше не активна — обход возобновлён"
    start >/dev/null 2>&1 || log_msg "Не удалось возобновить обход после домашней Wi-Fi"
  fi
  rmdir "$STATE_DIR/home.lock" 2>/dev/null
  return 0
}

# Ручной запуск: снимает паузу и, если телефон сейчас в домашней сети,
# запоминает, что в ней пользователь хочет работать с обходом.
manual_start() {
  local ssid
  rm -f "$HOME_PAUSED_FILE"
  if [ "$HOME_WIFI" = "1" ] && ssid=$(current_ssid) && ssid_is_home "$ssid"; then
    printf '%s' "$ssid" > "$HOME_OVERRIDE_FILE"
  fi
  start
}

status_service() {
  if is_running; then
    echo "Служба NFQWS2 запущена (PID $(cat "$PIDFILE"))"
  else
    echo "Служба NFQWS2 остановлена"
  fi
}

case "$1" in
  start)              manual_start ;;
  stop)               rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE"; stop ;;
  home_check)         home_check; ensure_watchdog ;;
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
    rm -f "$HOME_PAUSED_FILE" "$HOME_OVERRIDE_FILE"
    rmdir "$STATE_DIR/home.lock" 2>/dev/null
    if [ "$AUTOSTART" = "1" ]; then
      ssid=$(current_ssid)
      if [ "$HOME_WIFI" = "1" ] && ssid_is_home "$ssid"; then
        log_msg "Домашняя Wi-Fi «$ssid» — автозапуск отложен до выхода из неё"
        printf '%s' "$ssid" > "$HOME_PAUSED_FILE"
        update_description paused "$ssid"
      else
        start || log_msg "Автозапуск не удался"
      fi
    else
      update_description stopped
    fi
    ensure_watchdog
    ;;
esac
# Наружу уходит статус выполненной команды, а не безусловный ноль. С `exit 0`
# провал выглядел успехом везде: nfqws2-ctl просто пробрасывает этот статус,
# поэтому «start не поднял демона» и «firewall_apply не принял правила» были
# неотличимы от удачи — и `|| { ...; return 1; }` в cmd_firewall_apply не
# срабатывал ни разу за всё время. Ветка автозапуска (`*`) выходит через
# ensure_watchdog, её статус тоже уходит наружу; при загрузке его никто не
# проверяет, а вызывать service.sh руками с ожиданием кода — нормальный сценарий.
exit $?
