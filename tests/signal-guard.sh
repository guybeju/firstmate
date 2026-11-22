#!/usr/bin/env bash
# tests/signal-guard.sh - the guarded helper of signal policy P-010: the verdict
# on one signal call, and the one place a test's computed signal is sent.
#
# Verdict only (never signals):
#   sh tests/signal-guard.sh <self-pid> <log-file-or-empty> <source> <signal> <form>
# Judge and send (the caller is this process's own parent, never an argument):
#   tests/signal-guard.sh --send <source> <signal> <form>
# where <form> is one of
#   <pid>                                         a recorded child of the caller
#   --below <recorded-pid> <command-glob> <stand-in-pid>
#   --identity <pid>                              a process with evidence of this run
#   --env-path <NAME> <pid>                       a process whose listed variable holds a run path
#   --group <leader-pid>                          a group whose live leader has evidence
#   --members <group-id>                          each live member of a group, one by one
#
# --send must be run directly as a program with an argument list (Perl
# `system LIST`, Python's subprocess list, Node's spawn args, or a plain shell
# command), never through a shell string, so that its parent is the caller.
# It prints one verdict line per target. It exits 0 when every target was
# accepted (and, outside log-only mode, signalled), 1 when any was refused
# (nothing is sent to a refused target), 2 on a usage error, and 3 when an
# accepted target was gone by the time of the send. In log-only mode
# (FM_TEST_SIGNAL_DRY_RUN set, FM_TEST_SIGNAL_LOG an absolute path) it sends
# nothing and appends its record to FM_TEST_SIGNAL_LOG.
#
# Every form refuses pid 1 or less, the test script FM_TEST_SUITE_PID, its
# parent FM_TEST_SUITE_PARENT, the signalling shell, every ancestor of the
# signalling shell from the test script upward (all of its ancestors when the
# test script is not among them; an ancestor between the test script and the
# signalling shell, such as the script a stand-in interrupts, still needs its
# own evidence), any systemd process (the user's service manager adopts
# orphans on a desktop, and the same user may signal it), and every argument
# that is not exactly one positive pid in digits with no leading 0 (empty or
# missing, 0, -1, negative pids, flags, several pids). Accepted signal names:
# TERM KILL STOP CONT INT HUP QUIT.
#
# <pid> is accepted only when it is in FM_TEST_RECORDED_CHILDREN (pids the
# caller recorded with fm_test_record_child right after starting each one with
# `&`) and its parent is the signalling shell.
#
# --below names a process under a recorded child: the one the case means to
# crash sits between the child and a stand-in that stopped at a crash point.
# The stand-in pid only proposes where to look; the guard decides live.
# <recorded-pid> must pass the checks above. Walking up from <stand-in-pid>
# must reach <recorded-pid> without meeting pid 1 or less, the test script or
# the signalling shell. Among the processes on that walk, below
# <recorded-pid>, those whose whole command line matches <command-glob> (a
# shell pattern that must not start with *) are the candidates. A forked
# subshell has the same command line as the process it copies and sits below
# it, so only a candidate whose parent does not match is kept. Exactly one
# must be left, and it must not be a systemd process.
#
# --identity names a process the test did not start itself as a plain
# background command (a grandchild, a daemon a fixture started, a pid a
# product wrote to a file), the first supplement of P-010. It must carry
# evidence that it belongs to this test run, read here, live, before any send:
#   path      its command line contains a root listed in the file
#             FM_TEST_RUN_ROOTS (the run's fm_test_tmproot registry) whose
#             .fm-test-fixture marker names FM_TEST_SUITE_PID as its owner,
#             followed by / or the end of a word;
#   env       its environment holds FM_TEST_RUN_MARKS with FM_TEST_RUN_MARK
#             (this run's own mark) as one of its words (Linux reads
#             /proc/<pid>/environ; elsewhere ps -E, which cannot read a
#             platform binary's environment, so that evidence is absent there);
#   ancestry  walking up its parents reaches FM_TEST_SUITE_PID.
# Depth and parentage alone are never evidence.
#
# --env-path is the fourth supplement of P-010: a process whose ancestry is
# gone and whose command line carries no run path, but whose environment
# variable <NAME> holds a path inside a run root (the root itself or below it,
# compared at a directory boundary). <NAME> must be one of the names written
# here, FM_HOME or FM_EXTENSION_LIFECYCLE_LOCK; a new name needs security's
# review. The guard reads the target's environment itself before the send
# (Linux /proc/<pid>/environ; elsewhere ps -E) and refuses when it cannot. The
# record names only that variable and its value. The standing refusals of
# --identity come first.
#
# --group names a process group by its leader. The leader must be alive, pass
# the --identity refusals, carry path or ancestry evidence (the environment
# alone is not enough for a group), lead its own group (its pgid is its pid),
# and that group must not be the group of FM_TEST_SUITE_PID,
# FM_TEST_SUITE_PARENT, the signalling shell or any of its ancestors. The
# signal goes to the whole group.
#
# --members names a group whose leader may already be gone. The guard lists
# the group's live members itself; a group id of 1 or less, or the group of
# the test script, its parent, the signalling shell or one of its ancestors,
# is refused outright. Each member is then judged as --identity on its own
# evidence and signalled alone if accepted; a refused member is left. A group
# with no live member is accepted with nothing to signal.
#
# With a log file each target appends one line: the source, the raw arguments
# as received, the shell, the target, its command, the verdict (with the
# evidence that held, or why none did), and the target's ancestry up to pid 1
# (for a refused --below call, the stand-in's).
set -u

