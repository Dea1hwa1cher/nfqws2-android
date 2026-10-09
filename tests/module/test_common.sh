#!/bin/sh
# Unit tests for the pure logic in lib/common.sh.
# Everything here runs without touching a device: no iptables, no /data/adb.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
trap sandbox_cleanup INT TERM
load_common
conf_reset
load_conf

# ── norm_args ─────────────────────────────────────────────────────────────────
section "norm_args: comment stripping and whitespace"

out=$(norm_args '--foo   --bar
   # this is a comment
   --baz')
assert_eq "--foo --bar --baz" "$out" "drops comment lines and collapses whitespace"

out=$(norm_args 'a\\b')
assert_eq "ab" "$out" "strips backslashes"

out=$(norm_args '   leading and trailing   ')
assert_eq "leading and trailing" "$out" "trims the edges"

section "norm_args: path rewriting"

out=$(norm_args '--lua-init=@/opt/etc/nfqws2/lua/zapret-lib.lua')
assert_eq "--lua-init=@$LUA_DIR/zapret-lib.lua" "$out" "lua path -> \$LUA_DIR"

out=$(norm_args '--blob=x:/opt/etc/nfqws2/blobs/stun.bin')
assert_eq "--blob=x:$BLOBS_DIR/stun.bin" "$out" "blobs path -> \$BLOBS_DIR"

out=$(norm_args '--hostlist=/opt/etc/nfqws2/lists/user.list')
assert_eq "--hostlist=$LISTS_DIR/user.list" "$out" "lists path -> \$LISTS_DIR"

out=$(norm_args '--debug=@/opt/var/log/nfqws2.log')
assert_eq "--debug=@$LOG_DIR/nfqws2.log" "$out" "log path -> \$LOG_DIR"

# The generic /opt/etc/nfqws2 rule must not swallow the specific ones above.
out=$(norm_args '/opt/etc/nfqws2/lua/a.lua /opt/etc/nfqws2/lists/b.list /opt/etc/nfqws2/c.conf')
assert_eq "$LUA_DIR/a.lua $LISTS_DIR/b.list $CONFDIR/c.conf" "$out" \
  "specific paths win over the generic /opt/etc/nfqws2 rule"

# ── list_count ────────────────────────────────────────────────────────────────
section "list_count"

printf 'a.com\n\n# comment\n  \nb.com\n' > "$LISTS_DIR/user.list"
assert_eq "2" "$(list_count "$LISTS_DIR/user.list")" "counts only real entries"

assert_eq "0" "$(list_count "$LISTS_DIR/does-not-exist.list")" "missing file counts as 0"

: > "$LISTS_DIR/user.list"
assert_eq "0" "$(list_count "$LISTS_DIR/user.list")" "empty file counts as 0"

section "list_counts agrees with list_count"

# json-status counts all its lists with one grep; the numbers must stay exactly
# what list_count gives file by file, including for missing and edge-case files.
printf 'a.com\r\n\r\n# c\r\nb.com' > "$LISTS_DIR/user.list"
printf 'x\n\t\n  # y\nz\n' > "$LISTS_DIR/exclude.list"
printf 'one\n' > "$LISTS_DIR/user.list.bak"
: > "$LISTS_DIR/auto.list"
mkdir -p "$LISTS_DIR/dir.list"
want=""
for f in user exclude auto user.list.bak dir does-not-exist user; do
  case "$f" in *.bak) p="$LISTS_DIR/$f" ;; *) p="$LISTS_DIR/$f.list" ;; esac
  set -- "$@" "$p"
  want="$want${want:+ }$(list_count "$p")"
done
assert_eq "$want" "$(list_counts "$@")" "one number per file, in argument order"
assert_eq "2" "$(list_counts "$LISTS_DIR/exclude.list")" "a single file works too"
rmdir "$LISTS_DIR/dir.list"; rm -f "$LISTS_DIR/user.list.bak"
set --

section "current_mode"

cp "$CONFFILE" "$CONFFILE.keep"
printf 'A=1\nNFQWS_EXTRA_ARGS="$MODE_LIST"\nNFQWS_EXTRA_ARGS="$MODE_ALL"\n' > "$CONFFILE"
assert_eq "list" "$(current_mode)" "the first NFQWS_EXTRA_ARGS line wins"
printf 'NFQWS_EXTRA_ARGS="--x"\n' > "$CONFFILE"
assert_eq "" "$(current_mode)" "no mode, no output"
mv -f "$CONFFILE.keep" "$CONFFILE"

# ── port_list_without ─────────────────────────────────────────────────────────
section "port_list_without"

assert_eq "80,1984" "$(port_list_without '80,443,1984' 443)" "removes a middle port"
assert_eq "443,1984" "$(port_list_without '80,443,1984' 80)" "removes the first port"
assert_eq "80,443" "$(port_list_without '80,443,1984' 1984)" "removes the last port"
assert_eq "80,443" "$(port_list_without '80,443' 5222)" "unknown port changes nothing"
assert_eq "80" "$(port_list_without '80,443' 443)" "single port can disappear"

# ── validate_conf ─────────────────────────────────────────────────────────────
section "validate_conf"

