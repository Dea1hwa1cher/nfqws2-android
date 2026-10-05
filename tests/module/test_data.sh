#!/bin/sh
# Data-integrity tests: the shipped configs, lists, blobs and metadata must stay
# mutually consistent. These need no sandbox and no Android tools — they only
# read the repository, so they are cheap and run first.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

# ── shell syntax ──────────────────────────────────────────────────────────────
section "shell syntax"

SCRIPTS="action.sh customize.sh service.sh uninstall.sh bin/nfqws2-ctl lib/common.sh"
for f in $SCRIPTS; do
  sh -n "$REPO_DIR/$f" 2>/dev/null
  assert_rc 0 $? "$f parses under sh"
done
for f in $SCRIPTS; do
  dash -n "$REPO_DIR/$f" 2>/dev/null
  assert_rc 0 $? "$f parses under dash"
done

section "line endings"

# Android's sh reads a CRLF script as garbage ("\r: not found" on every line).
for f in $SCRIPTS; do
  if grep -q "$(printf '\r')" "$REPO_DIR/$f" 2>/dev/null; then
    _fail "$f contains CR characters"
  else
    _ok "$f is LF-only"
  fi
done

# ── module.prop ───────────────────────────────────────────────────────────────
section "module.prop"

PROP="$REPO_DIR/module.prop"
for key in id name version versionCode author description; do
  assert_match "$(cat "$PROP")" "^$key=" "module.prop declares $key"
done
assert_match "$(sed -n 's/^version=//p' "$PROP")" '^v[0-9]+\.[0-9]+\.[0-9]+$' "version looks like vX.Y.Z"
assert_match "$(sed -n 's/^versionCode=//p' "$PROP")" '^[0-9]+$' "versionCode is numeric"
assert_eq "$(sed -n 's/^id=//p' "$PROP")" "nfqws2-android" "id matches the module directory name"

# ── configs ───────────────────────────────────────────────────────────────────
section "shipped configs"

assert_file "$REPO_DIR/defaults/nfqws2.conf" "defaults/nfqws2.conf exists"

for f in "$REPO_DIR"/defaults/nfqws2.conf "$REPO_DIR"/strategies/*.conf; do
  b="${f##*/}"
  out=$(awk '/`/ { print "backtick" } /\$\(/ { print "cmdsubst" }' "$f")
  if [ -z "$out" ]; then _ok "$b has no backticks or command substitution"
  else _fail "$b contains forbidden syntax: $out"; fi
done

# ── strategy references ───────────────────────────────────────────────────────
section "strategy references resolve"

# Mirrors the aliases lib/common.sh creates at runtime, so a strategy may refer
# to e.g. stun2.bin even though only stun.bin ships.
blob_alias_target() {
  case "$1" in
    quic_initial_www_google_com.bin) echo quic_initial.bin ;;
    tls_clienthello_www_google_com.bin|tls_clienthello_max_ru.bin|tls_clienthello_sochi_park.bin) echo tls_clienthello.bin ;;
    stun2.bin) echo stun.bin ;;
    stun.bin) echo stun2.bin ;;
    ACTIVE_DISCORD_UDP.bin) echo discord_udp.bin ;;
    discord_udp.bin) echo ACTIVE_DISCORD_UDP.bin ;;
    ACTIVE_GAME_UDP.bin) echo ACTIVE_DISCORD_UDP.bin ;;
    quic_initial_5ka_ru.bin|quic_initial_vk_com.bin|quic_initial_steamcommunity_com.bin) echo quic_initial.bin ;;
    quic_initial_4pda_to.bin|quic_initial_dbankcloud_ru.bin|quic_initial_my_youtube.bin) echo quic_initial.bin ;;
    *) echo "" ;;
  esac
}

