#!/system/bin/sh
# nfqws2-magisk — общая библиотека.
# Логика перенесена из nfqws2-keenetic (etc/init.d/common) и адаптирована под Android.
# Подключается через:  MODDIR=...; . "$MODDIR/lib/common.sh"

[ -n "$MODDIR" ] || { echo "MODDIR is not set" >&2; return 1 2>/dev/null || exit 1; }

: "${CONFDIR:=/data/adb/nfqws2}"
CONFFILE="$CONFDIR/nfqws2.conf"
LISTS_DIR="$CONFDIR/lists"
STATE_DIR="$CONFDIR/state"
LOG_DIR="$CONFDIR/logs"
IMPORTS_DIR="$CONFDIR/imports"

LUA_DIR="$MODDIR/lua"
BLOBS_DIR="$MODDIR/blobs"
NFQWS_BIN="$MODDIR/bin/nfqws2"

PIDFILE="$STATE_DIR/nfqws2.pid"
WD_PIDFILE="$STATE_DIR/watchdog.pid"
DESIRED_FILE="$STATE_DIR/desired"
ARGS_FILE="$STATE_DIR/last.args"
CAPS_FILE="$STATE_DIR/caps"
STARTED_AT_FILE="$STATE_DIR/started_at"
SERVICE_LOG="$LOG_DIR/service.log"
NFQWS_LOG="$LOG_DIR/nfqws2.log"

# Метки пакетов (как в nfqws2-keenetic)
MARK_EXCLUDE="0x20000000/0x20000000"    # соединение исключено (connmark)
MARK_INCLUDE="0x10000000/0x10000000"    # соединение принадлежит выбранному приложению (connmark)
MARK_PROCESSED="0x40000000/0x40000000"  # пакет уже обработан nfqws2 (ставит сам nfqws2)

IPT_GROUP_POST="nfqws_post"
IPT_GROUP_PRE="nfqws_pre"
IPT_GROUP_NAT="nfqws_nat"
IPT_GROUP_APP="nfqws_app"
IPT_GROUP_QOUT="nfqws_qout"   # дешёвый счётчик исходящих пакетов (см. _fw_counter_chain)
LIMITER_FILE_NAME="limiter"
# Биты CONNMARK для дешёвого счётчика исходящих пакетов (используется только когда нет connbytes,
# и только для исходящего направления — см. пояснение у _fw_counter_chain).
CNT_OUT_MASK=0x0f000000; CNT_OUT_STEP=16777216   # 1<<24, 4 бита = счётчик 0..15

mkdir -p "$LISTS_DIR" "$STATE_DIR" "$LOG_DIR" "$IMPORTS_DIR" 2>/dev/null

# ---------------------------------------------------------------- значения по умолчанию
set_defaults() {
  : "${ISP_INTERFACE:=}"
  : "${IFACE_EXCLUDE:=lo tun+ tap+ wg+ ppp+ ipsec+ ifb+ dummy+}"
  : "${IPV6_ENABLED:=1}"
  : "${TCP_PORTS:=80,443,1984,2053,2083,2087,2096,5222,8443}"
  : "${UDP_PORTS:=443,590:600,1400,3478:3481,5349,19294:19344,49152:65535}"
  : "${NFQUEUE_NUM:=300}"
  : "${NFQWS_USER:=root}"
  : "${LOG_LEVEL:=0}"
  : "${AUTOSTART:=1}"
  : "${WATCHDOG:=1}"
  : "${BLOCK_QUIC:=0}"
  : "${NAT_FIX:=1}"
  # Автооткат, если после применения правил/новой стратегии пропадает связь (см. safe_start_check)
  : "${SAFE_START:=1}"
  : "${APP_MODE:=off}"
  : "${LOG_MAX_KB:=512}"
  : "${PKT_LIMIT_OUT:=15}"
  : "${PKT_LIMIT_IN:=15}"
  case "$PKT_LIMIT_OUT" in ''|*[!0-9]*) PKT_LIMIT_OUT=15 ;; esac
  [ "$PKT_LIMIT_OUT" -ge 1 ] 2>/dev/null && [ "$PKT_LIMIT_OUT" -le 15 ] 2>/dev/null || PKT_LIMIT_OUT=15
  case "$PKT_LIMIT_IN" in ''|*[!0-9]*) PKT_LIMIT_IN=15 ;; esac
  [ "$PKT_LIMIT_IN" -ge 1 ] 2>/dev/null && [ "$PKT_LIMIT_IN" -le 15 ] 2>/dev/null || PKT_LIMIT_IN=15
}

# ---------------------------------------------------------------- лог
log_msg() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*"
  echo "$line"
  echo "$line" >> "$SERVICE_LOG" 2>/dev/null
}

