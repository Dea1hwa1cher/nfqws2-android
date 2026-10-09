#!/system/bin/sh
ui_print "- nfqws2 DNS Profiles plugin"
MAIN=/data/adb/modules/nfqws2-android
[ -d "$MAIN" ] || abort "! Install nfqws2-android first"
[ -s "$MODPATH/lib/dns.sh" ] || abort "! Missing DNS plugin runtime"
case "$ARCH" in arm64) BIN=dnsproxy-android-arm64 ;; arm) BIN=dnsproxy-android-arm ;; x86_64) BIN=dnsproxy-android-x86_64 ;; x86) BIN=dnsproxy-android-x86 ;; *) abort "! Unsupported architecture: ${ARCH:-unknown}" ;; esac
[ -s "$MODPATH/bin/$BIN" ] || abort "! Missing DNS binary for $ARCH"
cp -f "$MODPATH/bin/$BIN" "$MODPATH/bin/dnsproxy" || abort "! Failed to install dnsproxy"
chmod 0755 "$MODPATH/bin/dnsproxy"
rm -f "$MODPATH/bin/dnsproxy-android-arm64" "$MODPATH/bin/dnsproxy-android-arm" "$MODPATH/bin/dnsproxy-android-x86_64" "$MODPATH/bin/dnsproxy-android-x86"
rm -rf "$MODPATH/bin/licenses"
mkdir -p /data/adb/nfqws2/state /data/adb/nfqws2/logs
mkdir -p /data/adb/modules/nfqws2-dns-profiles
touch "$MODPATH/plugin.active"
ui_print "- Installed. DNS Profiles entry will be available in the main WebUI."
