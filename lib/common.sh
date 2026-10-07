#!/system/bin/sh
[ -n "$MODDIR" ] || { echo "MODDIR is not set" >&2; return 1 2>/dev/null || exit 1; }

: "${CONFDIR:=/data/adb/nfqws2}"
CONFFILE="$CONFDIR/nfqws2.conf"
LISTS_DIR="$CONFDIR/lists"
STATE_DIR="$CONFDIR/state"
LOG_DIR="$CONFDIR/logs"
STRATEGIES_DIR="$MODDIR/strategies"
USER_STRATEGIES_DIR="$CONFDIR/strategies"
IMPORTS_DIR="$CONFDIR/imports"

LUA_DIR="$MODDIR/lua"
BLOBS_DIR="$MODDIR/blobs"
NFQWS_BIN="$MODDIR/bin/nfqws2"

PIDFILE="$STATE_DIR/nfqws2.pid"
WD_PIDFILE="$STATE_DIR/watchdog.pid"
WN_PIDFILE="$STATE_DIR/netwatch.pid"
DESIRED_FILE="$STATE_DIR/desired"
ARGS_FILE="$STATE_DIR/last.args"
APP_UIDS_FILE="$STATE_DIR/app_uids"
SERVICE_LOG="$LOG_DIR/service.log"
NFQWS_LOG="$LOG_DIR/nfqws2.log"
ACTIVE_FILE="$STATE_DIR/active_strategy"

# Списки, поставленные релизом: .pending — новая версия, которую установщик
# не стал класть поверх правок пользователя (WebUI предлагает заменить её вручную).
LISTS_PENDING_DIR="$LISTS_DIR/.pending"

# Домашняя Wi-Fi: в этих сетях обход ставится на паузу (HOME_WIFI=1)
HOME_FILE="$CONFDIR/home_wifi.list"
HOME_PAUSED_FILE="$STATE_DIR/home_paused"      # служба остановлена из-за домашней сети, в файле — её SSID
HOME_OVERRIDE_FILE="$STATE_DIR/home_override"  # пользователь включил службу вручную в этой сети

MARK_EXCLUDE="0x20000000/0x20000000"
MARK_INCLUDE="0x10000000/0x10000000"
MARK_PROCESSED="0x40000000/0x40000000"

IPT_GROUP_POST="nfqws_post"
IPT_GROUP_PRE="nfqws_pre"
IPT_GROUP_NAT="nfqws_nat"
IPT_GROUP_QOUT="nfqws_qout"
IPT_GROUP_QIN="nfqws_qin"    # то же, что QOUT, но для входящих, когда нет connbytes
IPT_GROUP_APP="nfqws_app"

# xt_owner принимает не более 128 диапазонов в одном правиле
APP_UID_MAX=128

CNT_OUT_MASK=0x0f000000
CNT_OUT_STEP=16777216
CNT_IN_MASK=0x000f0000   # биты 16-19: отдельно от исходящего счётчика (24-27) и MARK_* (28-30)
CNT_IN_STEP=65536        # 1<<16

mkdir -p "$LISTS_DIR" "$STATE_DIR" "$LOG_DIR" "$USER_STRATEGIES_DIR" 2>/dev/null

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
  : "${STRATEGY_TLS:=auto}"
  : "${STRATEGY_UDP:=auto}"
  : "${APP_MODE:=off}"
  : "${LOG_MAX_KB:=512}"
  : "${PKT_LIMIT_OUT:=15}"
  : "${PKT_LIMIT_IN:=15}"
  : "${WAKELOCK:=0}"
  : "${HOME_WIFI:=0}"
}

log_msg() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)] $*"
  echo "$line"
  echo "$line" >> "$SERVICE_LOG" 2>/dev/null
}

