#!/bin/sh
# extended: DNS по профилям (lib/dns.sh).
#
# Без root и сети: iptables — мок из tests/lib/mock, dnsproxy — заглушка, которая
# просто живёт; dumpsys и settings отвечают как Android. Сквозная проверка на
# настоящих dnsproxy и iptables — в описании коммита, здесь — вся логика вокруг.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
[ -f "$MODDIR/lib/dns.sh" ] || { printf 'SKIP  lib/dns.sh only exists in the extended build\n'; sandbox_cleanup; exit 0; }

cat > "$MOCKBIN/dumpsys" <<'EOF'
#!/bin/sh
echo "Active default network: 101"
echo "  NetworkAgentInfo{network{100}  lp{{InterfaceName: rmnet0 DnsAddresses: [ /10.10.10.10 ] }}"
echo "  NetworkAgentInfo{network{101}  lp{{InterfaceName: wlan0 LinkAddresses: [ 192.168.1.5/24 ] DnsAddresses: [ /192.168.1.1,/fe80::1%wlan0 ] Domains: null}}"
EOF
printf '#!/bin/sh\ncase "$*" in *specifier*) echo "${STUB_PRIVATE_HOST:-}" ;; *) echo "${STUB_PRIVATE:-off}" ;; esac\n' > "$MOCKBIN/settings"
# dnsproxy-заглушка: записывает аргументы и живёт, пока её не убьют
cat > "$MODDIR/bin/dnsproxy" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$MOCK_DIR/dnsproxy.args"
exec sleep 600
EOF
chmod 0755 "$MOCKBIN/dumpsys" "$MOCKBIN/settings" "$MODDIR/bin/dnsproxy"
export STUB_PRIVATE STUB_PRIVATE_HOST
load_common
conf_reset
printf 'WATCHDOG=0\nIPV6_ENABLED=0\n' >> "$CONFFILE"

# ── первый запуск ─────────────────────────────────────────────────────────────
section "presets are seeded as disabled profiles"

dns_init
n_pre=$(ls "$MODDIR/defaults/dns-presets" | grep -c '\.conf$')
assert_eq "$n_pre" "$(ls "$DNS_PROFILES_DIR" | grep -c '\.conf$')" "every preset becomes a profile"
assert_eq "0" "$(grep -l '^ENABLED=1' "$DNS_PROFILES_DIR"/*.conf 2>/dev/null | wc -l | tr -d ' ')" "all of them start disabled"
assert_eq "net" "$(dns_default)" "the default DNS is the network's"
for f in "$MODDIR"/defaults/dns-presets/*.conf; do
  dns_profile_check "$f" 2>/dev/null; assert_rc 0 $? "preset ${f##*/} passes the input check"
done

# ── проверка ввода ────────────────────────────────────────────────────────────
section "server addresses"

for s in 1.1.1.1 1.1.1.1:53 '[2606:4700::1111]:53' 2606:4700::1111 'fe80::1%wlan0' udp://9.9.9.9 \
         tcp://1.1.1.1 tcp://dns.google:53 https://dns.google/dns-query 'https://dns.geohide.ru:8443/dns-query' \
         h3://dns.google/dns-query tls://dns.google tls://1.1.1.1:853 quic://dns.adguard-dns.com \
         sdns://AgcAAAAAAAAABzEuMC4wLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5; do
  dns_server_ok "$s"; assert_rc 0 $? "accepted: $s"
done
for s in '' 'https://a b' 'https://x/$(id)' 'tls://host/path' 'ftp://x' 'dns.google' '1.1.1' '"1.1.1.1"' 'tls://' ; do
  dns_server_ok "$s"; assert_rc 1 $? "rejected: [$s]"
done

section "domains"

for d in instagram.com cdninstagram.com ru xn--p1ai sub.example.co.uk _dmarc.example.com a-b.c; do
  dns_domain_ok "$d"; assert_rc 0 $? "accepted: $d"
done
for d in '' -bad.com bad-.com 'a b.com' 'UPPER.com' 'a..b' '.com' 'x/y'; do
  dns_domain_ok "$d"; assert_rc 1 $? "rejected: [$d]"
done

section "profile normalisation"

