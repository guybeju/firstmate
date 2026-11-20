#!/bin/sh
# tests/signal-guard.sh - the verdict of signal policy P-010 on one signal call.
#
# Usage: sh tests/signal-guard.sh <self-pid> <log-file-or-empty> <source> <signal> [pid...]
#
# Prints "accepted <pid>" or "refused: <why>" and never signals anything.
# fm_test_signal in tests/lib.sh is its caller and the only code that sends the
# signal it accepts. <self-pid> is the shell that would send it, and
# FM_TEST_RECORDED_CHILDREN holds the space-separated pids that shell recorded
# with fm_test_record_child right after starting each one with `&`.
#
# Accepted is exactly one signal name from TERM KILL STOP CONT INT HUP QUIT, then
# exactly one pid, written in digits with no leading 0, that is greater than 1, is
# not the test script FM_TEST_SUITE_PID, its parent FM_TEST_SUITE_PARENT or
# <self-pid>, is not a systemd process (the user's service manager adopts
# orphans on a desktop, and the same user may signal it), is in
# FM_TEST_RECORDED_CHILDREN, and whose parent is <self-pid>. Everything else is
# refused: an empty or missing pid, 0, -1, negative pids and process groups,
# flags, several pids, and any pid found by walking up the process tree.
#
# With a log file it appends one line: the source, the raw arguments as
# received, the shell, the parsed target, its command, the verdict, and the
# target's ancestry up to pid 1.
set -u

self=$1 log=$2 source=$3
shift 3
raw="argc=$#"
for arg in "$@"; do raw="$raw [$arg]"; done
signal=${1-}
[ "$#" -eq 0 ] || shift
target=- command=- parent=-

ps_field() {  # <field> <pid>: one field of <pid>, empty when it is gone.
  command -p ps -o "$1=" -p "$2" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

judge_pid() {  # <pid>: prints the verdict on a pid already parsed as > 1.
  if [ "$1" = "${FM_TEST_SUITE_PID:-}" ]; then
    echo "refused: pid $1 is the test script itself"
  elif [ "$1" = "${FM_TEST_SUITE_PARENT:-}" ]; then
    echo "refused: pid $1 is the test script's parent"
  elif [ "$1" = "$self" ]; then
    echo "refused: pid $1 is the signalling shell itself"
  else
    case "$command" in
      *systemd*) echo "refused: pid $1 is the service manager '$command'" ;;
      *)
        case " ${FM_TEST_RECORDED_CHILDREN:-} " in
          *" $1 "*)
            if [ "$parent" = "$self" ]; then
              echo "accepted $1"
            else
              echo "refused: pid $1 is not a child of the signalling shell $self (its parent: ${parent:-none})"
            fi
            ;;
          *) echo "refused: pid $1 is not a recorded child (fm_test_record_child after its own &)" ;;
        esac
        ;;
    esac
  fi
}

case "$signal" in
  TERM | KILL | STOP | CONT | INT | HUP | QUIT) signal_ok=1 ;;
  *) signal_ok=0 ;;
esac
if [ "$signal_ok" -eq 0 ]; then
  verdict="refused: '$signal' is not one of the signal names TERM KILL STOP CONT INT HUP QUIT"
elif [ "$#" -ne 1 ]; then
  verdict="refused: takes exactly one pid, got $#"
else
  case "$1" in
    '') verdict="refused: the pid is empty" ;;
    *[!0-9]*) verdict="refused: '$1' is not a positive pid (a flag, a negative pid or a process group)" ;;
    0*) verdict="refused: '$1' is 0 or starts with 0" ;;
    *)
      target=$1
      parent=$(ps_field ppid "$target")
      command=$(ps_field args "$target")
      if [ "$target" -le 1 ]; then
        verdict="refused: pid $target is 1 or less"
      else
        verdict=$(judge_pid "$target")
      fi
      ;;
  esac
fi

if [ -n "$log" ]; then
  chain="" pid=$target levels=0
  while [ "$pid" != - ] && [ -n "$pid" ] && [ "$levels" -lt 64 ]; do
    chain="$chain < $pid $(ps_field args "$pid")"
    [ "$pid" -gt 1 ] 2>/dev/null || break
    pid=$(ps_field ppid "$pid")
    levels=$((levels + 1))
  done
  printf 'source=%s | raw: %s | shell=%s | target=%s command=%s | %s | ancestry: %s\n' \
    "$source" "$raw" "$self" "$target" "${command:--}" "$verdict" "${chain# < }" >> "$log"
fi
printf '%s\n' "$verdict"
