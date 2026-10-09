#!/system/bin/sh
MAIN=/data/adb/modules/nfqws2-android
if [ -x "$MAIN/service.sh" ]; then
  sh "$MAIN/service.sh" dns_stop >/dev/null 2>&1
fi
