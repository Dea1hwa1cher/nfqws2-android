#!/bin/sh
# Service lifecycle and firewall rule-set tests.
#
# These are the slowest tests in the suite: every iptables call is a process
# spawn, and a full rule set is ~130 rules across two tables. They are kept in
# their own file so the fast suites can be run without them.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
load_common
conf_reset
printf 'WATCHDOG=0\n' >> "$CONFFILE"

# ── start ─────────────────────────────────────────────────────────────────────
section "start: the daemon comes up and the arguments are assembled"

svc start
assert_rc 0 "$svc_rc" "start succeeds with the stub daemon"
assert_file "$CONFDIR/state/nfqws2.pid" "the pidfile is written"
assert_file "$CONFDIR/state/last.args" "the argument file is written"
assert_file "$CONFDIR/state/desired" "the desired-state marker is written"
assert_file "$CONFDIR/state/started_at" "the start timestamp is written"

args=$(cat "$CONFDIR/state/last.args")
assert_contains "$args" "--qnum=300" "the queue number reaches the daemon"
assert_contains "$args" "--user=root" "the run-as user reaches the daemon"
assert_contains "$args" "--debug=@$NFQWS_LOG" "the log path reaches the daemon"
assert_not_contains "$args" "/opt/etc/nfqws2" "no keenetic paths leak into the arguments"
assert_not_contains "$args" "MODE_" "MODE_ references are expanded before launch"

section "start: iptables chains"

assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "nfqws_post chain is created"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_pre" "nfqws_pre chain is created"
# APP_MODE defaults to off, so app_rules() actively removes its chain.
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "no app chain while APP_MODE=off"
assert_file "$MOCK_IPT_STORE/iptables/nat/nfqws_nat" "nfqws_nat chain is created with NAT_FIX=1"

assert_contains "$(ipt_rules nfqws_post)" "-j NFQUEUE --queue-num 300" "outgoing traffic is queued"
assert_contains "$(ipt_rules nfqws_pre)" "-j NFQUEUE --queue-num 300" "incoming traffic is queued"
assert_contains "$(ipt_rules nfqws_pre)" "--tcp-flags syn,ack syn,ack" "SYN/ACK replies are queued"
assert_contains "$(ipt_rules nfqws_post)" "-m connbytes" "connbytes is used when the kernel has it"
assert_not_contains "$(ipt_rules nfqws_post)" "-j nfqws_qout" "no counter chain is used in connbytes mode"
assert_contains "$(ipt_rules nfqws_post)" "-o lo -j RETURN" "loopback is excluded"
assert_contains "$(ipt_rules nfqws_nat nat)" "-j MASQUERADE" "the NAT fix is installed"

post=$(ipt_count nfqws_post)
assert_ge "$post" 10 "the postrouting chain has a substantial rule set ($post rules)"

section "start: the limiter is recorded for the UI"

assert_eq "connbytes" "$(cat "$CONFDIR/state/limiter")" "the limiter state file says connbytes"

# ── stop ──────────────────────────────────────────────────────────────────────
section "stop: everything is torn down"

svc stop
assert_rc 0 "$svc_rc" "stop succeeds"
assert_no_file "$CONFDIR/state/nfqws2.pid" "the pidfile is removed"
assert_no_file "$CONFDIR/state/desired" "the desired-state marker is removed"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "nfqws_post is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_pre" "nfqws_pre is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "nfqws_app is deleted"
assert_no_file "$MOCK_IPT_STORE/iptables/nat/nfqws_nat" "nfqws_nat is deleted"

# ── connmark_out mode ─────────────────────────────────────────────────────────
section "connmark_out: a kernel without connbytes gets counter chains"

conf_reset
printf 'WATCHDOG=0\nBLOCK_QUIC=1\nIPV6_ENABLED=0\nAPP_MODE=include\n' >> "$CONFFILE"
printf 'com.termux\n' > "$CONFDIR/apps.list"
MOCK_IPT_FEATURES="multiport owner NFQUEUE"
export MOCK_IPT_FEATURES
ipt_reset

svc firewall_apply
assert_rc 0 "$svc_rc" "firewall_apply succeeds without connbytes"

assert_eq "connmark_out" "$(cat "$CONFDIR/state/limiter")" "the limiter state file says connmark_out"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_qout" "the outgoing counter chain exists"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_qin" "the incoming counter chain exists"
assert_contains "$(ipt_rules nfqws_post)" "-j nfqws_qout" "outgoing traffic goes through the counter chain"
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_app" "an app chain appears once APP_MODE is set"
assert_contains "$(ipt_rules nfqws_app)" "--uid-owner 10201" "the resolved UID is matched by owner"
assert_contains "$(ipt_rules nfqws_app)" "--set-xmark 0x10000000/0x10000000" "include mode marks matching traffic"
assert_contains "$(ipt_rules nfqws_post)" "! --mark 0x10000000/0x10000000 -j RETURN" "unmarked traffic is skipped in include mode"
assert_contains "$(ipt_rules nfqws_pre)" "-j nfqws_qin" "incoming traffic goes through the counter chain"

# The counter chain walks PKT_LIMIT_OUT down to zero and then queues.
qout=$(ipt_rules nfqws_qout)
assert_contains "$qout" "--set-xmark" "the counter chain increments the connmark counter"
assert_contains "$qout" "-j NFQUEUE --queue-num 300" "the counter chain ends in NFQUEUE"
assert_contains "$qout" "/0x0f000000" "the outgoing counter uses its own mark bits"
assert_eq "15" "$(printf '%s\n' "$qout" | grep -c -- '--set-xmark')" "PKT_LIMIT_OUT=15 yields 15 counter steps"
qin=$(ipt_rules nfqws_qin)
assert_contains "$qin" "/0x000f0000" "the incoming counter uses disjoint mark bits"

section "connmark_out: BLOCK_QUIC drops UDP/443"

assert_contains "$(ipt_rules nfqws_post)" "-p udp --dport 443 -j DROP" "QUIC is blocked in the post chain"

section "IPv6 disabled"

assert_no_file "$MOCK_IPT_STORE/ip6tables/mangle/nfqws_post" "no ip6tables chain is created"

section "refresh_connmark_counter leaves no trace"

before=$(ipt_count nfqws_qout)
svc reload >/dev/null 2>&1
refresh_connmark_counter
assert_eq "$before" "$(ipt_count nfqws_qout)" "the temporary reset rule is removed again"

# ── firewall_ok ───────────────────────────────────────────────────────────────
section "firewall_ok"

firewall_ok
assert_rc 0 $? "firewall_ok sees the installed rules"

svc firewall_stop >/dev/null 2>&1
firewall_ok
assert_rc 1 $? "firewall_ok reports missing rules after firewall_stop"

section "IPv6 enabled builds both tables"

conf_reset
printf 'WATCHDOG=0\nIPV6_ENABLED=1\n' >> "$CONFFILE"
MOCK_IPT_FEATURES="connbytes multiport owner NFQUEUE"
export MOCK_IPT_FEATURES
ipt_reset

svc firewall_apply
assert_file "$MOCK_IPT_STORE/iptables/mangle/nfqws_post" "the IPv4 chain exists"
assert_file "$MOCK_IPT_STORE/ip6tables/mangle/nfqws_post" "the IPv6 chain exists"
svc firewall_stop >/dev/null 2>&1

harness_finish
