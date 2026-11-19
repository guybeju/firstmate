#!/usr/bin/env bash
# The one guarded way a board test sends a signal (signal policy P-010), shared
# by every suite whose tests stop a process themselves. Sourced after
# tests/lib.sh; sig_init writes the guard into the scratch root once TMP_ROOT
# is set. myshape/test/check-signals.sh pins kill_own_child's one signal line
# as the only one in those suites.
# shellcheck disable=SC2034 # SIGNAL_CHECK is read by the sourcing scripts.

# FM_TEST_SIGNAL_DRY_RUN=1: the guarded helper sends nothing and instead writes
# one line per call to FM_TEST_SIGNAL_LOG (an absolute path), so the targets
# can be read before a real run; the assertions that need a killed run are
# skipped, and every shim and migration ends by itself.
# FM_TEST_SIGNAL_DRY_RUN=unfixed: the same; fm-board/test/stage-8-migrate.sh
# also logs the target its shim chose before the fix there. Nothing is
# signalled in either mode.
case "${FM_TEST_SIGNAL_DRY_RUN:-}" in
  '' | 1 | unfixed) ;;
  *) echo "not ok - FM_TEST_SIGNAL_DRY_RUN must be 1, unfixed, or unset" >&2; exit 1 ;;
esac
signal_dry_run() {
  [ -n "${FM_TEST_SIGNAL_DRY_RUN:-}" ]
}
if signal_dry_run; then
  case "${FM_TEST_SIGNAL_LOG:-}" in
    /*) ;;
    *) echo "not ok - FM_TEST_SIGNAL_DRY_RUN needs FM_TEST_SIGNAL_LOG, an absolute path for its log" >&2; exit 1 ;;
  esac
  printf '# signal dry run (%s): nothing is signalled; each target is logged to %s\n' \
    "$FM_TEST_SIGNAL_DRY_RUN" "$FM_TEST_SIGNAL_LOG"
fi

# signal-check <test-pid> <log-file or ""> <source> [arguments...]: the guard's
# verdict on the arguments of one signal call, "accepted <pid>" or "refused:
# <why>". Only one positive pid that is a direct child of the test script, and
# not the user's service manager, is accepted. With a log file it appends one
# line: the raw arguments as received, then the parsed target, its command,
# the verdict and the target's ancestry up to pid 1. It never signals.
sig_init() {
  SIGNAL_CHECK=$TMP_ROOT/signal-check
  cat > "$SIGNAL_CHECK" <<'SH'
#!/bin/sh
test_pid=$1 log=$2 source=$3
shift 3
raw="argc=$#"
for arg in "$@"; do raw="$raw [$arg]"; done
target=- command=-
if [ "$#" -ne 1 ]; then
  verdict="refused: takes exactly one pid, got $# arguments"
else
  case "$1" in
    '') verdict="refused: the pid is empty" ;;
    *[!0-9]*) verdict="refused: '$1' is not a positive pid (a flag, a negative pid or a process group)" ;;
    0*) verdict="refused: '$1' is 0 or starts with 0" ;;
    *)
      target=$1
      parent=$(ps -o ppid= -p "$target" 2>/dev/null | tr -d ' ')
      command=$(ps -o args= -p "$target" 2>/dev/null || true)
      if [ "$target" -le 1 ]; then
        verdict="refused: pid $target is 1 or less"
      elif [ "$target" = "$test_pid" ]; then
        verdict="refused: pid $target is the test script itself"
      elif [ "$parent" != "$test_pid" ]; then
        verdict="refused: pid $target is not a child of the test script $test_pid (its parent: ${parent:-none})"
      else
        case "$command" in
          *systemd*) verdict="refused: pid $target is $command" ;;
          *) verdict="accepted $target" ;;
        esac
      fi
      ;;
  esac
fi
if [ -n "$log" ]; then
  chain="" pid=$target levels=0
  while [ "$pid" != - ] && [ -n "$pid" ] && [ "$levels" -lt 64 ]; do
    chain="$chain < $pid $(ps -o args= -p "$pid" 2>/dev/null || printf '(gone)')"
    [ "$pid" -gt 1 ] 2>/dev/null || break
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    levels=$((levels + 1))
  done
  printf 'source=%s | raw: %s | target=%s command=%s | %s | ancestry: %s\n' \
    "$source" "$raw" "$target" "${command:--}" "$verdict" "${chain# < }" >> "$log"
fi
printf '%s\n' "$verdict"
SH
  chmod +x "$SIGNAL_CHECK"
}

# kill_own_child <pid>: the one signal command of every test that sources this
# file (the boards' own stop commands, the migration's S1 and the cleanup on
# exit send theirs). signal-check
# judges the raw arguments, and only an accepted pid is signalled; anything
# else fails the test unsent. In a dry run nothing is sent and signal-check
# logs the call. The pid is a child this shell has not waited for, so it
# cannot have been reused.
kill_own_child() {
  local verdict log=""
  ! signal_dry_run || log=$FM_TEST_SIGNAL_LOG
  verdict=$("$SIGNAL_CHECK" "$$" "$log" kill_own_child "$@")
  if signal_dry_run; then
    return 0
  fi
  case "$verdict" in "accepted "*) ;; *) fail "signal guard: $verdict" ;; esac
  kill -KILL "${verdict#accepted }"
}

# dry_log <line>: one line in the dry run's log.
dry_log() {
  ! signal_dry_run || printf '%s\n' "$1" >> "$FM_TEST_SIGNAL_LOG"
}