# Ротация "на месте" (copytruncate): файл остаётся тем же inode, поэтому процесс, который в него пишет,
# не теряет лог. Прежний вариант через mv оставлял nfqws2 писать в удалённый файл (лог "замирал", место не освобождалось).
# Отладочный лог nfqws2 в работе не трогаем (неизвестно, открыт ли он в режиме append) — он усекается при запуске.
rotate_file() {   # $1 - файл, $2 - максимальный размер в байтах
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null)
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt "$max" ] || return 0
  tail -c $((max / 2)) "$f" > "$f.tmp" 2>/dev/null && cat "$f.tmp" > "$f" 2>/dev/null
  rm -f "$f.tmp"
}

rotate_logs() {   # $1 = start: вызывается до запуска nfqws2, можно усекать и debug-лог
  local max=$(( ${LOG_MAX_KB:-512} * 1024 )) f
  for f in "$SERVICE_LOG" "$NFQWS_LOG" "$LOG_DIR/auto.log"; do rotate_file "$f" "$max"; done
  if [ "$1" = "start" ]; then
    f="$LOG_DIR/nfqws2-debug.log"
    [ "$LOG_LEVEL" = "1" ] && : > "$f" 2>/dev/null || rotate_file "$f" "$max"
  fi
}

# ---------------------------------------------------------------- конфиг
# Конфиг подключается через "." (как в оригинале), поэтому перед этим он проверяется:
# вне кавычек допускаются только присваивания KEY=значение и комментарии,
# внутри кавычек запрещены обратные кавычки и $( ... ) — то есть выполнение команд.
validate_conf() {
  awk '
    BEGIN { ok = 1 }
    /`/ { printf "line %d: backtick is forbidden\n", NR; ok = 0 }
    /\$\(/ { printf "line %d: $( is forbidden\n", NR; ok = 0 }
    END { exit ok ? 0 : 1 }
  ' "$1"
}

load_conf() {
  if [ ! -f "$CONFFILE" ]; then
    cp -f "$MODDIR/defaults/nfqws2.conf" "$CONFFILE" 2>/dev/null
  fi
  local err
  err=$(validate_conf "$CONFFILE" 2>&1) || {
    log_msg "Конфиг $CONFFILE не прошёл проверку: $err"
    log_msg "Используется встроенный конфиг по умолчанию"
    . "$MODDIR/defaults/nfqws2.conf"
    set_defaults
    return 1
  }
  . "$CONFFILE"
  set_defaults
  return 0
}

validate_args_conf() {
  local v var
  for var in NFQWS_BASE_ARGS NFQWS_ARGS NFQWS_ARGS_QUIC NFQWS_ARGS_UDP NFQWS_EXTRA_ARGS NFQWS_ARGS_IPSET; do
    eval "v=\$$var"
    case "$v" in
      *--new*) echo "Использовать --new в $var нельзя. Используйте NFQWS_ARGS_CUSTOM"; return 1 ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------- состояние
is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}

list_count() {
  [ -f "$1" ] || { printf 0; return; }
  local c
  c=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null)
  printf '%s' "${c:-0}"
}

# ---------------------------------------------------------------- возможности бинарника
# Оригинальный nfqws2-keenetic использует пропатченный бинарник (--fastpath-workaround).
# Стандартный бинарник zapret2 этой опции не знает, поэтому её передаём только если она поддерживается.
nfqws_supports() {
  local opt="$1" key
  [ -x "$NFQWS_BIN" ] || return 1
  key=$(cksum < "$NFQWS_BIN" 2>/dev/null | cut -d' ' -f1)
  if [ ! -f "$CAPS_FILE" ] || ! grep -q "^bin=$key$" "$CAPS_FILE" 2>/dev/null; then
    { echo "bin=$key"; if command -v timeout >/dev/null 2>&1; then timeout 5 "$NFQWS_BIN" --help 2>&1; else "$NFQWS_BIN" --help 2>&1; fi | grep -o -e '--[a-z0-9-]*' | sort -u | sed 's/^--/opt=/'; } > "$CAPS_FILE" 2>/dev/null
  fi
  grep -q "^opt=$opt$" "$CAPS_FILE" 2>/dev/null
}

# ---------------------------------------------------------------- построение аргументов
# 1) убрать строки-комментарии внутри многострочных значений, 2) сжать пробелы,
# 3) подменить пути оригинала (/opt/...) на пути Android.
norm_args() {
  printf '%s\n' "$1" \
    | sed -e 's/^[[:space:]]*#.*$//' -e 's/\\$//' \
    | tr '\n\t' '  ' | tr -s ' ' \
    | sed -e "s#/opt/etc/nfqws2/lua#$LUA_DIR#g" \
          -e "s#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g" \
          -e "s#/opt/etc/nfqws2/lists#$LISTS_DIR#g" \
          -e "s#/opt/etc/nfqws2#$CONFDIR#g" \
          -e "s#/opt/var/log#$LOG_DIR#g" \
          -e 's/^ //; s/ $//'
}

port_list_without() {   # $1 - список портов через запятую, $2 - порт для удаления
  printf ',%s,' "$1" | sed "s/,$2,/,/g; s/^,//; s/,\$//"
}

_startup_args() {
  local base tcp quic udp extra custom ipset
  base=$(norm_args "$NFQWS_BASE_ARGS")
  tcp=$(norm_args "$NFQWS_ARGS")
  quic=$(norm_args "$NFQWS_ARGS_QUIC")
  udp=$(norm_args "$NFQWS_ARGS_UDP")
  extra=$(norm_args "$NFQWS_EXTRA_ARGS")
  custom=$(norm_args "$NFQWS_ARGS_CUSTOM")
  ipset=""
  if [ -n "$NFQWS_ARGS_IPSET" ] && [ "$(list_count "$LISTS_DIR/ipset.list")" -gt 0 ]; then
    ipset=$(norm_args "$NFQWS_ARGS_IPSET")
  fi

  local args="--user=$NFQWS_USER --qnum=$NFQUEUE_NUM"

  # --fastpath-workaround есть только в пропатченном бинарнике Keenetic: при импорте оригинального
  # конфига опция лежит в NFQWS_BASE_ARGS, поэтому на стандартном бинарнике её нужно вырезать.
  if nfqws_supports fastpath-workaround; then
    case " $base " in
      *' --fastpath-workaround='*) ;;
      *) args="$args --fastpath-workaround=auto" ;;
    esac
  else
    base=$(printf '%s' "$base" | sed 's/--fastpath-workaround=[^ ]*//g' | tr -s ' ' | sed 's/^ //; s/ $//')
  fi
  args="$args $base"

  # На Android bind-fix4 ломает raw-сокеты из-за policy routing (errno 101: Network is unreachable)
  if [ -n "$ISP_INTERFACE" ] && [ "$(echo $ISP_INTERFACE | wc -w)" -gt 1 ]; then
  nfqws_supports bind-fix4 && args="$args --bind-fix4"
  [ "$IPV6_ENABLED" != "0" ] && nfqws_supports bind-fix6 && args="$args --bind-fix6"
  fi

  if [ "$LOG_LEVEL" = "1" ]; then
    args="--debug=@$LOG_DIR/nfqws2-debug.log $args"
  else
    args="--debug=@$NFQWS_LOG $args"
  fi

  [ -n "$custom" ] && args="$args $custom --new"
  [ -n "$udp" ] && args="$args $udp --new"

  if [ -n "$quic" ] && [ "$BLOCK_QUIC" != "1" ]; then
    [ -n "$ipset" ] && args="$args $quic $ipset --ipset-ip=0.0.0.0 --new"
    args="$args $quic $extra --new"
  fi

  [ -n "$ipset" ] && args="$args $tcp $ipset --ipset-ip=0.0.0.0 --new"
  args="$args $tcp $extra"

  printf '%s' "$args" | tr -s ' '
}

# ---------------------------------------------------------------- приложения (UID)
# Список пакетов в $CONFDIR/apps.list, режим APP_MODE: off | include | exclude
resolve_uids() {
  local pkg uid
  [ -f "$CONFDIR/apps.list" ] || return 0
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$CONFDIR/apps.list" | while read -r pkg _rest; do
    uid=$(awk -v p="$pkg" '$1 == p { print $2; exit }' ${PACKAGES_LIST:-/data/system/packages.list} 2>/dev/null)
    [ -n "$uid" ] && echo "$uid"
  done
}

# ---------------------------------------------------------------- ядро
kernel_modules() {
  command -v modprobe >/dev/null 2>&1 || return 0
  modprobe -a -q nfnetlink_queue xt_multiport xt_connbytes xt_NFQUEUE xt_CONNMARK xt_connmark xt_owner nf_conntrack 2>/dev/null
  return 0
}

has_ipt_feature() {   # $1 - iptables/ip6tables, остальное - правило для проверки в тестовой цепочке
  ipt_probe "$@" >/dev/null 2>&1
}

# То же, но печатает причину отказа (для диагностики). Код возврата 0 - правило принято.
ipt_probe() {
  local CMD="$1"; shift
  local err rc
  $CMD -w -t mangle -N nfqws_test >/dev/null 2>&1
  $CMD -w -t mangle -F nfqws_test >/dev/null 2>&1
  err=$($CMD -w -t mangle -A nfqws_test "$@" 2>&1); rc=$?
  $CMD -w -t mangle -F nfqws_test >/dev/null 2>&1
  $CMD -w -t mangle -X nfqws_test >/dev/null 2>&1
  [ "$rc" -eq 0 ] || printf '%s' "$err" | tail -n1
  return $rc
}

# Есть ли в ядре/iptables xt_connbytes. Без него ограничить число пакетов на соединение нечем:
# любая замена через CONNMARK требует по одному правилу iptables на каждое значение счётчика и
# линейно перебирается ядром для КАЖДОГО пакета соединения — при лимите 15-50 это 16-52 правила на
# пакет и заметная нагрузка на слабых SoC. Это и оказалось причиной циклических подвисаний сети.
# Поэтому, как и в справочном модуле zapret2-magisk, без connbytes ПОЛНЫЙ перехват входящего потока
# (PREROUTING) не делаем — только управляющие пакеты (RST/FIN/SYN,ACK, см. _fw_iface_rules), которых
# на порядки меньше, чем потока данных.
detect_limiter() {   # $1 - iptables/ip6tables (по умолчанию iptables)
  local C="${1:-iptables}"
  if has_ipt_feature $C -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:15 -j RETURN; then
    echo connbytes
  else
    echo connmark_out
  fi
}

# ---------------------------------------------------------------- firewall
# Цепочка-счётчик для исходящих пакетов одного соединения: пропускает в NFQUEUE первые LIM пакетов,
# дальше — RETURN без похода в userspace. Нужна, когда нет xt_connbytes: без неё КАЖДЫЙ пакет КАЖДОГО
# исходящего соединения на выбранных портах шёл бы в nfqws2 всю жизнь соединения (проверено по логам:
# одно длинное TCP-соединение прогнало через очередь 1281 пакет, 83% всего лога — пакеты "длинных"
# соединений, которым повторная обработка была не нужна). Эта цепочка ставится ТОЛЬКО на исходящее
# направление: исходящих пакетов на 1-2 порядка меньше, чем входящих (подтверждено логами), поэтому
# линейный перебор до 15 правил на пакет для них не создаёт заметной нагрузки — в отличие от версии
# 1.0.1/1.0.2, где такая же цепочка стояла и на входящем направлении и вызывала подвисания.
_fw_counter_chain() {   # $1 CMD  $2 имя цепочки  $3 маска  $4 шаг  $5 лимит (1..15)
  local CMD="$1" CH="$2" MASK="$3" STEP="$4" LIM="$5" k
  case "$LIM" in ''|*[!0-9]*) LIM=15 ;; esac
  [ "$LIM" -gt 15 ] && LIM=15
  [ "$LIM" -lt 1 ] && LIM=1
  $CMD -w -t mangle -N "$CH" 2>/dev/null
  $CMD -w -t mangle -F "$CH"
  $CMD -w -t mangle -A "$CH" -m connmark --mark $((LIM * STEP))/$MASK -j RETURN
  k=$((LIM - 1))
  while [ "$k" -ge 0 ]; do
    $CMD -w -t mangle -A "$CH" -m connmark --mark $((k * STEP))/$MASK -j CONNMARK --set-xmark $(((k + 1) * STEP))/$MASK
    k=$((k - 1))
  done
  $CMD -w -t mangle -A "$CH" -j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass
}

# Бюджет PKT_LIMIT_OUT тратится ОДИН РАЗ за всю жизнь соединения и никогда не возвращается: у
# долгоживущих keep-alive соединений (поиск, соцсети — именно то, что наблюдалось зависающим) он
# исчерпывается быстро, и дальше нечем противостоять DPI, которая может рвать поток не только на
# старте. Периодически (из watchdog) обнуляем счётчик вставкой и немедленным снятием одного
# временного правила в начало цепочки — это не трогает conntrack и не требует внешних утилит типа
# conntrack-tools, которых на телефоне обычно нет. Если цепочки нет (LIMITER=connbytes), команды
# просто ничего не найдут — безопасно подавлено.
refresh_connmark_counter() {
  iptables -w -t mangle -I $IPT_GROUP_QOUT 1 -j CONNMARK --set-xmark 0x0/$CNT_OUT_MASK 2>/dev/null
  iptables -w -t mangle -D $IPT_GROUP_QOUT 1 2>/dev/null
  if [ "$IPV6_ENABLED" = "1" ]; then
    ip6tables -w -t mangle -I $IPT_GROUP_QOUT 1 -j CONNMARK --set-xmark 0x0/$CNT_OUT_MASK 2>/dev/null
    ip6tables -w -t mangle -D $IPT_GROUP_QOUT 1 2>/dev/null
  fi
}

_fw_iface_rules() {
  # $1 CMD, $2 "-o IF" или "", $3 "-i IF" или ""
  local CMD="$1" OUT="$2" IN="$3"
  local JNFQ="-j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass"
  local CONN_CHECK="-m mark ! --mark $MARK_PROCESSED"
  local UP="$IPT_UDP_EFF" TP="$IPT_TCP_PORTS"
  local CB_OUT="" CB_IN="" LIM_OUT=""

  case "$LIMITER" in
    connbytes)
      CB_OUT="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_OUT"
      CB_IN="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_IN"
      ;;
    connmark_out)
      LIM_OUT="-j $IPT_GROUP_QOUT"
      ;;
  esac

  # --- POSTROUTING (исходящий: свой трафик, а также раздача Hotspot/USB-модем) ---
  if [ -n "$LIM_OUT" ]; then
    [ -n "$UP" ] && $CMD -w -t mangle -A $IPT_GROUP_POST $OUT $CONN_CHECK -p udp -m multiport --dports $UP $LIM_OUT
    [ -n "$TP" ] && $CMD -w -t mangle -A $IPT_GROUP_POST $OUT $CONN_CHECK -p tcp -m multiport --dports $TP $LIM_OUT
  else
    [ -n "$UP" ] && $CMD -w -t mangle -A $IPT_GROUP_POST $OUT $CONN_CHECK -p udp -m multiport --dports $UP $CB_OUT $JNFQ
    [ -n "$TP" ] && $CMD -w -t mangle -A $IPT_GROUP_POST $OUT $CONN_CHECK -p tcp -m multiport --dports $TP $CB_OUT $JNFQ
  fi
  if [ -n "$TP" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST $OUT $CONN_CHECK -p tcp -m multiport --dports $TP --tcp-flags fin fin $JNFQ
    $CMD -w -t mangle -A $IPT_GROUP_POST $OUT $CONN_CHECK -p tcp -m multiport --dports $TP --tcp-flags rst rst $JNFQ
  fi

  # --- NAT: фейковые UDP-пакеты клиентов раздачи должны пройти маскарад ---
  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -A $IPT_GROUP_NAT $OUT -m mark --mark $MARK_PROCESSED -p udp -j MASQUERADE
  fi

  # --- PREROUTING (входящий / ответы) ---
  # Минимальный перехват нужен ВСЕГДА, даже без connbytes: входящий поддельный RST/FIN — то, чем
  # DPI может оборвать уже идущее соединение ПОЗЖЕ, не только на старте (SYN,ACK — начало ответа,
  # тоже дёшево и редко). Именно это, по логам, резало отдельные долгие соединения (поиск, лента)
  # посреди работы — сам процесс жив, правила на месте, но конкретная сессия просто умирает и не
  # восстанавливается, пока не открыть новую (приложение переоткрыть). Эти несколько строк дешёвы
  # (управляющие пакеты редки, это не поток данных) и не создают той нагрузки, из-за которой полный
  # перехват входящего без connbytes отключён ниже.
  $CMD -w -t mangle -A $IPT_GROUP_PRE $IN -m mark --mark $MARK_PROCESSED -j RETURN
  if [ -n "$TP" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP --tcp-flags syn,ack syn,ack $JNFQ
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP --tcp-flags fin fin $JNFQ
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP --tcp-flags rst rst $JNFQ
  fi

  # Полный перехват ответного потока (не только управляющих пакетов) — только когда есть connbytes:
  # без него это на порядок объёмнее исходящего, и именно это лимитирование через линейный CONNMARK
  # вызывало циклические подвисания сети (версии 1.0.1/1.0.2). Часть техник, которым нужно видеть
  # весь ответ сервера, в этом режиме всё ещё не работает — ограничение ядра телефона, не модуля.
  [ "$LIMITER" = "connbytes" ] || return 0
  [ -n "$UP" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p udp -m multiport --sports $UP $CB_IN $JNFQ
  [ -n "$TP" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP $CB_IN $JNFQ
}

_firewall_start() {
  local CMD="$1" IF UID_ ex

  IPT_TCP_PORTS=$(printf '%s' "$TCP_PORTS" | tr '-' ':')
  IPT_UDP_EFF=$(printf '%s' "$UDP_PORTS" | tr '-' ':')
  [ "$BLOCK_QUIC" = "1" ] && IPT_UDP_EFF=$(port_list_without "$IPT_UDP_EFF" 443)

  LIMITER=$(detect_limiter "$CMD")
  [ "$CMD" = "iptables" ] && echo "$LIMITER" > "$STATE_DIR/$LIMITER_FILE_NAME" 2>/dev/null
  if [ "$LIMITER" = "connmark_out" ] && [ "$CMD" = "iptables" ]; then
    log_msg "Внимание: нет xt_connbytes — входящий поток не перехватывается (только RST/FIN/SYN,ACK); исходящий ограничен $PKT_LIMIT_OUT пак. на соединение (CONNMARK, сбрасывается раз в 30 сек)"
  fi

  $CMD -w -t mangle -N $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_POST
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done

  $CMD -w -t mangle -N $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done

  if [ "$LIMITER" = "connmark_out" ]; then
    _fw_counter_chain "$CMD" $IPT_GROUP_QOUT $CNT_OUT_MASK $CNT_OUT_STEP "$PKT_LIMIT_OUT"
  fi

  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -N $IPT_GROUP_NAT 2>/dev/null
    $CMD -w -t nat -F $IPT_GROUP_NAT
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
  fi

  # Виртуальные интерфейсы (VPN и т.п.) не трогаем: там уже зашифрованный или чужой трафик
  if [ -z "$ISP_INTERFACE" ]; then
    for ex in $IFACE_EXCLUDE; do
      $CMD -w -t mangle -A $IPT_GROUP_POST -o "$ex" -j RETURN
      $CMD -w -t mangle -A $IPT_GROUP_PRE -i "$ex" -j RETURN
    done
  fi

  # Выбор приложений по UID (аналог «политики доступа» Keenetic).
  # Решение сохраняется в connmark, чтобы ответы (PREROUTING, если есть) обрабатывались так же.
  if [ "$APP_MODE" = "include" ] || [ "$APP_MODE" = "exclude" ]; then
    if [ -n "$APP_UIDS" ] && has_ipt_feature "$CMD" -m owner --uid-owner 0 -j RETURN; then
      if [ "$APP_MODE" = "exclude" ]; then
        for UID_ in $APP_UIDS; do
          $CMD -w -t mangle -A $IPT_GROUP_POST -m owner --uid-owner "$UID_" -j CONNMARK --set-xmark $MARK_EXCLUDE
        done
      else
        for UID_ in $APP_UIDS; do
          $CMD -w -t mangle -A $IPT_GROUP_POST -m owner --uid-owner "$UID_" -j CONNMARK --set-xmark $MARK_INCLUDE
        done
        $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark ! --mark $MARK_INCLUDE -j CONNMARK --set-xmark $MARK_EXCLUDE
      fi
      $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark --mark $MARK_EXCLUDE -j RETURN
      $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark --mark $MARK_EXCLUDE -j RETURN
    else
      log_msg "Внимание: фильтр приложений не применён (пустой список или нет xt_owner)"
    fi
  fi

  # Принудительный откат QUIC -> TCP
  if [ "$BLOCK_QUIC" = "1" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST -p udp --dport 443 -j DROP
  fi

  if [ -n "$ISP_INTERFACE" ]; then
    for IF in $ISP_INTERFACE; do
      _fw_iface_rules "$CMD" "-o $IF" "-i $IF"
    done
  else
    _fw_iface_rules "$CMD" "" ""
  fi

  # Подключаем цепочки к системным только после полного заполнения
  $CMD -w -t mangle -I POSTROUTING 1 -j $IPT_GROUP_POST
  $CMD -w -t mangle -I PREROUTING 1 -j $IPT_GROUP_PRE
  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -I POSTROUTING 1 -j $IPT_GROUP_NAT
  fi
}

_firewall_stop() {
  local CMD="$1"
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done
  $CMD -w -t mangle -F $IPT_GROUP_POST 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_QOUT 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_QOUT 2>/dev/null
  if [ "$CMD" = "iptables" ]; then
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
    $CMD -w -t nat -F $IPT_GROUP_NAT 2>/dev/null; $CMD -w -t nat -X $IPT_GROUP_NAT 2>/dev/null
  fi
}

firewall_iptables()  { _firewall_start iptables; }
firewall_ip6tables() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start ip6tables; }

firewall_start() {
  APP_UIDS=""
  [ "$APP_MODE" = "off" ] || APP_UIDS=$(resolve_uids | sort -u | tr '\n' ' ')
  firewall_iptables
  firewall_ip6tables
}

firewall_stop() {
  _firewall_stop iptables
  _firewall_stop ip6tables
}

firewall_ok() {
  iptables -w -t mangle -C POSTROUTING -j $IPT_GROUP_POST 2>/dev/null
}

system_config() {
  # Conntrack
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1
  
  # Защита от переполнения сокетов NFQUEUE и сырых сокетов rawsend
  sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.rmem_default=2097152 >/dev/null 2>&1
  sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------- время работы
uptime_seconds() {
  is_running || { printf '0'; return; }
  [ -f "$STARTED_AT_FILE" ] || { printf '0'; return; }
  local st now
  st=$(cat "$STARTED_AT_FILE" 2>/dev/null)
  case "$st" in ''|*[!0-9]*) printf '0'; return ;; esac
  now=$(date +%s 2>/dev/null)
  [ "$now" -ge "$st" ] 2>/dev/null && printf '%s' $((now - st)) || printf '0'
}

# ---------------------------------------------------------------- проверка связи и автооткат
# Быстрая проверка интернета: TCP-подключение к паре публичных адресов на 443 порт.
# Не зависит от DNS (используются голые IP) и не зависит от того, что именно ломает
# конкретная стратегия — только от того, есть соединение или нет.
probe_net() {
  local h
  if command -v curl >/dev/null 2>&1; then
    for h in 1.1.1.1 8.8.8.8 9.9.9.9; do
      curl -s -k -m 4 --connect-timeout 3 -o /dev/null "https://$h/" 2>/dev/null && return 0
    done
    return 1
  fi
  if command -v nc >/dev/null 2>&1; then
    for h in 1.1.1.1 8.8.8.8 9.9.9.9; do
      if command -v timeout >/dev/null 2>&1; then
        timeout 5 nc -w 3 "$h" 443 </dev/null >/dev/null 2>&1 && return 0
      else
        nc -w 3 "$h" 443 </dev/null >/dev/null 2>&1 && return 0
      fi
    done
    return 1
  fi
  return 2   # нечем проверить (нет curl и nc) — вызывающий код должен считать это "неизвестно"
}

# Многие готовые стратегии (переносы из Windows-бандлов winws1, flowseal и т.п.) ссылаются на свои
# .bin-блобы через --blob=имя:@путь, которых нет в нашем комплекте blobs/. nfqws2 в этом случае
# не стартует вовсе ("cannot access file ..."), а сообщение об этом тонет в хвосте лога. Проверяем
# заранее и называем ровно те файлы, которых не хватает, вместо общей "не запустился, смотри лог".
check_blobs_exist() {   # $1 - собранная строка аргументов
  local missing="" path
  set -f
  for path in $(printf '%s\n' "$1" | grep -o -- '--blob=[^: ]*:@[^[:space:]]*' | sed 's/^[^@]*@//'); do
    [ -f "$path" ] || missing="$missing $path"
  done
  set +f
  printf '%s' "${missing# }"
}

# Ждём, пока nfqws2 реально привяжется к очереди NFQUEUE (а не просто останется процессом).
wait_queue_bound() {
  [ -e /proc/net/netfilter/nfnetlink_queue ] || return 0   # нечем проверить — не блокируем запуск
  local i=0
  while [ "$i" -lt 6 ]; do
    grep -q "^[[:space:]]*$NFQUEUE_NUM[[:space:]]" /proc/net/netfilter/nfnetlink_queue 2>/dev/null && return 0
    is_running || return 1
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Проверка связи до/после применения правил. Вызывается из service.sh после firewall_start.
# При потере связи откатывает всё (останавливает nfqws2 и снимает правила) и подробно логирует,
# какой режим был активен и какие именно аргументы запускались — чтобы было видно, что менять.
safe_start_check() {
  [ "$SAFE_START" = "1" ] || return 0
  local before after
  probe_net; before=$?
  [ "$before" -eq 2 ] && { log_msg "safe_start: нет curl/nc — проверка связи пропущена"; return 0; }
  if [ "$before" -ne 0 ]; then
    log_msg "safe_start: связи не было ещё ДО запуска — пропускаю автооткат (не с чем сравнивать)"
    return 0
  fi
  sleep 2
  probe_net; after=$?
  if [ "$after" -eq 0 ]; then
    log_msg "safe_start: связь после запуска в порядке"
    return 0
  fi
  sleep 3
  probe_net; after=$?
  [ "$after" -eq 0 ] && { log_msg "safe_start: связь восстановилась после короткой задержки"; return 0; }

  log_msg "safe_start: ОТКАТ — после включения правил пропала связь (до запуска она была)"
  log_msg "safe_start: активная конфигурация — режим: $(current_mode_hint)"
  {
    echo "===== nfqws2-magisk safe_start rollback $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) ====="
    echo "mode=$(current_mode_hint) limiter=$(cat "$STATE_DIR/$LIMITER_FILE_NAME" 2>/dev/null)"
    echo "--- last.args ---"; cat "$ARGS_FILE" 2>/dev/null
    echo "--- nfqws2.log (tail) ---"; tail -n 30 "$NFQWS_LOG" 2>/dev/null
  } > "$LOG_DIR/rollback-diag.txt" 2>/dev/null
  return 1
}

current_mode_hint() {
  grep -m1 '^NFQWS_EXTRA_ARGS=' "$CONFFILE" 2>/dev/null | grep -o 'MODE_[A-Z]*' | head -n1
}

# ---------------------------------------------------------------- импорт конфигов пачками
# Файл считается конфигом nfqws2-keenetic, если в нём есть минимум 2 ключевых переменной.
is_keenetic_config() {
  local f="$1" n
  [ -f "$f" ] || return 1
  n=$(grep -cE '^[[:space:]]*(NFQWS_BASE_ARGS|NFQWS_ARGS|NFQWS_ARGS_QUIC|NFQWS_ARGS_UDP|NFQWS_EXTRA_ARGS|NFQWS_ARGS_IPSET|ISP_INTERFACE|TCP_PORTS)=' "$f" 2>/dev/null)
  [ "${n:-0}" -ge 2 ]
}

import_safe_name() {
  # Чёрный список вместо белого: убираем только то, что реально опасно для пути/shell
  # (/ как разделитель каталогов, кавычки, обратный слэш, $ и обратные кавычки), а не весь
  # не-ASCII — иначе кириллица и любой другой unicode превращались бы в подчёркивания.
  # Байты '/','\','`','$','"',''' всегда однобайтовые (< 0x80) и не входят в UTF-8-продолжения,
  # поэтому их можно безопасно вырезать побайтово, не трогая многобайтовые символы.
  printf '%s' "$1" | tr -d '/\\`$"'"'" | tr -d '\n\r\t' | sed -e 's/^[[:space:].]*//' -e 's/[[:space:]]*$//' | cut -c1-200
}

