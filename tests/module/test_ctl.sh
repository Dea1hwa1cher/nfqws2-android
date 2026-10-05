#!/bin/sh
# End-to-end tests for bin/nfqws2-ctl, run against a sandbox copy of the module
# with stub Android tools. This is the interface the WebUI talks to, so the
# shape of its output is a contract, not an implementation detail.
#
# Note on style: ctl() stores its result in $ctl_out/$ctl_rc rather than
# printing, so assertions read the variable instead of `$(ctl ...)` — a command
# substitution would run ctl in a subshell and capture nothing.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
# The test shell needs the same paths and helpers the module uses ($CONFFILE,
# $LISTS_DIR, list_count…) to inspect what the ctl did. The ctl itself sources
# its own copy from the sandbox, so this is purely for the assertions.
load_common
conf_reset
printf 'WATCHDOG=0\n' >> "$CONFFILE"

# ── json-status: the WebUI's only data source ─────────────────────────────────
section "json-status: stopped service"

ctl json-status
assert_rc 0 "$ctl_rc" "exits 0"
assert_contains "$ctl_out" '"running":false' "reports running=false"
assert_contains "$ctl_out" '"pid":""' "reports an empty pid"
assert_contains "$ctl_out" '"uptime":0' "reports uptime 0"

for key in running pid uptime strategy version mode limiter pkt_limit_out pkt_limit_in \
           block_quic app_mode autostart watchdog wakelock_on ipv6 log_level qdrop queue \
           app_uids counts; do
  assert_contains "$ctl_out" "\"$key\":" "json-status exposes $key"
done
for key in user auto exclude ipset ipset_exclude apps; do
  assert_contains "$ctl_out" "\"$key\":" "counts exposes $key"
done

section "json-status: numeric fields stay numeric"

# These are spliced into the JSON without quotes; a non-numeric value would make
# the whole document unparseable and take the WebUI down with it.
for key in pkt_limit_out pkt_limit_in block_quic autostart watchdog wakelock_on ipv6 log_level qdrop queue app_uids; do
  assert_match "$ctl_out" "\"$key\":[0-9]+" "$key is emitted as a bare number"
done

section "json-status: garbage in the config cannot break the JSON"

conf_reset
printf 'PKT_LIMIT_OUT=abc\nNFQUEUE_NUM=\nLOG_LEVEL=none\n' >> "$CONFFILE"
ctl json-status
assert_rc 0 "$ctl_rc" "still exits 0 with a corrupt config"
assert_match "$ctl_out" '"pkt_limit_out":[0-9]+' "corrupt PKT_LIMIT_OUT degrades to a number"
assert_match "$ctl_out" '"queue":[0-9]+' "empty NFQUEUE_NUM degrades to a number"
assert_match "$ctl_out" '"log_level":[0-9]+' "non-numeric LOG_LEVEL degrades to a number"
assert_no_match "$ctl_out" '"pkt_limit_out":"' "no numeric field is ever quoted"

section "json-status: running service"

conf_reset
# A live PID in the pidfile is enough for the running branch; actually starting
# the service would build ~260 iptables rules through the stub, which costs
# minutes on this machine and is covered by test_service.sh instead.
sleep 300 &
FAKE_PID=$!
printf '%s\n' "$FAKE_PID" > "$CONFDIR/state/nfqws2.pid"
date +%s > "$CONFDIR/state/started_at"

ctl is-running
assert_rc 0 "$ctl_rc" "is-running returns 0 for a live pid"
ctl json-status
assert_contains "$ctl_out" '"running":true' "reports running=true"
assert_contains "$ctl_out" "\"pid\":\"$FAKE_PID\"" "pid matches the pidfile"
assert_match "$ctl_out" '"uptime":[0-9]+' "uptime is reported"

kill "$FAKE_PID" 2>/dev/null
wait "$FAKE_PID" 2>/dev/null
rm -f "$CONFDIR/state/nfqws2.pid" "$CONFDIR/state/started_at"
ctl is-running
assert_rc 1 "$ctl_rc" "is-running returns 1 without a pidfile"

# ── set ───────────────────────────────────────────────────────────────────────
section "set: value validation"

ctl set BLOCK_QUIC 1
assert_rc 0 "$ctl_rc" "BLOCK_QUIC accepts 1"
ctl get-conf
assert_contains "$ctl_out" 'BLOCK_QUIC="1"' "the value is written to the config"

ctl set BLOCK_QUIC 2
assert_rc 1 "$ctl_rc" "BLOCK_QUIC rejects 2"

ctl set PKT_LIMIT_OUT 15
assert_rc 0 "$ctl_rc" "PKT_LIMIT_OUT accepts 15"
ctl set PKT_LIMIT_OUT 0
assert_rc 1 "$ctl_rc" "PKT_LIMIT_OUT rejects 0"
ctl set PKT_LIMIT_OUT 16
assert_rc 1 "$ctl_rc" "PKT_LIMIT_OUT rejects 16"

