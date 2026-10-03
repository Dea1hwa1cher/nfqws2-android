#!/system/bin/sh
[ -n "$MODDIR" ] || { echo "MODDIR is not set" >&2; return 1 2>/dev/null || exit 1; }

: "${CONFDIR:=/data/adb/nfqws2}"
CONFFILE="$CONFDIR/nfqws2.conf"
LISTS_DIR="$CONFDIR/lists"
STATE_DIR="$CONFDIR/state"
LOG_DIR="$CONFDIR/logs"
USER_PRESETS_DIR="$CONFDIR/presets"
STRATEGIES_DIR="$MODDIR/strategies"
USER_STRATEGIES_DIR="$CONFDIR/strategies"

LUA_DIR="$MODDIR/lua"
BLOBS_DIR="$MODDIR/blobs"
PRESETS_DIR="$MODDIR/presets"
NFQWS_BIN="$MODDIR/bin/nfqws2"

PIDFILE="$STATE_DIR/nfqws2.pid"
WD_PIDFILE="$STATE_DIR/watchdog.pid"
DESIRED_FILE="$STATE_DIR/desired"
ARGS_FILE="$STATE_DIR/last.args"
CAPS_FILE="$STATE_DIR/caps"
APP_UIDS_FILE="$STATE_DIR/app_uids"
SERVICE_LOG="$LOG_DIR/service.log"
NFQWS_LOG="$LOG_DIR/nfqws2.log"

MARK_EXCLUDE="0x20000000/0x20000000"
MARK_INCLUDE="0x10000000/0x10000000"
MARK_PROCESSED="0x40000000/0x40000000"

IPT_GROUP_POST="nfqws_post"
IPT_GROUP_PRE="nfqws_pre"
IPT_GROUP_NAT="nfqws_nat"
IPT_GROUP_QOUT="nfqws_qout"
IPT_GROUP_APP="nfqws_app"

# xt_owner принимает не более 128 диапазонов в одном правиле
APP_UID_MAX=128

CNT_OUT_MASK=0x0f000000
CNT_OUT_STEP=16777216

mkdir -p "$LISTS_DIR" "$STATE_DIR" "$LOG_DIR" "$USER_PRESETS_DIR" "$USER_STRATEGIES_DIR" 2>/dev/null

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
  : "${BLOCK_QUIC:=1}"
  : "${NAT_FIX:=1}"
  : "${STRATEGY_TLS:=auto}"
  : "${STRATEGY_UDP:=auto}"
  : "${PRESET_TCP:=}"
  : "${APP_MODE:=off}"
  : "${LOG_MAX_KB:=512}"
  : "${PKT_LIMIT_OUT:=15}"
  : "${PKT_LIMIT_IN:=15}"
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
          [ -f "$LISTS_DIR/user.list" ] && cp -f "$LISTS_DIR/user.list" "$LISTS_DIR/user_extra.list" || touch "$LISTS_DIR/user_extra.list" ;;
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
    [ "$LOG_LEVEL" = "1" ] && : > "$f" 2>/dev/null || rotate_file "$f" "$max"
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