printf 'A=1\nB="x"\n' > "$CONFFILE"
validate_conf "$CONFFILE"; assert_rc 0 $? "plain config passes"

printf 'A=1\nB=`id`\n' > "$CONFFILE"
validate_conf "$CONFFILE" >/dev/null 2>&1; assert_rc 1 $? "backtick is rejected"

printf 'A=1\nB=$(id)\n' > "$CONFFILE"
validate_conf "$CONFFILE" >/dev/null 2>&1; assert_rc 1 $? "command substitution is rejected"

out=$(validate_conf "$CONFFILE" 2>&1)
assert_contains "$out" "line 2" "the offending line number is reported"

# ── dry_run_check and validate_conf_file ──────────────────────────────────────
section "dry_run_check and validate_conf_file"

conf_reset
validate_conf_file "$CONFFILE"
assert_rc 0 $? "valid conf file passes validate_conf_file"

printf 'NFQWS_BASE_ARGS="--new"\n' > "$CONFFILE"
validate_conf_file "$CONFFILE" >/dev/null 2>&1
assert_rc 1 $? "config with --new in base args is rejected by validate_conf_file"

conf_reset
MOCK_NFQWS_DRY_RUN_FAIL=1
export MOCK_NFQWS_DRY_RUN_FAIL
validate_conf_file "$CONFFILE" >/dev/null 2>&1
assert_rc 1 $? "validate_conf_file fails when nfqws2 dry-run rejects parameters"
unset MOCK_NFQWS_DRY_RUN_FAIL

# ── import_safe_name ──────────────────────────────────────────────────────────
section "import_safe_name"

assert_eq "keenetic" "$(import_safe_name 'keenetic')" "plain name survives"
assert_eq "etcpasswd" "$(import_safe_name '/etc/passwd')" "slashes are stripped"
assert_eq "мой конфиг" "$(import_safe_name 'мой конфиг')" "cyrillic survives, only edges are trimmed"
assert_eq "ab" "$(import_safe_name '..ab')" "leading dots are trimmed"

q="'"
raw="a/b\\c\`d\$e\"f${q}g"
assert_eq "abcdefg" "$(import_safe_name "$raw")" "shell metacharacters are removed"

long=$(printf 'x%.0s' $(seq 1 400))
assert_eq "200" "$(printf '%s' "$(import_safe_name "$long")" | wc -c | tr -d ' ')" "name is capped at 200 chars"

# ── is_keenetic_config ────────────────────────────────────────────────────────
section "is_keenetic_config"

printf 'NFQWS_ARGS="x"\n' > "$SANDBOX/one.conf"
is_keenetic_config "$SANDBOX/one.conf"; assert_rc 1 $? "a single key is not enough"

printf 'NFQWS_ARGS="x"\nISP_INTERFACE="eth0"\n' > "$SANDBOX/two.conf"
is_keenetic_config "$SANDBOX/two.conf"; assert_rc 0 $? "two keys are accepted"

printf '# just a comment\nfoo=bar\n' > "$SANDBOX/none.conf"
is_keenetic_config "$SANDBOX/none.conf"; assert_rc 1 $? "unrelated file is rejected"

# ── is_running ────────────────────────────────────────────────────────────────
section "is_running"

rm -f "$PIDFILE"
is_running; assert_rc 1 $? "no pidfile means not running"

echo "" > "$PIDFILE"
is_running; assert_rc 1 $? "empty pidfile means not running"

echo "0" > "$PIDFILE"
is_running; assert_rc 1 $? "pid 0 is rejected"

echo "notapid" > "$PIDFILE"
is_running; assert_rc 1 $? "non-numeric pid is rejected"

echo "999999" > "$PIDFILE"
is_running; assert_rc 1 $? "dead pid is rejected"

echo "$$" > "$PIDFILE"
is_running; assert_rc 0 $? "live pid is accepted"

# ── app_uid_count ─────────────────────────────────────────────────────────────
section "app_uid_count"

rm -f "$APP_UIDS_FILE"
assert_eq "0" "$(app_uid_count)" "missing uid file counts as 0"

printf '10123,10188,10201\n' > "$APP_UIDS_FILE"
assert_eq "3" "$(app_uid_count)" "counts comma-separated uids"

printf '10123,,abc,10201\n' > "$APP_UIDS_FILE"
assert_eq "2" "$(app_uid_count)" "ignores empty and non-numeric fields"

# ── resolve_app_uids ──────────────────────────────────────────────────────────
section "resolve_app_uids"

printf '# packages\ncom.example.browser\ncom.termux\nmissing.app\n' > "$CONFDIR/apps.list"
out=$(resolve_app_uids)
assert_eq "10123,10201" "$out" "resolves only packages present on the device, sorted"

printf 'com.termux\n' > "$CONFDIR/apps.list"
assert_eq "10201" "$(resolve_app_uids)" "single package resolves"

: > "$CONFDIR/apps.list"
assert_eq "" "$(resolve_app_uids)" "empty apps.list resolves to nothing"

# ── _startup_args ─────────────────────────────────────────────────────────────
section "_startup_args"

