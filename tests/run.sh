#!/bin/sh
# Regression suite for the nfqws2-android module and its WebUI.
#
#   sh tests/run.sh              # everything
#   sh tests/run.sh --fast       # skip the slow service/rule-set and browser tests
#   sh tests/run.sh --keep       # keep the sandboxes for inspection
#
# Exit status is 0 only when every suite passed.
#
# Runtime note: on Windows/Git Bash every process spawn costs a few hundred
# milliseconds, and these suites spawn thousands of them, so a full run takes
# several minutes. On Linux the same suite finishes in seconds.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$HERE/.." && pwd)

FAST=0
for a in "$@"; do
  case "$a" in
    --fast) FAST=1 ;;
    --keep) NFQWS_TEST_KEEP=1 ;;
    -h|--help)
      printf 'usage: sh tests/run.sh [--fast] [--keep]\n'
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
  esac
done
export NFQWS_TEST_KEEP="${NFQWS_TEST_KEEP:-0}"

WORK=$(mktemp -d "${NFQWS_TEST_TMP:-/tmp}/nfqws2-run.XXXXXX") || exit 1
cleanup() { find "$WORK" -delete 2>/dev/null; rmdir "$WORK" 2>/dev/null; }
trap 'cleanup' EXIT INT TERM

RESULTS=""
FAILED=0

run_suite() { # <label> <command...>
  label="$1"; shift
  printf '\n########## %s\n' "$label"
  if "$@" > "$WORK/out.txt" 2>&1; then
    cat "$WORK/out.txt"
    RESULTS="$RESULTS
   PASS  $label"
  else
    cat "$WORK/out.txt"
    RESULTS="$RESULTS
   FAIL  $label"
    FAILED=$((FAILED + 1))
  fi
}

skip_suite() {
  printf '\n########## %s\n' "$1"
  printf '   SKIP  %s\n' "$2"
  RESULTS="$RESULTS
   SKIP  $1 ($2)"
}

# ── tooling ───────────────────────────────────────────────────────────────────
SHELLS=""
for s in ${NFQWS_TEST_SHELLS:-dash bash}; do
  command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"
done
[ -n "$SHELLS" ] || SHELLS=" sh"

NODE_BIN="${NFQWS_TEST_NODE:-}"
if [ -z "$NODE_BIN" ]; then
  if command -v node >/dev/null 2>&1; then
    NODE_BIN=node
  elif [ -x "$HOME/.workbuddy-ai/binaries/node/versions/22.22.2-3/node.exe" ]; then
    NODE_BIN="$HOME/.workbuddy-ai/binaries/node/versions/22.22.2-3/node.exe"
  fi
fi

# Playwright is not a dependency of the module; point NODE_PATH at a workspace
# that has it, or the browser suite skips itself.
if [ -z "${NODE_PATH:-}" ] && [ -d "$HOME/.workbuddy-ai/binaries/node/workspace/node_modules" ]; then
  NODE_PATH="$HOME/.workbuddy-ai/binaries/node/workspace/node_modules"
fi
export NODE_PATH="${NODE_PATH:-}"

printf 'nfqws2-android regression suite\n'
printf 'repo:    %s\n' "$REPO_DIR"
printf 'shells: %s\n' "$SHELLS"
printf 'node:   %s\n' "${NODE_BIN:-<not found>}"

# ── module ────────────────────────────────────────────────────────────────────
run_suite "module: data integrity" sh "$HERE/module/test_data.sh"
run_suite "module: packaging" sh "$HERE/module/test_packaging.sh"

for s in $SHELLS; do
  run_suite "module: lib/common.sh under $s" "$s" "$HERE/module/test_common.sh"
done

run_suite "module: nfqws2-ctl" sh "$HERE/module/test_ctl.sh"

if [ "$FAST" = 1 ]; then
  skip_suite "module: service and firewall" "--fast"
else
  run_suite "module: service and firewall" sh "$HERE/module/test_service.sh"
fi

# ── webui ─────────────────────────────────────────────────────────────────────
if [ -z "$NODE_BIN" ]; then
  skip_suite "webui: static invariants" "node not found"
  skip_suite "webui: ctl contract" "node not found"
  skip_suite "webui: rendered geometry" "node not found"
else
  run_suite "webui: static invariants" "$NODE_BIN" "$HERE/webui/test_static.js"

  # The contract test compares index.html against the real ctl, so the ctl
  # output is produced here and handed over as files.
  sh "$HERE/lib/dump-ctl.sh" json-status > "$WORK/json-status.txt" 2>/dev/null
  sh "$HERE/lib/dump-ctl.sh" list-strategies > "$WORK/list-strategies.txt" 2>/dev/null
  if [ -s "$WORK/json-status.txt" ]; then
    run_suite "webui: ctl contract" "$NODE_BIN" "$HERE/webui/test_contract.js" \
      "$WORK/json-status.txt" "$WORK/list-strategies.txt"
  else
    skip_suite "webui: ctl contract" "could not collect json-status from the sandbox"
  fi

  if [ "$FAST" = 1 ]; then
    skip_suite "webui: rendered geometry" "--fast"
  else
    run_suite "webui: rendered geometry" "$NODE_BIN" "$HERE/webui/test_layout.js"
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n========================================\n'
printf 'summary%s\n' "$RESULTS"
printf '========================================\n'

if [ "$FAILED" -eq 0 ]; then
  printf 'all suites passed\n'
  exit 0
fi
printf '%d suite(s) failed\n' "$FAILED"
exit 1