list_imports() {
  local f
  for f in "$IMPORTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf
  done | sort
}

# Готовит содержимое импортированного файла к ПРЕДПРОСМОТРУ в редакторе: тот же перенос путей
# и та же чистка переменных Keenetic, что и раньше при импорте, но НИЧЕГО не сохраняет — исходный
# файл в imports/ остаётся как есть, чтобы Настройки Android можно было поменять один раз и они
# были одинаковы на всех конфигах, а не "заморожены" на момент импорта каждого из них.
render_import_merged() {
  local src="$1" out="$STATE_DIR/import_preview.$$"
  [ -f "$src" ] || return 1

  awk '
    function is_drop(k) { return k == "ISP_INTERFACE" || k == "USER" || k == "POLICY_NAME" || k == "POLICY_EXCLUDE" || k == "LOG_DEBUG_PATH" }
    function flush_pend(   i) { for (i = 1; i <= np; i++) print pend[i]; np = 0 }
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    {
      line = $0
      if (inval) {
        if (!dropping) print line
        if (quotes(line) % 2 == 1) inval = 0
        next
      }
      if (line ~ /^[ \t]*#/) { pend[++np] = line; next }
      if (line ~ /^[ \t]*$/) {
        if (dropping_pending) { np = 0; dropping_pending = 0 }
        flush_pend(); print line; next
      }
      if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        key = substr(line, 1, RLENGTH - 1)
        dropping = is_drop(key)
        if (dropping) { np = 0 } else { flush_pend(); print line }
        if (quotes(line) % 2 == 1) inval = 1
        next
      }
      flush_pend(); print line
    }
    END { flush_pend() }' "$src" \
  | tr -d '\r' \
  | sed -e 's#/opt/etc/nfqws2/lua#$LUA_DIR#g' -e 's#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g' \
        -e 's#/opt/etc/nfqws2/lists#$LISTS_DIR#g' -e 's#/opt/etc/nfqws2#$CONFDIR#g' \
        -e 's#/opt/var/log#$LOG_DIR#g' > "$out"

  local have
  have=$(grep -o '^[A-Za-z_][A-Za-z0-9_]*=' "$out" | tr -d '=' | sort -u | tr '\n' ' ')
  {
    echo
    echo "# ---- Настройки Android (текущие, подставлены при выборе конфига) ----"
    awk -v have=" $have " '
      function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
      {
        if (inval) { if (keep) print; if (quotes($0) % 2 == 1) inval = 0; next }
        if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
          key = substr($0, 1, RLENGTH - 1)
          keep = (index(have, " " key " ") == 0)
          if (keep) print
          if (quotes($0) % 2 == 1) inval = 1
        }
      }' "$CONFFILE"
  } >> "$out"

  cat "$out"
  rm -f "$out"
}