conf_reset
printf 'ipset.example.com\n' > "$LISTS_DIR/ipset.list"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--user=root" "passes the configured user"
assert_contains "$args" "--qnum=300" "passes the queue number"
assert_contains "$args" "--debug=@$NFQWS_LOG" "LOG_LEVEL=0 logs to nfqws2.log"
assert_not_contains "$args" "--bind-fix4" "no bind-fix without ISP_INTERFACE"
assert_contains "$args" "--ipset=$LISTS_DIR/ipset.list" "ipset block appears when ipset.list is populated"

: > "$LISTS_DIR/ipset.list"
reload_conf
args=$(_startup_args)
assert_not_contains "$args" "--ipset" "ipset block disappears when ipset.list is empty"

printf 'BLOCK_QUIC=1\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_not_contains "$args" "--filter-udp=443" "QUIC block drops the quic desync"

conf_reset
printf 'LOG_LEVEL=1\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--debug=@$LOG_DIR/nfqws2-debug.log" "LOG_LEVEL=1 logs to the debug file"

conf_reset
printf 'ISP_INTERFACE="wlan0 rmnet0"\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--bind-fix4" "multiple ISP interfaces enable bind-fix4"
assert_contains "$args" "--bind-fix6" "bind-fix6 follows when IPv6 is on"

conf_reset
printf 'ISP_INTERFACE="wlan0 rmnet0"\nIPV6_ENABLED=0\n' >> "$CONFFILE"
reload_conf
args=$(_startup_args)
assert_contains "$args" "--bind-fix4" "bind-fix4 still applies"
assert_not_contains "$args" "--bind-fix6" "bind-fix6 is skipped with IPv6 disabled"

# ── render_import_merged ──────────────────────────────────────────────────────
section "render_import_merged"

conf_reset
printf 'PKT_LIMIT_OUT=15\n' >> "$CONFFILE"
reload_conf
cat > "$SANDBOX/imp.conf" <<'IMP'
ISP_INTERFACE="eth0"
USER="keenetic"
POLICY_NAME="p1"
LOG_DEBUG_PATH="/opt/var/log/nfqws2.log"
NFQWS_BASE_ARGS="--lua-init=@/opt/etc/nfqws2/lua/zapret-lib.lua"
PKT_LIMIT_OUT=3
IMP
out=$(render_import_merged "$SANDBOX/imp.conf")
assert_not_contains "$out" 'ISP_INTERFACE=' "device-specific ISP_INTERFACE is dropped"
assert_not_contains "$out" 'USER="keenetic"' "keentic USER is dropped"
assert_not_contains "$out" 'POLICY_NAME=' "POLICY_NAME is dropped"
assert_not_contains "$out" 'LOG_DEBUG_PATH=' "LOG_DEBUG_PATH is dropped"
# The preview is what ends up in nfqws2.conf, which the module sources after
# lib/common.sh has defined these variables — so the reference form is correct
# here, unlike in norm_args() where the real path must reach the binary.
assert_contains "$out" '@$LUA_DIR/zapret-lib.lua' "lua path becomes a \$LUA_DIR reference"
assert_not_contains "$out" '/opt/etc/nfqws2' "no /opt paths survive"
assert_contains "$out" 'AUTOSTART=' "keys the import lacks are filled in from the device conf"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^PKT_LIMIT_OUT=')" \
  "keys the import defines are not duplicated in the appended section"

# ── rotate_file ───────────────────────────────────────────────────────────────
section "rotate_file"

big="$SANDBOX/big.log"
awk 'BEGIN{for(i=0;i<200;i++) print "0123456789"}' > "$big"
before=$(wc -c < "$big" | tr -d ' ')
rotate_file "$big" 500
after=$(wc -c < "$big" | tr -d ' ')
assert_ge "$before" 2000 "the fixture really is over the limit"
if [ "$after" -lt "$before" ]; then _ok "oversized file is truncated"; else _fail "oversized file was not truncated"; fi
if [ "$after" -le 500 ]; then _ok "result fits the limit"; else _fail "result is still $after bytes"; fi

small="$SANDBOX/small.log"
printf 'tiny\n' > "$small"
rotate_file "$small" 500
assert_eq "tiny" "$(cat "$small")" "small file is left alone"

# ── sync_lists_and_blobs ──────────────────────────────────────────────────────
section "sync_lists_and_blobs: restoring a missing list"

# A list deleted from the config directory comes back from the module's copy;
# an existing one, edited by the user, is never overwritten.
rm -f "$LISTS_DIR/user_extra.list"
printf 'mine\n' > "$LISTS_DIR/youtube.list"
sync_lists_and_blobs >/dev/null 2>&1
assert_eq "$(cat "$MODDIR/lists/user_extra.list")" "$(cat "$LISTS_DIR/user_extra.list" 2>/dev/null)" \
  "a missing list is copied from the module"
assert_eq "mine" "$(cat "$LISTS_DIR/youtube.list")" "an existing list is left alone"

rm -rf "$LISTS_DIR"
sync_lists_and_blobs >/dev/null 2>&1
assert_file "$LISTS_DIR/user.list" "a removed lists directory is recreated and filled"

harness_finish