sync_lists_and_blobs() {
  mkdir -p "$LISTS_DIR" "$CONFDIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null

  for sdir in "$MODDIR/lists" "$MODDIR/defaults/lists"; do
    if [ -d "$sdir" ]; then
      for f in "$sdir"/*; do
        [ -f "$f" ] || continue
        local bname="${f##*/}"
        [ -f "$LISTS_DIR/$bname" ] || cp -f "$f" "$LISTS_DIR/$bname"
      done
    fi
  done

  for l in google youtube user_extra ipset_as ipset_do ipset_cf_full ipset_amazon ipset_ovh; do
    if [ ! -f "$LISTS_DIR/$l.list" ]; then
      case "$l" in
        google)
          printf 'google.com\ngooglevideo.com\nyoutube.com\nytimg.com\nggpht.com\ngoogleapis.com\ngvt1.com\n' > "$LISTS_DIR/google.list" ;;
        youtube)
          printf 'youtube.com\nyoutu.be\ngooglevideo.com\nytimg.com\nggpht.com\n' > "$LISTS_DIR/youtube.list" ;;
        user_extra)
          # Явный if, а не `[ -f ] && cp || touch`: при падении cp выполнился бы
          # touch, и на месте копии остался бы пустой список. Так ошибка видна,
          # а посев повторится при следующем запуске.
          if [ -f "$LISTS_DIR/user.list" ]; then
            cp -f "$LISTS_DIR/user.list" "$LISTS_DIR/user_extra.list"
          else
            touch "$LISTS_DIR/user_extra.list"
          fi ;;
        *)
          touch "$LISTS_DIR/$l.list" ;;
      esac
      chmod 0644 "$LISTS_DIR/$l.list" 2>/dev/null
    fi
  done

  if [ -d "$BLOBS_DIR" ]; then
    [ -f "$BLOBS_DIR/quic_initial_www_google_com.bin" ] || [ ! -f "$BLOBS_DIR/quic_initial.bin" ] || ln -sf "$BLOBS_DIR/quic_initial.bin" "$BLOBS_DIR/quic_initial_www_google_com.bin"
    [ -f "$BLOBS_DIR/tls_clienthello_www_google_com.bin" ] || [ ! -f "$BLOBS_DIR/tls_clienthello.bin" ] || ln -sf "$BLOBS_DIR/tls_clienthello.bin" "$BLOBS_DIR/tls_clienthello_www_google_com.bin"
    [ -f "$BLOBS_DIR/tls_clienthello_max_ru.bin" ] || [ ! -f "$BLOBS_DIR/tls_clienthello.bin" ] || ln -sf "$BLOBS_DIR/tls_clienthello.bin" "$BLOBS_DIR/tls_clienthello_max_ru.bin"
    [ -f "$BLOBS_DIR/tls_clienthello_sochi_park.bin" ] || [ ! -f "$BLOBS_DIR/tls_clienthello.bin" ] || ln -sf "$BLOBS_DIR/tls_clienthello.bin" "$BLOBS_DIR/tls_clienthello_sochi_park.bin"
    [ -f "$BLOBS_DIR/stun2.bin" ] || [ ! -f "$BLOBS_DIR/stun.bin" ] || ln -sf "$BLOBS_DIR/stun.bin" "$BLOBS_DIR/stun2.bin"
    [ -f "$BLOBS_DIR/stun.bin" ] || [ ! -f "$BLOBS_DIR/stun2.bin" ] || ln -sf "$BLOBS_DIR/stun2.bin" "$BLOBS_DIR/stun.bin"
    [ -f "$BLOBS_DIR/ACTIVE_DISCORD_UDP.bin" ] || [ ! -f "$BLOBS_DIR/discord_udp.bin" ] || ln -sf "$BLOBS_DIR/discord_udp.bin" "$BLOBS_DIR/ACTIVE_DISCORD_UDP.bin"
    [ -f "$BLOBS_DIR/discord_udp.bin" ] || [ ! -f "$BLOBS_DIR/ACTIVE_DISCORD_UDP.bin" ] || ln -sf "$BLOBS_DIR/ACTIVE_DISCORD_UDP.bin" "$BLOBS_DIR/discord_udp.bin"
    [ -f "$BLOBS_DIR/ACTIVE_GAME_UDP.bin" ] || [ ! -f "$BLOBS_DIR/ACTIVE_DISCORD_UDP.bin" ] || ln -sf "$BLOBS_DIR/ACTIVE_DISCORD_UDP.bin" "$BLOBS_DIR/ACTIVE_GAME_UDP.bin"
    for qb in 5ka_ru vk_com steamcommunity_com 4pda_to dbankcloud_ru my_youtube; do
      [ -f "$BLOBS_DIR/quic_initial_${qb}.bin" ] || [ ! -f "$BLOBS_DIR/quic_initial.bin" ] || ln -sf "$BLOBS_DIR/quic_initial.bin" "$BLOBS_DIR/quic_initial_${qb}.bin"
    done
  fi
}

rotate_file() {
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null)
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$sz" -gt "$max" ] || return 0
  tail -c $((max / 2)) "$f" > "$f.tmp" 2>/dev/null && cat "$f.tmp" > "$f" 2>/dev/null
  rm -f "$f.tmp"
}

rotate_logs() {
  local max=$(( ${LOG_MAX_KB:-512} * 1024 )) f
  for f in "$SERVICE_LOG" "$NFQWS_LOG" "$LOG_DIR/auto.log"; do rotate_file "$f" "$max"; done
  if [ "$1" = "start" ]; then
    f="$LOG_DIR/nfqws2-debug.log"
    # То же самое: при неудачном обнулении `&& … ||` запустил бы ротацию вместо
    # него. С включённой отладкой лог начинается заново, с выключенной — ротируется.
    if [ "$LOG_LEVEL" = "1" ]; then
      : > "$f" 2>/dev/null
    else
      rotate_file "$f" "$max"
    fi
  fi
}