printf 'com.termux\n' > "$CONFDIR/apps.list"
ctl set APP_MODE include
assert_rc 0 "$ctl_rc" "APP_MODE accepts include"
ctl set APP_MODE whatever
assert_rc 1 "$ctl_rc" "APP_MODE rejects an unknown mode"

ctl set NFQWS_ARGS "--lua-desync=fake"
assert_rc 1 "$ctl_rc" "set refuses parameters outside the allow-list"

ctl set BLOCK_QUIC
assert_rc 1 "$ctl_rc" "set without a value fails"

section "set-mode"

ctl set-mode list
assert_rc 0 "$ctl_rc" "set-mode list is accepted"
ctl get-conf
assert_contains "$ctl_out" 'NFQWS_EXTRA_ARGS="$MODE_LIST"' "mode is stored as a MODE_ reference"

ctl set-mode nonsense
assert_rc 1 "$ctl_rc" "set-mode rejects an unknown mode"

# ── lists ─────────────────────────────────────────────────────────────────────
section "get-list / save-list-b64"

ctl get-list user
assert_rc 0 "$ctl_rc" "get-list user works"
assert_contains "$ctl_out" "youtube.com" "get-list returns the seeded contents"

ctl save-list-b64 user "$(b64 'one.example.com
two.example.com')"
assert_rc 0 "$ctl_rc" "save-list-b64 works"
assert_eq "2" "$(list_count "$CONFDIR/lists/user.list")" "the list is replaced"

ctl get-list nosuchlist
assert_rc 1 "$ctl_rc" "an unknown list name is rejected"

section "add-domain"

printf 'first.example.com' > "$CONFDIR/lists/user.list"   # deliberately no trailing newline
ctl add-domain "https://WWW.Example.COM/some/path"
assert_rc 0 "$ctl_rc" "add-domain accepts a URL"
assert_contains "$ctl_out" "example.com" "the domain is lowercased and normalised"
assert_eq "2" "$(list_count "$CONFDIR/lists/user.list")" "the previous entry survives the append"

ctl add-domain "https://www.example.com/"
assert_eq "2" "$(list_count "$CONFDIR/lists/user.list")" "an existing domain is not duplicated"

ctl add-domain "not a domain"
assert_rc 1 "$ctl_rc" "add-domain rejects garbage"

ctl clear-auto
assert_rc 0 "$ctl_rc" "clear-auto works"
assert_eq "0" "$(list_count "$CONFDIR/lists/auto.list")" "auto.list is emptied"

ctl reset-lists
assert_rc 0 "$ctl_rc" "reset-lists works"
assert_eq "$(list_count "$MODDIR/defaults/lists/user.list")" "$(list_count "$CONFDIR/lists/user.list")" \
  "user.list is back to the shipped default"

# ── config ────────────────────────────────────────────────────────────────────
section "save-conf-b64"

ctl save-conf-b64 "$(b64 'A=1
B="x"')"
assert_rc 0 "$ctl_rc" "a valid config is accepted"
ctl get-conf
assert_contains "$ctl_out" 'A=1' "the new config is in place"

ctl save-conf-b64 "$(b64 'A=`id`')"
assert_rc 1 "$ctl_rc" "a config with a backtick is rejected"

ctl save-conf-b64 "$(b64 'A=$(id)')"
assert_rc 1 "$ctl_rc" "a config with command substitution is rejected"

ctl save-conf-b64 "$(b64 '')"
assert_rc 1 "$ctl_rc" "an empty config is rejected"

assert_file "$CONFFILE.bak" "a backup of the previous config is kept"

ctl validate-conf-b64 "$(b64 'OK=1')"
assert_rc 0 "$ctl_rc" "validate-conf-b64 accepts a valid config"
ctl validate-conf-b64 "$(b64 'BAD=`x`')"
assert_rc 1 "$ctl_rc" "validate-conf-b64 rejects an invalid config"

# ── strategies ────────────────────────────────────────────────────────────────
section "strategies"

ctl list-strategies
assert_rc 0 "$ctl_rc" "list-strategies works"
assert_contains "$ctl_out" "alt13" "a shipped strategy is listed"
# "default" is not a file — it means "use the shipped nfqws2.conf" — so the ctl
# deliberately does not list it; the WebUI prepends it itself.
assert_not_contains "$ctl_out" "default" "default is not a real strategy file"
assert_eq "$(printf '%s\n' "$ctl_out" | sort -u | wc -l | tr -d ' ')" \
          "$(printf '%s\n' "$ctl_out" | wc -l | tr -d ' ')" "the list has no duplicates"

mkdir -p "$CONFDIR/strategies"
printf 'NFQWS_ARGS="--filter-tcp=443"\n' > "$CONFDIR/strategies/mine.conf"
ctl list-strategies
assert_contains "$ctl_out" "mine" "user strategies are listed too"

ctl get-strategy
assert_rc 0 "$ctl_rc" "get-strategy works"