mode=verdict
if [ "${1-}" = --send ]; then
  mode=send
  shift
  self=$PPID
  log=
  if [ -n "${FM_TEST_SIGNAL_DRY_RUN:-}" ]; then
    case "${FM_TEST_SIGNAL_LOG:-}" in
      /*) log=$FM_TEST_SIGNAL_LOG ;;
      *) echo "refused: log-only mode needs FM_TEST_SIGNAL_LOG, an absolute path" >&2; exit 2 ;;
    esac
  fi
  if [ "$#" -lt 2 ]; then
    echo "usage: tests/signal-guard.sh --send <source> <signal> <form>" >&2
    exit 2
  fi
  source=$1
  shift
else
  if [ "$#" -lt 3 ]; then
    echo "usage: sh tests/signal-guard.sh <self-pid> <log-file-or-empty> <source> <signal> <form>" >&2
    exit 2
  fi
  self=$1 log=$2 source=$3
  shift 3
fi
raw="argc=$#"
for arg in "$@"; do raw="$raw [$arg]"; done
signal=${1-}
[ "$#" -eq 0 ] || shift
target=- command=- parent=- walk_from=

ps_field() {  # <field> <pid>: one field of <pid>, empty when it is gone.
  command -p ps -ww -o "$1=" -p "$2" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
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

self_chain() {  # the pids from <self-pid> up to pid 1, space-separated with a leading space.
  chain=" " pid=$self levels=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$levels" -lt 64 ]; do
    chain="$chain$pid "
    pid=$(ps_field ppid "$pid")
    levels=$((levels + 1))
  done
  printf '%s\n' "$chain"
}

protected_chain() {  # the shell's ancestors from the test script up, or all of them.
  chain=" " pid=$(ps_field ppid "$self") levels=0 seen_suite=0 below=" "
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$levels" -lt 64 ]; do
    [ "$pid" != "${FM_TEST_SUITE_PID:-}" ] || seen_suite=1
    if [ "$seen_suite" -eq 1 ]; then chain="$chain$pid "; else below="$below$pid "; fi
    pid=$(ps_field ppid "$pid")
    levels=$((levels + 1))
  done
  if [ "$seen_suite" -eq 1 ]; then printf '%s\n' "$chain"; else printf '%s\n' "$below$chain"; fi
}

own_groups() {  # the groups of the test script, its parent, the shell and its ancestors.
  for pid in ${FM_TEST_SUITE_PID:-} ${FM_TEST_SUITE_PARENT:-} $(self_chain); do
    ps_field pgid "$pid"
  done
}

environment_of() {  # <pid>: its environment, one NAME=value per line where readable.
  if [ -r "/proc/$1/environ" ]; then
    tr '\000' '\n' < "/proc/$1/environ" 2>/dev/null
  else
    command -p ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n'
  fi
}

path_evidence() {  # <pid>: prints the run root its command line names, or nothing.
  [ -n "${FM_TEST_RUN_ROOTS:-}" ] && [ -f "$FM_TEST_RUN_ROOTS" ] || return 0
  args=" $(ps_field args "$1") "
  while IFS= read -r root; do
    case "$root" in /?*) ;; *) continue ;; esac
    [ "$(sed -n '1p' "$root/.fm-test-fixture" 2>/dev/null)" = "${FM_TEST_SUITE_PID:-}" ] || continue
    case "$args" in
      *"$root/"* | *"$root "*) printf '%s\n' "$root"; return 0 ;;
    esac
  done < "$FM_TEST_RUN_ROOTS"
}

env_evidence() {  # <pid>: 0 when its environment carries this run's mark.
  [ -n "${FM_TEST_RUN_MARK:-}" ] || return 1
  marks=$(environment_of "$1" | sed -n 's/^FM_TEST_RUN_MARKS=//p' | sed -n '1p')
  case " $marks " in *" $FM_TEST_RUN_MARK "*) return 0 ;; esac
  return 1
}

ancestry_evidence() {  # <pid>: 0 when walking up from it reaches the test script.
  pid=$(ps_field ppid "$1") levels=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$levels" -lt 64 ]; do
    [ "$pid" != "${FM_TEST_SUITE_PID:-}" ] || return 0
    pid=$(ps_field ppid "$pid")
    levels=$((levels + 1))
  done
  return 1
}

standing_refusal() {  # <pid>: prints why a target is refused whatever its evidence, or nothing.
  identity_command=$(ps_field args "$1")
  if [ -z "$identity_command" ]; then
    echo "refused: pid $1 is not running"
  elif [ "$1" -le 1 ]; then
    echo "refused: pid $1 is 1 or less"
  elif [ "$1" = "${FM_TEST_SUITE_PID:-}" ]; then
    echo "refused: pid $1 is the test script itself"
  elif [ "$1" = "${FM_TEST_SUITE_PARENT:-}" ]; then
    echo "refused: pid $1 is the test script's parent"
  elif [ "$1" = "$self" ]; then
    echo "refused: pid $1 is the signalling shell itself"
  else
    case "$(protected_chain)" in
      *" $1 "*) echo "refused: pid $1 is an ancestor of the signalling shell $self at or above the test script"; return ;;
    esac
    case "$identity_command" in
      *systemd*) echo "refused: pid $1 is the service manager '$identity_command'" ;;
    esac
  fi
}

run_root_holding() {  # <path>: prints the run root that <path> is, or lies under.
  [ -n "${FM_TEST_RUN_ROOTS:-}" ] && [ -f "$FM_TEST_RUN_ROOTS" ] || return 0
  while IFS= read -r root; do
    case "$root" in /?*) ;; *) continue ;; esac
    [ "$(sed -n '1p' "$root/.fm-test-fixture" 2>/dev/null)" = "${FM_TEST_SUITE_PID:-}" ] || continue
    case "$1" in
      "$root" | "$root"/*) printf '%s\n' "$root"; return 0 ;;
    esac
  done < "$FM_TEST_RUN_ROOTS"
}

judge_env_path() {  # <name> <pid>: prints the verdict on the --env-path form.
  case "$1" in
    FM_HOME | FM_EXTENSION_LIFECYCLE_LOCK) ;;
    *) echo "refused: '$1' is not a variable --env-path may read (FM_HOME, FM_EXTENSION_LIFECYCLE_LOCK)"; return ;;
  esac
  refusal=$(standing_refusal "$2")
  [ -z "$refusal" ] || { echo "$refusal"; return; }
  environment=$(environment_of "$2")
  if [ -z "$environment" ]; then
    echo "refused: pid $2's environment cannot be read"
    return
  fi
  value=$(printf '%s\n' "$environment" | sed -n "s/^$1=//p" | sed -n '1p')
  root=$(run_root_holding "$value")
  if [ -n "$value" ] && [ -n "$root" ]; then
    echo "accepted $2 (evidence: env $1=$value under run root $root)"
  else
    echo "refused: pid $2's $1 is not a path under this run's temp roots"
  fi
}

judge_identity() {  # <pid> [group]: prints the verdict on the --identity form.
  refusal=$(standing_refusal "$1")
  [ -z "$refusal" ] || { echo "$refusal"; return; }
  root=$(path_evidence "$1")
  if [ -n "$root" ]; then
    echo "accepted $1 (evidence: path $root in its command line)"
  elif [ "${2-}" != group ] && env_evidence "$1"; then
    echo "accepted $1 (evidence: env FM_TEST_RUN_MARKS holds this run's mark)"
  elif ancestry_evidence "$1"; then
    echo "accepted $1 (evidence: ancestry reaches the test script ${FM_TEST_SUITE_PID:-})"
  elif [ "${2-}" = group ]; then
    echo "refused: pid $1 carries no path or ancestry evidence of this test run (a group leader is not accepted on its environment)"
  else
    echo "refused: pid $1 carries no evidence of this test run (no run root in its command line, no run mark in its environment, ancestry does not reach the test script ${FM_TEST_SUITE_PID:-none})"
  fi
}

judge_group() {  # <leader>: prints the verdict on the --group form.
  leader_verdict=$(judge_identity "$1" group)
  case "$leader_verdict" in
    "accepted "*) ;;
    *) echo "refused: the group leader: ${leader_verdict#refused: }"; return ;;
  esac
  pgid=$(ps_field pgid "$1")
  if [ "$pgid" != "$1" ]; then
    echo "refused: pid $1 does not lead its own group (its group: ${pgid:-none})"
    return
  fi
  case " $(own_groups | tr '\n' ' ') " in
    *" $pgid "*) echo "refused: group $pgid is the group of the test script, its parent, the signalling shell or one of its ancestors"; return ;;
  esac
  echo "accepted group $1 ${leader_verdict#accepted $1 }"
}

group_members() {  # <group-id>: the live pids in that group, one per line.
  command -p ps -ww -eo pid=,pgid= 2>/dev/null | awk -v g="$1" '$2 == g { print $1 }'
}

log_line() {  # <target> <command> <verdict> <walk-from>: one record in the log.
  [ -n "$log" ] || return 0
  chain="" pid=${4:-$1} levels=0
  while [ "$pid" != - ] && [ -n "$pid" ] && [ "$levels" -lt 64 ]; do
    chain="$chain < $pid $(ps_field args "$pid")"
    [ "$pid" -gt 1 ] 2>/dev/null || break
    pid=$(ps_field ppid "$pid")
    levels=$((levels + 1))
  done
  printf 'source=%s | raw: %s | shell=%s | target=%s command=%s | %s | ancestry: %s\n' \
    "$source" "$raw" "$self" "$1" "${2:--}" "$3" "${chain# < }" >> "$log"
}

send_one() {  # <signal> <pid> or <signal> -- -<group>: the one send of an accepted target.
  if [ "$mode" != send ] || [ -n "${FM_TEST_SIGNAL_DRY_RUN:-}" ]; then
    return 0
  fi
  kill -s "$@" 2>/dev/null || sent_rc=3
}

parse_pid() {  # <arg>: sets pid_error when the argument is not one positive pid.
  case "$1" in
    '') pid_error="refused: the pid is empty" ;;
    *[!0-9]*) pid_error="refused: '$1' is not a positive pid (a flag, a negative pid or a process group)" ;;
    0*) pid_error="refused: '$1' is 0 or starts with 0" ;;
    *) pid_error= ;;
  esac
}

sent_rc=0 refused=0
if [ "$signal_ok" -eq 0 ]; then
  verdict="refused: '$signal' is not one of the signal names TERM KILL STOP CONT INT HUP QUIT"
elif [ "${1-}" = --members ]; then
  shift
  parse_pid "${1-}"
  if [ "$#" -ne 1 ]; then
    verdict="refused: --members takes exactly one group id, got $#"
  elif [ -n "$pid_error" ]; then
    verdict=$pid_error
  elif [ "$1" -le 1 ]; then
    verdict="refused: group $1 is 1 or less"
  else
    case " $(own_groups | tr '\n' ' ') " in
      *" $1 "*) verdict="refused: group $1 is the group of the test script, its parent, the signalling shell or one of its ancestors" ;;
      *)
        group=$1 count=0
        for member in $(group_members "$group"); do
          count=$((count + 1))
          member_verdict=$(judge_identity "$member")
          log_line "$member" "$(ps_field args "$member")" "group $group member: $member_verdict" ""
          printf 'group %s member: %s\n' "$group" "$member_verdict"
          case "$member_verdict" in
            "accepted "*) send_one "$signal" "$member" ;;
            *) refused=1 ;;
          esac
        done
        [ "$count" -gt 0 ] || { log_line "$group" - "accepted group $group: no live member, nothing to signal" ""; echo "accepted group $group: no live member, nothing to signal"; }
        [ "$refused" -eq 0 ] || exit 1
        exit "$sent_rc"
        ;;
    esac
  fi
elif [ "${1-}" = --env-path ]; then
  shift
  parse_pid "${2-}"
  if [ "$#" -ne 2 ]; then
    verdict="refused: --env-path takes one variable name and exactly one pid, got $# arguments"
  elif [ -n "$pid_error" ]; then
    verdict=$pid_error
  else
    target=$2
    command=$(ps_field args "$target")
    verdict=$(judge_env_path "$1" "$target")
  fi
elif [ "${1-}" = --identity ] || [ "${1-}" = --group ]; then
  form=$1
  shift
  parse_pid "${1-}"
  if [ "$#" -ne 1 ]; then
    verdict="refused: $form takes exactly one pid, got $#"
  elif [ -n "$pid_error" ]; then
    verdict=$pid_error
  else
    target=$1
    command=$(ps_field args "$target")
    if [ "$form" = --identity ]; then
      verdict=$(judge_identity "$target")
    else
      verdict=$(judge_group "$target")
    fi
  fi
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
  parse_pid "$1"
  if [ -n "$pid_error" ]; then
    verdict=$pid_error
  else
    target=$1
    parent=$(ps_field ppid "$target")
    command=$(ps_field args "$target")
    verdict=$(judge_pid "$target")
  fi
fi

log_line "$target" "$command" "$verdict" "$walk_from"
printf '%s\n' "$verdict"
case "$verdict" in
  "accepted group "*)
    leader=${verdict#accepted group }
    leader=${leader%% *}
    send_one "$signal" -- "-$leader"
    ;;
  "accepted "*)
    accepted=${verdict#accepted }
    accepted=${accepted%% *}
    send_one "$signal" "$accepted"
    ;;
  *) [ "$mode" = verdict ] || exit 1 ;;
esac
exit "$sent_rc"