validate_conf() {
  awk '
    BEGIN { ok = 1 }
    /`/ { printf "line %d: backtick is forbidden\n", NR; ok = 0 }
    /\$\(/ { printf "line %d: $( is forbidden\n", NR; ok = 0 }
    END { exit ok ? 0 : 1 }
  ' "$1"
}

load_conf() {
  sync_lists_and_blobs
  if [ ! -f "$CONFFILE" ]; then
    cp -f "$MODDIR/defaults/nfqws2.conf" "$CONFFILE" 2>/dev/null
  fi
  local err
  err=$(validate_conf "$CONFFILE" 2>&1) || {
    log_msg "Конфиг $CONFFILE содержит ошибки: $err"
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

# Перезапись keenetic-путей на каталоги этого модуля. Раньше это правило
# копировалось трижды (norm_args, set_strategy, render_import_merged) и успело
# разойтись по кавычкам: две копии раскрывали переменные, третья — писала
# ссылкой, и по коду это различие видно не было.
#
# Порядок подстановок важен: частные пути (/opt/etc/nfqws2/lua, /blobs, /lists)
# обязаны идти раньше общего /opt/etc/nfqws2, иначе они подменяются общим
# правилом и превращаются в $CONFDIR/lua.
#
#   без аргумента  — подставить реальные пути: так нужно в командную строку
#                    бинарника;
#   аргумент "refs" — записать ссылками $LUA_DIR/$BLOBS_DIR/... : так нужно в
#                     конфиг, который модуль потом сорсит (именно в такой форме
#                     пути записаны в defaults/nfqws2.conf и в стратегиях).
rewrite_keenetic_paths() {
  if [ "$1" = "refs" ]; then
    sed -e 's#/opt/etc/nfqws2/lua#$LUA_DIR#g' \
        -e 's#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g' \
        -e 's#/opt/etc/nfqws2/lists#$LISTS_DIR#g' \
        -e 's#/opt/etc/nfqws2#$CONFDIR#g' \
        -e 's#/opt/var/log#$LOG_DIR#g'
  else
    sed -e "s#/opt/etc/nfqws2/lua#$LUA_DIR#g" \
        -e "s#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g" \
        -e "s#/opt/etc/nfqws2/lists#$LISTS_DIR#g" \
        -e "s#/opt/etc/nfqws2#$CONFDIR#g" \
        -e "s#/opt/var/log#$LOG_DIR#g"
  fi
}

norm_args() {
  printf '%s\n' "$1" \
    | sed -e 's/^[[:space:]]*#.*$//' -e 's/\\//g' \
    | awk '{ for (i=1; i<=NF; i++) printf "%s ", $i } END { print "" }' \
    | rewrite_keenetic_paths \
    | sed -e 's/  */ /g; s/^ //; s/ $//'
}

apply_strategy() {
  local args="$1" n="$2"
  case "$n" in ''|auto|AUTO|0) printf '%s' "$args"; return ;; esac
  set -f
  printf '%s\n' $args | awk -v n="$n" '
    /^--lua-desync=circular/ { next }
    /^--lua-desync=/ {
      if (match($0, /:strategy=[0-9]+/)) {
        s = substr($0, RSTART + 10, RLENGTH - 10)
        if (s != n) next
        $0 = substr($0, 1, RSTART - 1) substr($0, RSTART + RLENGTH)
      }
    }
    { printf "%s ", $0 }' | sed 's/ $//'
  set +f
}

app_mode_active() {
  case "$APP_MODE" in include|exclude) return 0 ;; *) return 1 ;; esac
}

# apps.list (имена пакетов) -> список UID из pm
resolve_app_uids() {
  local f="$CONFDIR/apps.list" pkgs PM=pm
  [ -f "$f" ] || return 0
  # WebUI/root-шелл не всегда имеет /system/bin в PATH
  command -v pm >/dev/null 2>&1 || PM=/system/bin/pm
  command -v "$PM" >/dev/null 2>&1 || return 0
  pkgs=$(grep -hv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$f" 2>/dev/null | tr -d '\r\t ' | tr 'A-Z' 'a-z')
  [ -n "$pkgs" ] || return 0
  "$PM" list packages -U 2>/dev/null | awk -v want="$pkgs" '
    BEGIN { n = split(want, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
    $1 ~ /^package:/ {
      p = substr($1, 9); u = $2; sub(/^uid:/, "", u)
      if ((p in w) && u ~ /^[0-9]+$/) print u
    }' | sort -n -u | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $0 }'
}

app_features_ok() {
  has_ipt_feature "$1" -m owner --uid-owner 0 -j RETURN &&
  has_ipt_feature "$1" -m connmark --mark 0x1/0x1 -j RETURN &&
  has_ipt_feature "$1" -j CONNMARK --set-xmark 0x1/0x1
}

app_uid_count() {
  local n
  [ -f "$APP_UIDS_FILE" ] || { printf 0; return; }
  n=$(tr ',' '\n' < "$APP_UIDS_FILE" 2>/dev/null | grep -cE '^[0-9]+$')
  printf '%s' "${n:-0}"
}

# Возвращает 0, если фильтр по приложениям установлен, 1 — если выключен/неприменим, 2 — с ошибкой
app_rules() {
  local CMD="$1" uids n chunk mark
  if ! app_mode_active; then
    $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null
    $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
    rm -f "$APP_UIDS_FILE"
    return 1
  fi
  if ! app_features_ok "$CMD"; then
    [ "$CMD" = "iptables" ] && log_msg "Нет xt_owner/xt_CONNMARK — фильтр по приложениям не применяется"
    return 2
  fi
  uids=$(resolve_app_uids)
  n=$(printf '%s\n' "$uids" | tr ',' '\n' | grep -cE '^[0-9]+$')
  if [ "$CMD" = "iptables" ]; then
    printf '%s\n' "$uids" > "$APP_UIDS_FILE"
    n=$(app_uid_count)
  fi
  if [ "$n" = "0" ]; then
    log_msg "apps.list: ни один пакет не сопоставлен с UID — фильтр по приложениям ($APP_MODE) не действует"
    return 2
  fi

  # В PREROUTING у пакета нет сокета, поэтому -m owner там не работает:
  # решение по UID принимается в POSTROUTING, а для ответных пакетов используется метка соединения.
  mark="$MARK_INCLUDE"
  [ "$APP_MODE" = "exclude" ] && mark="$MARK_EXCLUDE"
  $CMD -w -t mangle -N $IPT_GROUP_APP 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_APP
  printf '%s\n' "$uids" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n -u | awk -v mx="$APP_UID_MAX" '
      { b = int((NR - 1) / mx); a[b] = (b in a ? a[b] "," $0 : $0) }
      END { for (i = 0; i <= b; i++) if (i in a) print a[i] }' | while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    $CMD -w -t mangle -A $IPT_GROUP_APP -m owner --uid-owner "$chunk" -j CONNMARK --set-xmark "$mark"
  done
  $CMD -w -t mangle -A $IPT_GROUP_POST -j $IPT_GROUP_APP
  if [ "$APP_MODE" = "exclude" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark --mark "$MARK_EXCLUDE" -j RETURN
    [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark --mark "$MARK_EXCLUDE" -j RETURN
  else
    $CMD -w -t mangle -A $IPT_GROUP_POST -m connmark ! --mark "$MARK_INCLUDE" -j RETURN
    [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -m connmark ! --mark "$MARK_INCLUDE" -j RETURN
  fi
  log_msg "Фильтр по приложениям ($APP_MODE): $n UID"
  return 0
}

port_list_without() {
  printf ',%s,' "$1" | sed "s/,$2,/,/g; s/^,//; s/,\$//"
}

_startup_args() {
  local base tcp quic udp extra custom ipset
  base=$(norm_args "$NFQWS_BASE_ARGS")
  tcp=$(norm_args "$NFQWS_ARGS")
  tcp=$(apply_strategy "$tcp" "$STRATEGY_TLS")
  quic=$(norm_args "$NFQWS_ARGS_QUIC")
  udp=$(apply_strategy "$(norm_args "$NFQWS_ARGS_UDP")" "$STRATEGY_UDP")
  extra=$(norm_args "$NFQWS_EXTRA_ARGS")
  custom=$(norm_args "$NFQWS_ARGS_CUSTOM")
  ipset=""
  if [ -n "$NFQWS_ARGS_IPSET" ] && [ "$(list_count "$LISTS_DIR/ipset.list")" -gt 0 ]; then
    ipset=$(norm_args "$NFQWS_ARGS_IPSET")
  fi

  local args="--user=$NFQWS_USER --qnum=$NFQUEUE_NUM"

  if [ -n "$ISP_INTERFACE" ] && [ "$(echo $ISP_INTERFACE | wc -w)" -gt 1 ]; then
    args="$args --bind-fix4"
    [ "$IPV6_ENABLED" != "0" ] && args="$args --bind-fix6"
  fi

  if [ "$LOG_LEVEL" = "1" ]; then
    args="--debug=@$LOG_DIR/nfqws2-debug.log $args"
  else
    args="--debug=@$NFQWS_LOG $args"
  fi

  args="$args $base"
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

kernel_modules() {
  command -v modprobe >/dev/null 2>&1 || return 0
  modprobe -a -q nfnetlink_queue xt_multiport xt_connbytes xt_NFQUEUE xt_CONNMARK xt_connmark xt_owner nf_conntrack 2>/dev/null
  return 0
}

has_ipt_feature() {
  ipt_probe "$@" >/dev/null 2>&1
}

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

detect_limiter() {
  local C="${1:-iptables}"
  if has_ipt_feature $C -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:15 -j RETURN; then
    echo connbytes
  else
    echo connmark_out
  fi
}

_fw_counter_chain() {
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

_fw_add_rule() {
  # $1: CMD, $2: CHAIN, $3: IFSPEC (-o / -i), $4: proto (tcp/udp), $5: dir (dports/sports), $6: ports, $7: extra flags, $8: target
  local CMD="$1" CH="$2" IFSPEC="$3" PROTO="$4" DIR="$5" PORTS="$6" EXTRA="$7" TARGET="$8"
  [ -z "$PORTS" ] && return 0

  local applied=0
  if [ "$HAS_MULTIPORT" = "1" ]; then
    if $CMD -w -t mangle -A "$CH" $IFSPEC -p "$PROTO" -m multiport "--$DIR" "$PORTS" $EXTRA $TARGET 2>/dev/null; then
      applied=1
    fi
  fi

  if [ "$applied" = "0" ]; then
    local sdir p
    if [ "$DIR" = "dports" ]; then
      sdir="--dport"
    else
      sdir="--sport"
    fi
    for p in $(printf '%s' "$PORTS" | tr ',' ' '); do
      $CMD -w -t mangle -A "$CH" $IFSPEC -p "$PROTO" $sdir "$p" $EXTRA $TARGET 2>/dev/null
    done
  fi
}

_fw_iface_rules() {
  local CMD="$1" OUT="$2" IN="$3"
  local JNFQ="-j NFQUEUE --queue-num $NFQUEUE_NUM --queue-bypass"
  local UP="$IPT_UDP_EFF" TP="$IPT_TCP_PORTS"
  local CB_OUT="" CB_IN="" LIM_OUT="" LIM_IN=""
  local TARGET_OUT TARGET_IN

  case "$LIMITER" in
    connbytes)
      CB_OUT="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_OUT"
      CB_IN="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:$PKT_LIMIT_IN"
      TARGET_OUT="$CB_OUT $JNFQ"
      TARGET_IN="$CB_IN $JNFQ"
      ;;
    connmark_out)
      LIM_OUT="-j $IPT_GROUP_QOUT"
      LIM_IN="-j $IPT_GROUP_QIN"
      TARGET_OUT="$LIM_OUT"
      TARGET_IN="$LIM_IN"
      ;;
  esac

  # Пакеты, уже обработанные nfqws2 (маркированные MARK_PROCESSED),
  # не должны повторно отправляться в очередь ни на выходе, ни на входе
  $CMD -w -t mangle -A $IPT_GROUP_POST $OUT -m mark --mark $MARK_PROCESSED -j RETURN
  $CMD -w -t mangle -A $IPT_GROUP_PRE $IN -m mark --mark $MARK_PROCESSED -j RETURN

  # Исходящий трафик (POSTROUTING)
  [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" udp dports "$UP" "" "$TARGET_OUT"
  [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "" "$TARGET_OUT"

  # Завершение TCP-сессий (FIN/RST) отправляем в nfqws для корректного conntrack
  if [ -n "$TP" ]; then
    _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags fin fin" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_POST "$OUT" tcp dports "$TP" "--tcp-flags rst rst" "$JNFQ"
  fi

  # NAT fix для UDP
  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -A $IPT_GROUP_NAT $OUT -p udp -m mark --mark $MARK_PROCESSED -j MASQUERADE
  fi

  # Входящий трафик (PREROUTING)
  if [ -n "$TP" ]; then
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags syn,ack syn,ack" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags fin fin" "$JNFQ"
    _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "--tcp-flags rst rst" "$JNFQ"
  fi

  # Входящий поток данных (connbytes или connmark_in)
  [ -n "$UP" ] && _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" udp sports "$UP" "" "$TARGET_IN"
  [ -n "$TP" ] && _fw_add_rule "$CMD" $IPT_GROUP_PRE "$IN" tcp sports "$TP" "" "$TARGET_IN"
}

_firewall_start() {
  local CMD="$1" IF ex

  IPT_TCP_PORTS=$(printf '%s' "$TCP_PORTS" | tr '-' ':')
  IPT_UDP_EFF=$(printf '%s' "$UDP_PORTS" | tr '-' ':')
  [ "$BLOCK_QUIC" = "1" ] && IPT_UDP_EFF=$(port_list_without "$IPT_UDP_EFF" 443)

  LIMITER=$(detect_limiter "$CMD")
  [ "$CMD" = "iptables" ] && echo "$LIMITER" > "$STATE_DIR/limiter" 2>/dev/null

  HAS_MULTIPORT=0
  has_ipt_feature $CMD -p tcp -m multiport --dports 80,443 -j RETURN && HAS_MULTIPORT=1

  $CMD -w -t mangle -N $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_POST
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done

  $CMD -w -t mangle -N $IPT_GROUP_PRE 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_PRE
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done

  if [ "$LIMITER" = "connmark_out" ]; then
    _fw_counter_chain "$CMD" $IPT_GROUP_QOUT $CNT_OUT_MASK $CNT_OUT_STEP "$PKT_LIMIT_OUT"
    _fw_counter_chain "$CMD" $IPT_GROUP_QIN $CNT_IN_MASK $CNT_IN_STEP "$PKT_LIMIT_IN"
  fi

  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -N $IPT_GROUP_NAT 2>/dev/null
    $CMD -w -t nat -F $IPT_GROUP_NAT
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
  fi

  if [ -z "$ISP_INTERFACE" ]; then
    for ex in $IFACE_EXCLUDE; do
      $CMD -w -t mangle -A $IPT_GROUP_POST -o "$ex" -j RETURN
      $CMD -w -t mangle -A $IPT_GROUP_PRE -i "$ex" -j RETURN
    done
  fi

  app_rules "$CMD"

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
  $CMD -w -t mangle -F $IPT_GROUP_QIN 2>/dev/null;  $CMD -w -t mangle -X $IPT_GROUP_QIN 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
  if [ "$CMD" = "iptables" ]; then
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
    $CMD -w -t nat -F $IPT_GROUP_NAT 2>/dev/null; $CMD -w -t nat -X $IPT_GROUP_NAT 2>/dev/null
  fi
}

firewall_iptables()  { _firewall_start iptables; }
firewall_ip6tables() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start ip6tables; }

# Статус обеих половин, а не только последней. firewall_ip6tables() при
# выключенном IPv6 возвращает 0 безусловно, поэтому провал iptables в ней тонул:
# функция рапортовала успех, когда правила IPv4 не встали.
firewall_start() {
  local rc=0
  firewall_iptables || rc=1
  firewall_ip6tables || rc=1
  return $rc
}

firewall_stop() {
  local rc=0
  _firewall_stop iptables || rc=1
  _firewall_stop ip6tables || rc=1
  return $rc
}

firewall_ok() {
  iptables -w -t mangle -C POSTROUTING -j $IPT_GROUP_POST 2>/dev/null || return 1
  iptables -w -t mangle -S $IPT_GROUP_POST 2>/dev/null | grep -qE -- 'NFQUEUE|nfqws_qout'
}

# Бюджет PKT_LIMIT_OUT/IN тратится один раз за всю жизнь соединения и никогда не возвращается:
# у долгоживущих keep-alive соединений он кончается быстро, и дальше DPI уже нечем перехватывать.
# Раз в тик watchdog обнуляем оба счётчика вставкой и немедленным снятием одного временного
# правила. Снимаем по спецификации, а не «правилом номер 1», чтобы не удалить чужое правило,
# вставленное в цепочку параллельным firewall_start. Если цепочек нет (LIMITER=connbytes),
# команды просто ничего не найдут.
refresh_connmark_counter() {
  local spec
  for spec in "$IPT_GROUP_QOUT $CNT_OUT_MASK" "$IPT_GROUP_QIN $CNT_IN_MASK"; do
    set -- $spec
    iptables  -w -t mangle -I "$1" 1 -j CONNMARK --set-xmark "0x0/$2" 2>/dev/null && \
    iptables  -w -t mangle -D "$1"     -j CONNMARK --set-xmark "0x0/$2" 2>/dev/null
    if [ "$IPV6_ENABLED" != "0" ]; then
      ip6tables -w -t mangle -I "$1" 1 -j CONNMARK --set-xmark "0x0/$2" 2>/dev/null && \
      ip6tables -w -t mangle -D "$1"     -j CONNMARK --set-xmark "0x0/$2" 2>/dev/null
    fi
  done
  return 0
}

# На части Android-прошивок (особенно с агрессивным энергосбережением) корневой процесс модуля
# создаётся в cgroup вызвавшего root-доступ приложения и попадает под заморозку фоновых процессов
# вместе с ним. Переносим в корневую cgroup верхнего уровня (cgroup v2) — её не замораживают.
# Всё best-effort: если недоступно, просто не срабатывает. Проверка -w перед записью нужна
# потому, что в dash ошибка ОТКРЫТИЯ файла для записи уходит в stderr раньше, чем применяется
# редирект самой команды, и «2>/dev/null» после > её не подавляет.
protect_process() {   # $1 - PID; по умолчанию текущий процесс
  local p="${1:-$$}"
  [ -w "/proc/$p/oom_score_adj" ] 2>/dev/null && echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null
  [ -w /sys/fs/cgroup/cgroup.procs ] 2>/dev/null && echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
  return 0
}

# Партиционный wakelock держит CPU от глубокого сна, пока служба запущена. Это НЕ бесплатно —
# заметно повышает расход батареи, особенно ночью, когда телефон иначе спал бы. Включается
# только явно (WAKELOCK=1) — это эксперимент для проверки гипотезы, что именно заморозка/сон на
# этой конкретной прошивке останавливает обработку пакетов, а не включение по умолчанию для всех.
# Имя лока — это id модуля (module.prop). Совпадение обязательно: захват,
# освобождение и проверка в докторе пишут и читают одну и ту же строку, и если
# они разойдутся, лок не снимется никогда — телефон не заснёт до перезагрузки.
# Совпадение с module.prop проверяется тестом test_data.sh.
acquire_wakelock() {
  [ "$WAKELOCK" = "1" ] || return 0
  [ -w /sys/power/wake_lock ] 2>/dev/null && echo "nfqws2-android" > /sys/power/wake_lock 2>/dev/null
  return 0
}
# Снимаем независимо от WAKELOCK: если пользователь успел выключить параметр, а лок остался
# висеть (прошивка не передала его при рестарте службы), иначе он не освободится никогда.
#
# Старое имя снимаем тоже: лок в ядре не привязан к процессу и переживает обновление
# модуля, поэтому взятый прежней версией nfqws2-magisk висел бы до перезагрузки.
release_wakelock() {
  [ -w /sys/power/wake_unlock ] 2>/dev/null || return 0
  echo "nfqws2-android" > /sys/power/wake_unlock 2>/dev/null
  echo "nfqws2-magisk" > /sys/power/wake_unlock 2>/dev/null
  return 0
}

system_config() {
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1
  sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.rmem_default=2097152 >/dev/null 2>&1
  sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1

  # На живом Keenetic-роутере (где nfqws2-keenetic работает стабильно) эти два параметра явно
  # выставлены в startup-config: nf_conntrack_tcp_timeout_established=1200, ip conntrack
  # max-entries=16384. У нас они не трогались вовсе — остаются дефолтом ядра телефона, а на
  # части Android-прошивок (особенно с агрессивной экономией батареи/памяти) этот таймаут может
  # быть куда короче. Если запись conntrack для долгоживущего, но не постоянно активного
  # соединения (мессенджер, соцсеть) истекает раньше, чем приложение реально закрыло сокет,
  # ядро начинает видеть его пакеты как INVALID/untracked — и дальше зависит от того, что с
  # такими пакетами делает остальной стек (часто — тихо дропает). Подозреваемый отдельных
  # "зависших" соединений посреди работы, не только на старте. Задаём те же значения, что
  # доказанно стабильны на роутере — явно, не полагаясь на дефолт ядра телефона.
  local cur_est cur_max
  cur_est=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)
  cur_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
  [ -n "$cur_est" ] && log_msg "conntrack: nf_conntrack_tcp_timeout_established было $cur_est, ставим 1200 (как на эталонном роутере)"
  sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=1200 >/dev/null 2>&1
  if [ -n "$cur_max" ] && [ "$cur_max" -lt 16384 ] 2>/dev/null; then
    log_msg "conntrack: nf_conntrack_max было $cur_max, поднимаем до 16384 (как на эталонном роутере)"
    sysctl -w net.netfilter.nf_conntrack_max=16384 >/dev/null 2>&1
  fi
  return 0
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

# Ключи, которые описывают сам обход. Всё остальное в конфиге — настройки модуля
# (порты, очередь, лимиты, переключатели, режим списков): у всех встроенных
# стратегий они одинаковые, и при смене стратегии берутся из действующего
# конфига пользователя (USER_KEYS ниже).
STRATEGY_KEYS="NFQWS_BASE_ARGS NFQWS_ARGS NFQWS_ARGS_QUIC NFQWS_ARGS_UDP NFQWS_ARGS_IPSET NFQWS_ARGS_CUSTOM"

# Приводит импортированный конфиг nfqws2-keenetic к виду встроенной стратегии:
# каркас — defaults/nfqws2.conf, из импорта берутся только ключи обхода
# (STRATEGY_KEYS) и собственные переменные, на которые они ссылаются; пути
# Keenetic переписываются на каталоги модуля. Ключа обхода нет в импорте —
# он пустой, а не унаследованный от стандартной стратегии. Функция
# идемпотентна: уже приведённый файл проходит через неё без изменений.
normalize_import() { # <файл импорта> -> stdout
  local src="$1" clean="$STATE_DIR/import_norm.$$"
  [ -f "$src" ] || return 1
  tr -d '\r' < "$src" | rewrite_keenetic_paths refs > "$clean"
  awk -v skeys=" $STRATEGY_KEYS " -v tpl="$MODDIR/defaults/nfqws2.conf" '
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    function keyof(line) { return match(line, /^[A-Za-z_][A-Za-z0-9_]*=/) ? substr(line, 1, RLENGTH - 1) : "" }
    # Читает файл блоками «КЛЮЧ=значение» (значение может занимать несколько строк)
    function load(file, blk, ord,   line, k, cur, inval, n) {
      n = 0; inval = 0; cur = ""
      while ((getline line < file) > 0) {
        if (inval) { blk[cur] = blk[cur] "\n" line; if (quotes(line) % 2 == 1) inval = 0; continue }
        k = keyof(line)
        if (k == "") { if (file == tpl) { ord[++n] = "\001" line } continue }
        cur = k; blk[k] = line; ord[++n] = k
        if (quotes(line) % 2 == 1) inval = 1
      }
      close(file)
      return n
    }
    BEGIN {
      ni = load(ARGV[1], imp, iord)
      nt = load(tpl, tblk, tord)
      for (i = 1; i <= nt; i++) if (substr(tord[i], 1, 1) != "\001") intpl[tord[i]] = 1
      skip["ISP_INTERFACE"]; skip["USER"]; skip["POLICY_NAME"]; skip["POLICY_EXCLUDE"]; skip["LOG_DEBUG_PATH"]
      first = 1
      for (i = 1; i <= nt; i++) {
        k = tord[i]
        if (substr(k, 1, 1) == "\001") { print substr(k, 2); continue }
        if (index(skeys, " " k " ")) {
          # Собственные переменные импорта (например ARGS_BLOCK16) нужны раньше,
          # чем на них сошлются ключи обхода, — выводим их перед первым из них.
          if (first) {
            for (j = 1; j <= ni; j++) { e = iord[j]
              if (!(e in intpl) && !(e in skip) && !(e in done)) { print imp[e]; print ""; done[e] = 1 } }
            first = 0
          }
          print ((k in imp) ? imp[k] : k "=\"\"")
        } else {
          print tblk[k]
        }
      }
      exit
    }' "$clean"
  rm -f "$clean"
}

# Предпросмотр импорта в редакторе: стратегия + настройки из действующего конфига
render_import_merged() {
  local raw="$STATE_DIR/import_prev.$$"
  normalize_import "$1" > "$raw" || { rm -f "$raw"; return 1; }
  if [ -f "$CONFFILE" ]; then merge_user_keys "$raw" "$CONFFILE"; else cat "$raw"; fi
  rm -f "$raw"
}

# ---------------------------------------------------------------- язык служебного вывода
# Строки, которые WebUI показывает как содержимое (диагностика, сводка журналов,
# проверка доступности), печатаются на языке интерфейса: WebUI передаёт его в
# NFQWS_LANG. Журналы и сообщения службы остаются русскими.
M() { if [ "$NFQWS_LANG" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# ---------------------------------------------------------------- статус в module.prop
# Менеджер (Magisk / KernelSU / APatch) показывает description прямо в списке
# модулей, поэтому туда пишется текущее состояние службы. Пишем через cat >,
# а не mv: так у module.prop остаются прежние владелец и права.
DESC_BASE="Обход DPI на базе nfqws2."
current_mode() {
  grep -m1 '^NFQWS_EXTRA_ARGS=' "$CONFFILE" 2>/dev/null | grep -o 'MODE_[A-Z]*' | head -n1 | sed 's/MODE_//' | tr 'A-Z' 'a-z'
}
update_description() { # running | stopped | paused <ssid>
  local prop="$MODDIR/module.prop" d strat mode tmp
  if [ ! -f "$prop" ] || [ ! -w "$prop" ]; then return 0; fi
  case "$1" in
    running)
      strat=$(cat "$ACTIVE_FILE" 2>/dev/null); strat="${strat#imp:}"
      mode=$(current_mode)
      d="✅ Работает · ${strat:-default}${mode:+ · $mode}" ;;
    paused) d="⏸ Пауза: домашняя Wi-Fi «$2»" ;;
    *)      d="⛔ Остановлено" ;;
  esac
  d=$(printf '%s' "$d | $DESC_BASE" | tr -d '\n\r')
  tmp="$STATE_DIR/module.prop.$$"
  awk -v d="$d" 'BEGIN { done = 0 } /^description=/ { print "description=" d; done = 1; next } { print }
    END { if (!done) print "description=" d }' "$prop" > "$tmp" && cat "$tmp" > "$prop"
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------- стратегии
# Встроенная стратегия лежит в модуле и обновляется с релизом; правка
# пользователя сохраняется в $USER_STRATEGIES_DIR под тем же именем и
# перекрывает встроенную. Сброс к исходнику — удаление этой копии.
# Импортированные конфиги nfqws2-keenetic участвуют в выборе как «imp:<имя>».
strategy_name_ok() {
  case "$1" in ''|*/*|*'`'*|*'$'*|*'"'*|*\'*|*'\'*|.*) return 1 ;; esac
  return 0
}
strategy_builtin_file() { [ -f "$STRATEGIES_DIR/$1.conf" ] && printf '%s' "$STRATEGIES_DIR/$1.conf"; }
strategy_file() { # действующий файл стратегии: правка пользователя, иначе встроенная
  case "$1" in
    imp:*) [ -f "$IMPORTS_DIR/${1#imp:}.conf" ] && printf '%s' "$IMPORTS_DIR/${1#imp:}.conf" ;;
    *) if [ -f "$USER_STRATEGIES_DIR/$1.conf" ]; then printf '%s' "$USER_STRATEGIES_DIR/$1.conf"
       else strategy_builtin_file "$1"; fi ;;
  esac
}
# 0 — встроенная стратегия отредактирована пользователем и отличается от исходника
strategy_modified() {
  local b
  b=$(strategy_builtin_file "$1") || return 1
  [ -f "$USER_STRATEGIES_DIR/$1.conf" ] || return 1
  ! cmp -s "$b" "$USER_STRATEGIES_DIR/$1.conf"
}