norm_args() {
  printf '%s\n' "$1" \
    | sed -e 's/^[[:space:]]*#.*$//' -e 's/\\//g' \
    | awk '{ for (i=1; i<=NF; i++) printf "%s ", $i } END { print "" }' \
    | sed -e "s#/opt/etc/nfqws2/lua#$LUA_DIR#g" \
          -e "s#/opt/etc/nfqws2/blobs#$BLOBS_DIR#g" \
          -e "s#/opt/etc/nfqws2/lists#$LISTS_DIR#g" \
          -e "s#/opt/etc/nfqws2#$CONFDIR#g" \
          -e "s#/opt/var/log#$LOG_DIR#g" \
          -e 's/  */ /g; s/^ //; s/ $//'
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

_fw_iface_rules() {
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

  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -A $IPT_GROUP_NAT $OUT -m mark --mark $MARK_PROCESSED -p udp -j MASQUERADE
  fi

  [ "$LIMITER" = "connbytes" ] || return 0
  $CMD -w -t mangle -A $IPT_GROUP_PRE $IN -m mark --mark $MARK_PROCESSED -j RETURN
  [ -n "$UP" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p udp -m multiport --sports $UP $CB_IN $JNFQ
  if [ -n "$TP" ]; then
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP $CB_IN $JNFQ
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP --tcp-flags syn,ack syn,ack $JNFQ
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP --tcp-flags fin fin $JNFQ
    $CMD -w -t mangle -A $IPT_GROUP_PRE $IN $CONN_CHECK -p tcp -m multiport --sports $TP --tcp-flags rst rst $JNFQ
  fi
}

_firewall_start() {
  local CMD="$1" IF ex

  IPT_TCP_PORTS=$(printf '%s' "$TCP_PORTS" | tr '-' ':')
  IPT_UDP_EFF=$(printf '%s' "$UDP_PORTS" | tr '-' ':')
  [ "$BLOCK_QUIC" = "1" ] && IPT_UDP_EFF=$(port_list_without "$IPT_UDP_EFF" 443)

  LIMITER=$(detect_limiter "$CMD")
  [ "$CMD" = "iptables" ] && echo "$LIMITER" > "$STATE_DIR/limiter" 2>/dev/null

  $CMD -w -t mangle -N $IPT_GROUP_POST 2>/dev/null
  $CMD -w -t mangle -F $IPT_GROUP_POST
  while $CMD -w -t mangle -D POSTROUTING -j $IPT_GROUP_POST 2>/dev/null; do :; done

  if [ "$LIMITER" = "connbytes" ]; then
    $CMD -w -t mangle -N $IPT_GROUP_PRE 2>/dev/null
    $CMD -w -t mangle -F $IPT_GROUP_PRE
  fi
  while $CMD -w -t mangle -D PREROUTING -j $IPT_GROUP_PRE 2>/dev/null; do :; done

  if [ "$LIMITER" = "connmark_out" ]; then
    _fw_counter_chain "$CMD" $IPT_GROUP_QOUT $CNT_OUT_MASK $CNT_OUT_STEP "$PKT_LIMIT_OUT"
  fi

  if [ "$CMD" = "iptables" ] && [ "$NAT_FIX" = "1" ]; then
    $CMD -w -t nat -N $IPT_GROUP_NAT 2>/dev/null
    $CMD -w -t nat -F $IPT_GROUP_NAT
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
  fi

  if [ -z "$ISP_INTERFACE" ]; then
    for ex in $IFACE_EXCLUDE; do
      $CMD -w -t mangle -A $IPT_GROUP_POST -o "$ex" -j RETURN
      [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -A $IPT_GROUP_PRE -i "$ex" -j RETURN
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
  [ "$LIMITER" = "connbytes" ] && $CMD -w -t mangle -I PREROUTING 1 -j $IPT_GROUP_PRE
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
  $CMD -w -t mangle -F $IPT_GROUP_APP 2>/dev/null; $CMD -w -t mangle -X $IPT_GROUP_APP 2>/dev/null
  if [ "$CMD" = "iptables" ]; then
    while $CMD -w -t nat -D POSTROUTING -j $IPT_GROUP_NAT 2>/dev/null; do :; done
    $CMD -w -t nat -F $IPT_GROUP_NAT 2>/dev/null; $CMD -w -t nat -X $IPT_GROUP_NAT 2>/dev/null
  fi
}

firewall_iptables()  { _firewall_start iptables; }
firewall_ip6tables() { [ "$IPV6_ENABLED" = "0" ] && return 0; _firewall_start ip6tables; }

firewall_start() {
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
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1
  sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1
  sysctl -w net.core.rmem_default=2097152 >/dev/null 2>&1
  sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1
  return 0
}