#!/system/bin/sh
# Load installed plugins.
DNS_PLUGIN_DIR="${DNS_PLUGIN_DIR:-/data/adb/modules/nfqws2-dns-profiles}"
if [ -f "$DNS_PLUGIN_DIR/plugin.active" ] && [ -f "$DNS_PLUGIN_DIR/lib/dns.sh" ]; then
  DNS_PLUGIN=1
  . "$DNS_PLUGIN_DIR/lib/dns.sh"
elif [ -f "$MODDIR/lib/dns.sh" ]; then
  DNS_PLUGIN=1
  . "$MODDIR/lib/dns.sh"
else
  DNS_PLUGIN=0
  dns_plugin_available() { return 1; }
  dns_enabled() { return 1; }
  dns_standalone() { return 1; }
  dns_service_up() { return 0; }
  dns_start() { return 0; }
  dns_stop() { return 0; }
  dns_check() { return 0; }
  dns_boot_reset() { return 0; }
  dns_doctor() { return 0; }
  dns_backup_add() { return 0; }
  dns_backup_restore() { return 0; }
  dns_ctl() { echo "DNS profiles plugin is not installed" >&2; return 1; }
fi