out=$(printf 'NAME=  Тест  \r\nENABLED=1\nSERVER=1.1.1.1\nSERVER=1.1.1.1\nDOMAIN=*.Example.COM.\nDOMAIN=example.com\nJUNK=1\n' | dns_profile_normalize)
assert_eq "NAME=Тест
ENABLED=1
SERVER=1.1.1.1
DOMAIN=example.com" "$out" "trimmed, lower-cased, deduplicated, junk dropped"
printf 'NAME=x\n' > "$SANDBOX/many"
i=0; while [ $i -le "$DNS_MAX_SERVERS" ]; do echo "SERVER=1.1.1.$i" >> "$SANDBOX/many"; i=$((i + 1)); done
dns_profile_save many < "$SANDBOX/many" 2>/dev/null
assert_rc 1 $? "more than $DNS_MAX_SERVERS servers are refused"
assert_no_file "$DNS_PROFILES_DIR/many.conf" "and nothing is written"

# ── конфиг dnsproxy ───────────────────────────────────────────────────────────
section "dnsproxy configuration"

dns_build
assert_rc 1 $? "nothing to apply while no profile is enabled and the default is the network"

printf 'NAME=Insta\nENABLED=1\nSERVER=https://ns2.opennameserver.org/dns-query\nSERVER=tls://dns.google\nDOMAIN=instagram.com\nDOMAIN=cdninstagram.com\n' | dns_profile_save insta
printf 'NAME=Off\nENABLED=0\nSERVER=9.9.9.9\nDOMAIN=off.example\n' | dns_profile_save off
dns_build
assert_rc 0 $? "an enabled profile with domains gives a configuration"
up=$(cat "$DNS_RUN_DIR/upstreams.txt")
assert_contains "$up" "192.168.1.1:53" "the default goes to the DNS of the active network"
assert_contains "$up" "[fe80::1%wlan0]:53" "an IPv6 network DNS is bracketed"
assert_not_contains "$up" "10.10.10.10" "not the DNS of an inactive network"
assert_contains "$up" "[/instagram.com/cdninstagram.com/]https://ns2.opennameserver.org/dns-query" "domains route to the first server"
assert_contains "$up" "[/instagram.com/cdninstagram.com/]tls://dns.google" "and to the second one"
assert_not_contains "$up" "off.example" "a disabled profile is not applied"
args=$(cat "$DNS_RUN_DIR/args")
assert_contains "$args" "$DNS_PORT" "the listening port is set"
assert_contains "$args" "77.88.8.8:53" "public bootstrap servers are there as a fallback"

echo insta > "$DNS_DEFAULT_FILE"
dns_build
assert_eq "https://ns2.opennameserver.org/dns-query" "$(head -n 1 "$DNS_RUN_DIR/upstreams.txt")" "a profile as the default puts its servers first"
assert_not_contains "$(cat "$DNS_RUN_DIR/upstreams.txt")" "192.168.1.1:53" "the network DNS is then not a primary"
assert_contains "$(cat "$DNS_RUN_DIR/fallback.txt")" "192.168.1.1:53" "but stays a fallback"
echo net > "$DNS_DEFAULT_FILE"

# 250 доменов — три строки правил на сервер, по 100 доменов
printf 'NAME=Big\nENABLED=1\nSERVER=8.8.8.8\n' > "$SANDBOX/big"
i=0; while [ $i -lt 250 ]; do echo "DOMAIN=d$i.example" >> "$SANDBOX/big"; i=$((i + 1)); done
dns_profile_save big < "$SANDBOX/big"
dns_build
assert_eq "3" "$(grep -c '\]8\.8\.8\.8$' "$DNS_RUN_DIR/upstreams.txt")" "long domain lists are split into lines of 100"
rm -f "$DNS_PROFILES_DIR/big.conf"

# ── перехват ──────────────────────────────────────────────────────────────────
section "interception follows the service"

: > "$DNS_ENABLED_FILE"
svc start
assert_rc 0 "$svc_rc" "the service starts"
assert_file "$DNS_PIDFILE" "dnsproxy is started with it"
assert_contains "$(cat "$MOCK_DIR/dnsproxy.args")" "$DNS_RUN_DIR/upstreams.txt" "with the generated upstream list"
nat=$(ipt_rules nfqws_dns nat)
assert_contains "$nat" "-m mark --mark 0x0/0xffff -j RETURN" "packets without a netd mark are left alone (no loop)"
assert_contains "$nat" "-p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT" "UDP DNS goes to dnsproxy"
assert_contains "$nat" "-p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT" "TCP DNS too"
assert_contains "$(ipt_rules OUTPUT nat)" "-j nfqws_dns" "OUTPUT jumps into the chain"
assert_contains "$(ipt_rules nfqws_dns nat ip6tables)" "REDIRECT" "IPv6 is redirected when ip6tables has nat"

