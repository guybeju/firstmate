#!/usr/bin/env bash
# No line under fm-board/test may send a signal to a pid found by walking up
# the process tree ($PPID or ps -o ppid). A wrapper that execs, or a parent
# that dies first, moves that pid one level up, and on a desktop the parent
# of an orphan is the user's service manager: signalling it ends the login.
# Tests send signals only through stage-8-migrate.sh's guarded helper, to a
# pid taken from $!.
#
# Usage: fm-board/test/check-signals.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
signal='kill'
ancestor='PPID|ps -o ppid'
hits=$(grep -rnE "${signal}.*(${ancestor})|(${ancestor}).*${signal}" "$TEST_DIR" || true)
if [ -n "$hits" ]; then
  printf 'not ok - a line under fm-board/test signals a pid found through its ancestry:\n%s\n' "$hits" >&2
  exit 1
fi
printf 'ok - no line under fm-board/test signals a pid found through its ancestry\n'