missing_blobs=0
missing_lists=0
for f in "$REPO_DIR"/defaults/nfqws2.conf "$REPO_DIR"/strategies/*.conf; do
  for b in $(grep -o '\$BLOBS_DIR/[A-Za-z0-9_.-]*' "$f" | sed 's|\$BLOBS_DIR/||' | sort -u); do
    if [ -f "$REPO_DIR/blobs/$b" ]; then continue; fi
    alias=$(blob_alias_target "$b")
    if [ -n "$alias" ] && [ -f "$REPO_DIR/blobs/$alias" ]; then continue; fi
    missing_blobs=$((missing_blobs + 1))
    _fail "${f##*/} references missing blob $b"
  done
  for l in $(grep -o '\$LISTS_DIR/[A-Za-z0-9_.-]*' "$f" | sed 's|\$LISTS_DIR/||' | sort -u); do
    if [ -f "$REPO_DIR/lists/$l" ] || [ -f "$REPO_DIR/defaults/lists/$l" ]; then continue; fi
    missing_lists=$((missing_lists + 1))
    _fail "${f##*/} references missing list $l"
  done
done
[ "$missing_blobs" = 0 ] && _ok "every referenced blob exists (directly or as a runtime alias)"
[ "$missing_lists" = 0 ] && _ok "every referenced list exists"

# ── lists vs defaults/lists ───────────────────────────────────────────────────
section "lists/ and defaults/lists/ agree"

# These two copies drifted apart once already (commit af8101b): customize.sh
# installs from lists/, while reset-lists restores from defaults/lists/, so a
# stale copy in either place makes "fresh install" and "reset lists" produce
# different results — silently re-adding entries one of them had dropped.
list_lines() { grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null || echo 0; }

for f in "$REPO_DIR"/defaults/lists/*.list; do
  b="${f##*/}"
  if [ ! -f "$REPO_DIR/lists/$b" ]; then
    _fail "lists/$b is missing while defaults/lists/$b exists"
    continue
  fi
  if cmp -s "$f" "$REPO_DIR/lists/$b"; then
    _ok "lists/$b matches defaults/lists/$b"
  else
    _fail "lists/$b differs from defaults/lists/$b ($(list_lines "$REPO_DIR/lists/$b") vs $(list_lines "$f") entries)"
  fi
done

section "lists are sane"

for f in "$REPO_DIR"/lists/*.list; do
  b="${f##*/}"
  bad=$(grep -nE '^[^#]*[[:space:]]+[^[:space:]]' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*$' | head -1)
  # ipset lists are "1.2.3.0/24" style and exclude lists may carry comments;
  # a stray CR is the real hazard here.
  if grep -q "$(printf '\r')" "$f" 2>/dev/null; then
    _fail "lists/$b contains CR characters"
  else
    _ok "lists/$b has no CR characters"
  fi
done

# ── installer ─────────────────────────────────────────────────────────────────
section "installer covers the shipped binaries"

for d in "$REPO_DIR"/binaries/*/; do
  b="${d%/}"; b="${b##*/}"
  case "$b" in
    android-arm64)  pat='arm64\*|aarch64\*' ;;
    android-arm)    pat='armeabi\*|arm\*' ;;
    android-x86_64) pat='x86_64\*' ;;
    android-x86)    pat='x86\*' ;;
    *) pat="__none__" ;;
  esac
  assert_match "$(cat "$REPO_DIR/customize.sh")" "$pat" "customize.sh maps ABI $b"
  assert_file "$d/nfqws2" "binaries/$b/nfqws2 exists"
done

section "installer wires up the runtime"

assert_contains "$(cat "$REPO_DIR/customize.sh")" 'cp -f "$MODPATH/binaries/$BIN/nfqws2" "$MODPATH/bin/nfqws2"' \
  "customize.sh installs the picked binary as bin/nfqws2"
for f in user exclude ipset ipset_exclude auto probe_hosts; do
  assert_contains "$(cat "$REPO_DIR/customize.sh")" "$f" "customize.sh seeds $f.list"
done

section "service entry points the WebUI relies on"

for cmd in start stop restart reload status firewall_apply firewall_stop; do
  assert_contains "$(cat "$REPO_DIR/service.sh")" "$cmd)" "service.sh handles $cmd"
done

harness_finish