pid=$(cat "$DNS_PIDFILE")
dns_start
assert_eq "$pid" "$(cat "$DNS_PIDFILE")" "an unchanged configuration does not restart dnsproxy"

kill "$pid"; sleep 0.3
dns_check
assert_ne_pid=$(cat "$DNS_PIDFILE" 2>/dev/null)
[ -n "$assert_ne_pid" ] && [ "$assert_ne_pid" != "$pid" ] && kill -0 "$assert_ne_pid" 2>/dev/null
assert_rc 0 $? "the watchdog check restarts a dead dnsproxy"

svc stop
assert_no_file "$DNS_PIDFILE" "stopping the service stops dnsproxy"
assert_eq "" "$(ipt_rules OUTPUT nat | grep nfqws_dns)" "and removes the jump"
assert_no_file "$MOCK_IPT_STORE/iptables/nat/nfqws_dns" "and the chain"

rm -f "$DNS_ENABLED_FILE"
svc start
assert_no_file "$DNS_PIDFILE" "with the feature off the service starts without dnsproxy"
svc stop

# ── команды WebUI ─────────────────────────────────────────────────────────────
section "nfqws2-ctl dns-*"

ctl dns-state
assert_contains "$ctl_out" "#status" "dns-state has a status section"
assert_contains "$ctl_out" "enabled=0" "it reports the feature as off"
assert_contains "$ctl_out" "private=off" "and the Private DNS mode"
assert_contains "$ctl_out" "#profile insta" "profiles follow"
assert_contains "$ctl_out" "#preset meta" "and presets"

STUB_PRIVATE=hostname; STUB_PRIVATE_HOST=dns.google
ctl dns-state
assert_contains "$ctl_out" "private=hostname" "Private DNS with a host is detected"
assert_contains "$ctl_out" "private_host=dns.google" "with the host name"
STUB_PRIVATE=off; STUB_PRIVATE_HOST=

ctl dns-save-b64 new1 "$(b64 'NAME=Новый
ENABLED=1
SERVER=tls://dns.comss.one
DOMAIN=chatgpt.com')"
assert_rc 0 "$ctl_rc" "a profile is saved"
assert_file "$DNS_PROFILES_DIR/new1.conf" "under its id"
ctl dns-save-b64 new2 "$(b64 'NAME=Плохой
SERVER=tls://a b')"
assert_rc 1 "$ctl_rc" "a bad server address is refused"
assert_contains "$ctl_out" "Неверный адрес" "with a reason"
ctl dns-save-b64 '../evil' "$(b64 'NAME=x')"
assert_rc 1 "$ctl_rc" "a path in the id is refused"

ctl dns-profile-enable new1 0
assert_contains "$(cat "$DNS_PROFILES_DIR/new1.conf")" "ENABLED=0" "a profile can be switched off"
ctl dns-set-default new1
assert_eq "new1" "$(dns_default)" "a profile can be the default"
ctl dns-set-default nosuch
assert_rc 1 "$ctl_rc" "an unknown default is refused"
ctl dns-delete new1
assert_no_file "$DNS_PROFILES_DIR/new1.conf" "a profile is deleted"
assert_eq "net" "$(dns_default)" "deleting the default profile falls back to the network DNS"
ctl dns-set-enabled 1
assert_file "$DNS_ENABLED_FILE" "the feature is switched on"
ctl dns-set-enabled 0
assert_no_file "$DNS_ENABLED_FILE" "and off"

section "backup carries the profiles"

: > "$DNS_ENABLED_FILE"; echo insta > "$DNS_DEFAULT_FILE"
BACKUP_DIR_OLD="${NFQWS_BACKUP_DIR:-}"
NFQWS_BACKUP_DIR="$SANDBOX/dl"; export NFQWS_BACKUP_DIR
ctl backup-create
assert_rc 0 "$ctl_rc" "a backup is created"
name=$(printf '%s' "$ctl_out" | head -n 1 | cut -f1)
rm -f "$DNS_PROFILES_DIR/insta.conf" "$DNS_ENABLED_FILE"; echo net > "$DNS_DEFAULT_FILE"
ctl backup-restore "$name"
assert_rc 0 "$ctl_rc" "and restored"
assert_file "$DNS_PROFILES_DIR/insta.conf" "the profile is back"
assert_file "$DNS_ENABLED_FILE" "the feature state is back"
assert_eq "insta" "$(dns_default)" "the default is back"

harness_finish