ctl set-strategy alt13
assert_rc 0 "$ctl_rc" "set-strategy applies a shipped strategy"
ctl get-conf
# Shipped strategies already reference $LUA_DIR/$BLOBS_DIR, exactly like the
# default config does — the config is sourced by the module, so the reference
# form is what should end up in it. What must NOT survive is a keenetic path.
assert_contains "$ctl_out" '@$LUA_DIR/' "the strategy keeps \$LUA_DIR references"
assert_not_contains "$ctl_out" "/opt/etc/nfqws2" "no keenetic paths survive the rewrite"
ctl get-strategy
assert_eq "alt13" "$ctl_out" "the active strategy is recorded"

ctl set-strategy nosuchstrategy
assert_rc 1 "$ctl_rc" "an unknown strategy is rejected"

ctl set-strategy default
assert_rc 0 "$ctl_rc" "set-strategy default works"
ctl get-strategy
assert_eq "default" "$ctl_out" "the active strategy is back to default"

# ── imports ───────────────────────────────────────────────────────────────────
section "imports"

imp=$(b64 'NFQWS_ARGS="--filter-tcp=443"
ISP_INTERFACE="eth0"
PKT_LIMIT_OUT=3')
ctl import-add-b64 "$(b64 'my-config')" "$imp"
assert_rc 0 "$ctl_rc" "a keenetic config is imported"
assert_contains "$ctl_out" "my-config" "the import is stored under its name"

ctl list-imports
assert_contains "$ctl_out" "my-config" "the import is listed"

ctl get-import-merged-b64 "my-config"
assert_rc 0 "$ctl_rc" "the merged preview is produced"
preview=$(printf '%s' "$ctl_out" | base64 -d 2>/dev/null)
assert_not_contains "$preview" "ISP_INTERFACE=" "the preview drops ISP_INTERFACE"
assert_contains "$preview" "Настройки Android" "the preview appends the Android settings section"

ctl import-add-b64 "$(b64 'not-a-config')" "$(b64 'just some text')"
assert_rc 1 "$ctl_rc" "a non-keenetic file is rejected"

ctl get-import-merged-b64 "../etc/passwd"
assert_rc 1 "$ctl_rc" "path traversal in get-import-merged is rejected"
ctl delete-import "../etc/passwd"
assert_rc 1 "$ctl_rc" "path traversal in delete-import is rejected"
ctl rename-import "../etc/passwd" "x"
assert_rc 1 "$ctl_rc" "path traversal in rename-import is rejected"

ctl rename-import "my-config" "renamed-import"
assert_rc 0 "$ctl_rc" "an import can be renamed"
assert_contains "$ctl_out" "renamed-import" "the new name is reported"
assert_no_file "$CONFDIR/imports/my-config.conf" "the old file is gone"

ctl delete-import "renamed-import"
assert_rc 0 "$ctl_rc" "an import can be deleted"
assert_no_file "$CONFDIR/imports/renamed-import.conf" "the file is really gone"

# ── logs ──────────────────────────────────────────────────────────────────────
section "logs"

printf 'line one\nline two\nline three\n' > "$CONFDIR/logs/service.log"
ctl get-logs service 2
assert_rc 0 "$ctl_rc" "get-logs works"
assert_contains "$ctl_out" "line three" "the tail includes the newest line"
assert_not_contains "$ctl_out" "line one" "the tail respects the requested count"

ctl get-logs service abc
assert_rc 0 "$ctl_rc" "a non-numeric line count falls back instead of failing"
assert_contains "$ctl_out" "line one" "the fallback keeps everything"

ctl get-logs nfqws 5
assert_contains "$ctl_out" "пусто" "an empty log reports (пусто) rather than nothing"

ctl clear-logs
assert_rc 0 "$ctl_rc" "clear-logs works"
assert_eq "0" "$(wc -c < "$CONFDIR/logs/service.log" | tr -d ' ')" "service.log is truncated"

# ── doctor / status ───────────────────────────────────────────────────────────
section "doctor"

ctl doctor
assert_rc 0 "$ctl_rc" "doctor runs to completion"
assert_match "$ctl_out" "^(ok|warn|fail|info)	" "doctor emits tab-separated severity rows"
assert_contains "$ctl_out" "NFQUEUE" "doctor checks the NFQUEUE target"
assert_contains "$ctl_out" "limiter" "doctor reports the limiter in use"

section "doctor without kernel features"

MOCK_IPT_FEATURES="multiport NFQUEUE"
export MOCK_IPT_FEATURES
ctl doctor
assert_contains "$ctl_out" "нет connbytes" "a kernel without connbytes is reported as connmark_out"
MOCK_IPT_FEATURES="connbytes multiport owner NFQUEUE"
export MOCK_IPT_FEATURES

section "status"

ctl status
assert_rc 0 "$ctl_rc" "status works"
assert_contains "$ctl_out" "Служба NFQWS2" "status reports the service state"
assert_contains "$ctl_out" "Режим:" "status reports the mode line"

section "unknown command"

ctl definitely-not-a-command
assert_rc 1 "$ctl_rc" "an unknown command fails"
assert_contains "$ctl_out" "Команды:" "an unknown command prints the usage list"

harness_finish
