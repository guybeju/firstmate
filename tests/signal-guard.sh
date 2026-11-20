#!/bin/sh
# tests/signal-guard.sh - the verdict of signal policy P-010 on one signal call.
#
# Usage: sh tests/signal-guard.sh <self-pid> <log-file-or-empty> <source> <signal> [pid...]
#        sh tests/signal-guard.sh <self-pid> <log-file-or-empty> <source> <signal> \
#          --below <recorded-pid> <command-glob> <stand-in-pid>
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
# --below names a process under a recorded child instead: the one the case
# means to crash sits between the child and a stand-in that stopped at a crash
# point. The stand-in pid only proposes where to look; the guard decides live.
# <recorded-pid> must pass every check above. Walking up from <stand-in-pid>
# must reach <recorded-pid> without meeting pid 1 or less, the test script or
# the signalling shell. Among the processes on that walk, below
# <recorded-pid>, those whose whole command line matches <command-glob> (a
# shell pattern that must not start with *) are the candidates. A forked
# subshell has the same command line as the process it copies and sits below
# it, so only a candidate whose parent does not match is kept. Exactly one
# must be left, and it must not be a systemd process.
#
# With a log file it appends one line: the source, the raw arguments as
# received, the shell, the parsed target, its command, the verdict, and the
# target's ancestry up to pid 1 (for a refused --below call, the stand-in's).
set -u

self=$1 log=$2 source=$3
shift 3
raw="argc=$#"
for arg in "$@"; do raw="$raw [$arg]"; done
signal=${1-}
[ "$#" -eq 0 ] || shift
target=- command=- parent=- walk_from=

ps_field() {  # <field> <pid>: one field of <pid>, empty when it is gone.
  command -p ps -o "$1=" -p "$2" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

judge_pid() {  # <pid>: prints the verdict on a pid already parsed as digits.
  if [ "$1" -le 1 ]; then
    echo "refused: pid $1 is 1 or less"
  elif [ "$1" = "${FM_TEST_SUITE_PID:-}" ]; then
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
matches_glob() {  # <pid>: 0 when its whole command line matches the glob.
  # shellcheck disable=SC2254 # the glob is the pattern, deliberately unquoted.
  case "$(ps_field args "$1")" in $glob) return 0 ;; esac
  return 1
}

judge_below() {  # <recorded> <stand-in>: prints the verdict on the --below form.
  recorded_verdict=$(command=$(ps_field args "$1"); parent=$(ps_field ppid "$1"); judge_pid "$1")
  case "$recorded_verdict" in
    "accepted "*) ;;
    *) echo "refused: the recorded child: ${recorded_verdict#refused: }"; return ;;
  esac
  segment="" pid=$2 levels=0
  while [ "$pid" != "$1" ]; do
    if [ -z "$pid" ] || [ "$pid" -le 1 ] 2>/dev/null || [ "$pid" = "${FM_TEST_SUITE_PID:-}" ] ||
      [ "$pid" = "$self" ] || [ "$levels" -ge 64 ]; then
      echo "refused: stand-in $2 is not below the recorded child $1 (the walk up stopped at '${pid:-none}')"
      return
    fi
    segment="$segment $pid"
    pid=$(ps_field ppid "$pid")
    levels=$((levels + 1))
  done
  found="" count=0
  for pid in $segment; do
    matches_glob "$pid" || continue
    matches_glob "$(ps_field ppid "$pid")" && continue
    found=$pid count=$((count + 1))
  done
  if [ "$count" -ne 1 ]; then
    echo "refused: $count processes between stand-in $2 and the recorded child $1 match '$glob' with a parent that does not, not exactly one"
    return
  fi
  if [ "$found" -le 1 ] || [ "$found" = "$1" ] || [ "$found" = "${FM_TEST_SUITE_PID:-}" ] ||
    [ "$found" = "${FM_TEST_SUITE_PARENT:-}" ] || [ "$found" = "$self" ]; then
    echo "refused: pid $found is 1 or less, the recorded child, the test script, its parent or the signalling shell"
    return
  fi
  case "$(ps_field args "$found")" in
    *systemd*) echo "refused: pid $found is the service manager" ;;
    *) echo "accepted $found" ;;
  esac
}

if [ "$signal_ok" -eq 0 ]; then
  verdict="refused: '$signal' is not one of the signal names TERM KILL STOP CONT INT HUP QUIT"
elif [ "${1-}" = --below ]; then
  glob=${3-}
  if [ "$#" -ne 4 ]; then
    verdict="refused: --below takes a recorded pid, a command glob and a stand-in pid, got $(($# - 1)) arguments"
  elif [ -z "$glob" ] || [ "${glob#\*}" != "$glob" ]; then
    verdict="refused: the command glob '$glob' is empty or starts with *"
  else
    verdict=""
    for arg in "$2" "$4"; do
      case "$arg" in
        '' | 0* | *[!0-9]*) verdict="refused: '$arg' is not a positive pid" ;;
      esac
    done
    if [ -z "$verdict" ]; then
      walk_from=$4
      verdict=$(judge_below "$2" "$4")
      case "$verdict" in
        "accepted "*)
          target=${verdict#accepted }
          walk_from=$target
          command=$(ps_field args "$target")
          ;;
      esac
    fi
  fi
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
      verdict=$(judge_pid "$target")
      ;;
  esac
fi

if [ -n "$log" ]; then
  chain="" pid=${walk_from:-$target} levels=0
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
