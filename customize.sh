#!/system/bin/sh

# grab own info (version)
versionCode=$(grep versionCode "$MODPATH/module.prop" | sed 's/versionCode=//g' )

ui_print "*******************************************"
ui_print "- nfqws2-android"
ui_print "- v$versionCode "
ui_print "*******************************************"

case "$ARCH" in
  arm64) BIN=android-arm64 ;;
  arm) BIN=android-arm ;;
  x86_64) BIN=android-x86_64 ;;
  x86) BIN=android-x86 ;;
  *) abort "! Unsupported architecture: ${ARCH:-unknown}" ;;
esac
ui_print "- Architecture: $ARCH -> $BIN"

case "$BIN" in
  android-arm64|android-arm|android-x86_64|android-x86) ;;
  *) abort "! Invalid binary target: $BIN" ;;
esac

for f in \
  service.sh action.sh uninstall.sh lib/common.sh bin/nfqws2-ctl \
  defaults/nfqws2.conf \
  "binaries/$BIN/nfqws2"
do
  [ -s "$MODPATH/$f" ] || abort "! Missing or empty module file: $f"
done

cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2" ||
  abort "! Failed to install nfqws2 binary"
[ -s "$MODPATH/bin/nfqws2" ] || abort "! Installed nfqws2 binary is empty"
rm -rf "$MODPATH/binaries"

CONF=/data/adb/nfqws2
mkdir -p "$CONF/lists" "$CONF/state" "$CONF/logs" "$CONF/imports" "$CONF/strategies" ||
  abort "! Cannot create $CONF; check /data/adb access"

if [ -f "$CONF/nfqws2.conf" ]; then
  ui_print "- Keeping existing config: $CONF/nfqws2.conf"
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf.dist" ||
    abort "! Failed to save the default config"
else
  cp -f "$MODPATH/defaults/nfqws2.conf" "$CONF/nfqws2.conf" ||
    abort "! Failed to create $CONF/nfqws2.conf"
  ui_print "- Created config: $CONF/nfqws2.conf"
fi

DIST="$CONF/lists/.dist"
PEND="$CONF/lists/.pending"
mkdir -p "$DIST" "$PEND" || abort "! Cannot create list update directories"

for src in "$MODPATH"/lists/*.list; do
  [ -f "$src" ] || continue
  f=${src##*/}
  dst="$CONF/lists/$f"

  if [ "$f" = auto.list ]; then
    if [ ! -f "$dst" ]; then
      cp -f "$src" "$dst" || abort "! Failed to install $f"
    fi
    cp -f "$src" "$DIST/$f" || abort "! Failed to save release copy of $f"
    continue
  fi

  if [ ! -f "$dst" ] || cmp -s "$src" "$dst"; then
    cp -f "$src" "$dst" || abort "! Failed to install $f"
    rm -f "$PEND/$f"
  elif [ -f "$DIST/$f" ] && cmp -s "$src" "$DIST/$f"; then
    :
  elif [ -f "$DIST/$f" ] && cmp -s "$dst" "$DIST/$f"; then
    cp -f "$src" "$dst" || abort "! Failed to update $f"
    rm -f "$PEND/$f"
  elif [ ! -f "$DIST/$f" ]; then
    case " user exclude ipset ipset_exclude probe_hosts " in
      *" ${f%.list} "*)
        cp -f "$src" "$PEND/$f" || abort "! Failed to save pending update for $f"
        ui_print "- $f has local changes; the release version is available in the WebUI"
        ;;
      *)
        cp -f "$src" "$dst" || abort "! Failed to migrate $f"
        rm -f "$PEND/$f"
        ;;
    esac
  else
    cp -f "$src" "$PEND/$f" || abort "! Failed to save pending update for $f"
    ui_print "- $f has local changes; the release version is available in the WebUI"
  fi

  cp -f "$src" "$DIST/$f" || abort "! Failed to save release copy of $f"
done

if [ ! -f "$CONF/apps.list" ]; then
  printf '%s\n' "# App packages (APP_MODE=include|exclude), one per line" > "$CONF/apps.list" ||
    abort "! Failed to create $CONF/apps.list"
fi
if [ ! -f "$CONF/home_wifi.list" ]; then
  printf '%s\n' "# Home Wi-Fi SSIDs, one per line" > "$CONF/home_wifi.list" ||
    abort "! Failed to create $CONF/home_wifi.list"
fi

# set perms to nfwqws2
busybox chmod +x "$MODPATH/bin/nfqws2"
busybox chmod +x "$MODPATH/bin/nfqws2-ctl"

ui_print "- Installation complete! Reboot your device."
