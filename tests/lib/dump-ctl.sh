#!/bin/sh
# Prints the output of one nfqws2-ctl command, run against a fresh sandbox.
#
# Exists so tests written in another language (the WebUI contract test is Node)
# can check themselves against the real ctl instead of a hand-written fixture.
#
#   dump-ctl.sh json-status
#   dump-ctl.sh list-strategies
#
# The sandbox is removed afterwards, so the caller sees nothing but the output.

HERE=$(cd "$(dirname "$0")" && pwd)
TESTS_DIR=$(cd "$HERE/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
. "$TESTS_DIR/lib/harness.sh"

sandbox_init
conf_reset
printf 'WATCHDOG=0\n' >> "$CONFDIR/nfqws2.conf"

ctl "$@"
printf '%s\n' "$ctl_out"

sandbox_cleanup