# Конфиг стратегии в том виде, в каком его кладёт set-strategy, — до переноса
# пользовательских настроек.
render_strategy() {
  local f
  case "$1" in
    ''|default) cat "$MODDIR/defaults/nfqws2.conf" ;;
    imp:*) f=$(strategy_file "$1") || return 1; normalize_import "$f" ;;
    *) f=$(strategy_file "$1") || return 1
       rewrite_keenetic_paths < "$f" \
         | sed -e 's#^[[:space:]]*ISP_INTERFACE=.*#ISP_INTERFACE=""#' \
               -e 's#^[[:space:]]*USER=.*#NFQWS_USER=root#' ;;
  esac
}

# Нижний блок конфига — настройки модуля, а не стратегии: у всех встроенных
# стратегий он одинаковый. Поэтому при смене стратегии и сбросе конфига он
# целиком переносится из действующего конфига: переключатели, порты, очередь,
# лимиты, режим списков, фильтр приложений и домашняя Wi-Fi остаются прежними.
# Режим списков переносится, только если это одна из штатных ссылок $MODE_*.
USER_KEYS="IPV6_ENABLED TCP_PORTS UDP_PORTS NFQUEUE_NUM PKT_LIMIT_OUT PKT_LIMIT_IN BLOCK_QUIC NAT_FIX APP_MODE AUTOSTART WATCHDOG NFQWS_USER LOG_LEVEL LOG_MAX_KB WAKELOCK HOME_WIFI NFQWS_EXTRA_ARGS"
merge_user_keys() { # <сгенерированный конфиг> <конфиг-источник настроек>  -> stdout
  awk -v keys=" $USER_KEYS " -v src="$2" '
    function quotes(str,   t) { t = str; return gsub(/"/, "", t) }
    function keyof(line) { return match(line, /^[A-Za-z_][A-Za-z0-9_]*=/) ? substr(line, 1, RLENGTH - 1) : "" }
    BEGIN {
      while ((getline line < src) > 0) {
        k = keyof(line)
        if (k == "" || !index(keys, " " k " ") || quotes(line) % 2 == 1 || (k in keep)) continue
        if (k != "NFQWS_EXTRA_ARGS" || line ~ /^NFQWS_EXTRA_ARGS="?\$MODE_(LIST|AUTO|ALL)"?[ \t]*$/) keep[k] = line
      }
      close(src)
    }
    skip { if (quotes($0) % 2 == 1) skip = 0; next }
    {
      k = keyof($0)
      if (k != "" && (k in keep) && !(k in done)) {
        print keep[k]; done[k] = 1
        if (quotes($0) % 2 == 1) skip = 1
        next
      }
      print
    }
    END {
      hdr = 0
      for (k in keep) {
        if (!(k in done)) {
          if (!hdr) { print ""; print "# ---- Настройки Android"; hdr = 1 }
          print keep[k]
        }
      }
    }' "$1"
}

# ---------------------------------------------------------------- домашняя Wi-Fi
# SSID текущей сети или код 1, если телефон не подключён к Wi-Fi. `cmd wifi`
# есть с Android 11, dumpsys — запасной путь для старых прошивок.
current_ssid() {
  local s
  s=$(cmd wifi status 2>/dev/null | sed -n 's/^Wifi is connected to "\(.*\)"[[:space:]]*$/\1/p' | head -n1)
  if [ -z "$s" ]; then
    s=$(dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo SSID: .*Supplicant state: COMPLETED' \
        | sed -e 's/.*mWifiInfo SSID: //' -e 's/, BSSID:.*//' -e 's/^"\(.*\)"$/\1/')
  fi
  case "$s" in ''|'<unknown ssid>'|'<none>'|0x) return 1 ;; esac
  printf '%s' "$s"
}
ssid_is_home() {
  if [ -z "$1" ] || [ ! -f "$HOME_FILE" ]; then return 1; fi
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$HOME_FILE" 2>/dev/null | grep -Fxq -- "$1"
}
