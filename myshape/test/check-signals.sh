#!/usr/bin/env bash
# Static check of every test file whose tests stop a process themselves: all of
# fm-board/test, and the board's stage-7 scripts, their library, the stub
# aggregators, stage-4-writes.sh and the shared guard here; the shims the tests write are
# included, since their text lives in these files:
#   - no line may combine a signal with a pid found by walking up the process
#     tree ($PPID or ps -o ppid): a wrapper that execs, or a parent that dies
#     first, moves that pid one level up, and on a desktop the parent of an
#     orphan is the user's service manager, so signalling it ends the login;
#   - no line may use the pattern-based signal commands (p-, -all);
#   - the only signal command is the one line in signal-lib.sh's guarded
#     helper, which signals only a pid its signal-check accepted.
# It also runs helpers.sh's exit cleanup, tb_stop_boards, with an empty, a
# relative and a bare "/" TMP_ROOT, and requires that it ran no command at all.
# Comment lines are not checked. The other board stages still send signals of
# their own and are not checked here.
#
# Usage: myshape/test/check-signals.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CHECKED=("$ROOT_DIR/fm-board/test" "$TEST_DIR/signal-lib.sh" "$TEST_DIR/standalone-lib.sh" "$TEST_DIR/helpers.sh"
  "$TEST_DIR"/stage-7-*.sh "$TEST_DIR/stage-4-writes.sh" "$TEST_DIR/stub-aggregator")
signal='kill'
ancestor='PPID|ps -o ppid'
banned="p${signal}|${signal}all"
helper_file="$TEST_DIR/signal-lib.sh"
helper_line="  ${signal} -KILL \"\${verdict#accepted }\""
problems=""

code_lines() {  # <extended regex>: "file:line:text" of matching lines that are not comments.
  grep -rnE "$1" "${CHECKED[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}

hits=$(code_lines "${signal}.*(${ancestor})|(${ancestor}).*${signal}")
[ -z "$hits" ] || problems="${problems}a signal sent to a pid found through its ancestry:
$hits
"
hits=$(code_lines "(^|[^[:alnum:]_-])(${banned})([^[:alnum:]_-]|\$)")
[ -z "$hits" ] || problems="${problems}a pattern-based signal command:
$hits
"
hits=$(code_lines "(^|[^[:alnum:]_-])${signal}([[:space:]]|\$)")
allowed=$(printf '%s\n' "$hits" | awk -v file="$helper_file" -v line="$helper_line" '
  { split($0, part, ":"); text = substr($0, length(part[1]) + length(part[2]) + 3) }
  part[1] == file && text == line { n++ }
  END { print n + 0 }')
others=$(printf '%s\n' "$hits" | awk -v file="$helper_file" -v line="$helper_line" '
  $0 == "" { next }
  { split($0, part, ":"); text = substr($0, length(part[1]) + length(part[2]) + 3) }
  !(part[1] == file && text == line)')
[ -z "$others" ] || problems="${problems}a signal command outside the guarded helper:
$others
"
[ "$allowed" -eq 1 ] || problems="${problems}the guarded helper's one signal line was found $allowed times in $helper_file, not once
"
# tb_stop_boards with no usable scratch root must run nothing: every command it
# could reach is a stub that records being run.
stubs=$(mktemp -d "${TMPDIR:-/tmp}/check-signals.XXXXXX")
for name in pgrep pkill killall node ps sed sleep; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >> %s/ran\n' "$name" "$stubs" > "$stubs/$name"
  chmod +x "$stubs/$name"
done
for scratch in "" "relative/root" "/"; do
  # shellcheck source=myshape/test/helpers.sh
  (PATH="$stubs:$PATH" ROOT=$ROOT_DIR TMP_ROOT=$scratch && . "$TEST_DIR/helpers.sh" && tb_stop_boards) ||
    problems="${problems}tb_stop_boards failed with TMP_ROOT '$scratch'
"
done
if [ -s "$stubs/ran" ]; then
  problems="${problems}tb_stop_boards ran commands without an absolute scratch root:
$(cat "$stubs/ran")
"
fi
rm -r "$stubs"

if [ -n "$problems" ]; then
  printf 'not ok - signal check:\n%s' "$problems" >&2
  exit 1
fi
printf 'ok - the checked tests send signals only through the guarded helper, never by ancestry\n'
