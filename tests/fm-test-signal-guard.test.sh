#!/usr/bin/env bash
# Behaviour tests for signal policy P-010's guard: tests/signal-guard.sh's
# verdicts and tests/lib.sh's fm_test_signal, fm_test_record_child,
# fm_fake_crash_point and fm_test_crash_at.
#
# Every child these cases start ends by itself, except the one that
# fm_test_signal ends in the last two cases. With FM_TEST_SIGNAL_DRY_RUN=1 and
# FM_TEST_SIGNAL_LOG set, nothing is signalled at all: those cases then check
# the logged verdict instead and leave the child to end by itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/tests/signal-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-signal-guard)
LOG=${FM_TEST_SIGNAL_LOG:-$TMP_ROOT/signal.log}

# The pid of this shell as a child process sees it (portable to bash 3.2, which
# has no BASHPID): the substitution's own process execs sh, so sh's parent is
# the shell that evaluated it. Every case runs in this same shell.
THIS_SHELL=$(exec sh -c 'printf "%s\n" "$PPID"')

guard() {  # <self> <signal> [pid...]: the guard's verdict, logged to LOG
  local self=$1
  shift
  sh "$GUARD" "$self" "$LOG" "fm-test-signal-guard" "$@"
}

expect_refused() {  # <verdict> <label>
  case "$1" in
    "refused: "*) ;;
    *) fail "$2 was not refused: $1" ;;
  esac
}

# A child that ends by itself once <release> exists, so no case has to signal it.
start_waiting_child() {  # <release>
  ( i=0; while [ ! -e "$1" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done ) &
  WAITING_CHILD=$!
}

# 0 while any process's command line names <path>; the path reaches awk through
# the environment, so the check never matches itself.
running_under() {  # <path>
  ps -ww -eo args= | RUNNING_UNDER="$1" awk 'index($0, ENVIRON["RUNNING_UNDER"]) { found = 1 } END { exit !found }'
}

# The nearest systemd process above this suite that is not pid 1: on a desktop
# that is the user's service manager, which adopts orphans. Empty elsewhere.
user_manager_pid() {
  local pid=$$ comm
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ "$comm" != systemd ] || { printf '%s\n' "$pid"; return 0; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  done
}

test_forms_without_one_explicit_pid_are_refused() {
  local self unset_pid
  self=$THIS_SHELL
  unset unset_pid
  expect_refused "$(guard "$self" TERM "")" "an empty pid"
  expect_refused "$(guard "$self" TERM "${unset_pid-}")" "an unset variable"
  expect_refused "$(guard "$self" TERM)" "a call with no pid"
  expect_refused "$(guard "$self" TERM 0)" "pid 0"
  expect_refused "$(guard "$self" TERM -1)" "pid -1"
  expect_refused "$(guard "$self" TERM -4242)" "a negative pid"
  expect_refused "$(guard "$self" TERM -- -4242)" "a process group after --"
  expect_refused "$(guard "$self" TERM 0123)" "a pid with a leading 0"
  expect_refused "$(guard "$self" TERM 1)" "pid 1"
  expect_refused "$(guard "$self" TERM 12 13)" "two pids"
  expect_refused "$(guard "$self" -TERM 12)" "a dash-prefixed signal"
  expect_refused "$(guard "$self" 9 12)" "a numeric signal"
  expect_refused "$(guard "$self" "" 12)" "an empty signal"
  pass "the guard refuses every form without exactly one explicit pid and one signal name"
}

test_the_suite_its_parent_and_the_user_manager_are_refused() {
  local self manager verdict
  self=$THIS_SHELL
  expect_refused "$(guard "$self" TERM "$$")" "the test's own pid"
  expect_refused "$(guard "$self" TERM "$PPID")" "the test's parent"
  expect_refused "$(guard "$self" TERM "$self")" "the signalling shell"
  manager=$(user_manager_pid)
  if [ -n "$manager" ]; then
    verdict=$(FM_TEST_RECORDED_CHILDREN=" $manager" guard "$self" TERM "$manager")
    assert_contains "$verdict" "is the service manager" \
      "the user manager $manager was not refused as the service manager, even when recorded"
    expect_refused "$(guard "$self" TERM "$manager")" "the user manager"
  else
    echo "# no systemd ancestor here, so the user-manager input is not exercised"
  fi
  pass "the guard refuses the test script, its parent, the signalling shell and the user manager"
}

test_only_a_recorded_child_of_the_signalling_shell_is_accepted() {
  local self release grandchild verdict middle i
  self=$THIS_SHELL
  release="$TMP_ROOT/recorded.release"
  start_waiting_child "$release"
  verdict=$(guard "$self" TERM "$WAITING_CHILD")
  assert_contains "$verdict" "is not a recorded child" "an unrecorded child was not refused as unrecorded"
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $WAITING_CHILD" guard "$self" TERM "$WAITING_CHILD")
  [ "$verdict" = "accepted $WAITING_CHILD" ] || fail "a recorded child of this shell was not accepted: $verdict"
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $WAITING_CHILD" guard "$PPID" TERM "$WAITING_CHILD")
  assert_contains "$verdict" "is not a child of the signalling shell" \
    "a recorded child was accepted for a shell that is not its parent"
  : > "$release"
  wait "$WAITING_CHILD" || fail "the waiting child did not end by itself"

  sh -c 'sleep 2 > /dev/null 2>&1 & echo "$!"; wait' > "$TMP_ROOT/grandchild" &
  middle=$!
  i=0
  while [ ! -s "$TMP_ROOT/grandchild" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  grandchild=$(cat "$TMP_ROOT/grandchild")
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $grandchild" guard "$self" TERM "$grandchild")
  assert_contains "$verdict" "is not a child of the signalling shell" "a recorded grandchild was accepted"
  wait "$middle" || fail "the grandchild's parent did not end by itself"
  pass "the guard accepts only a recorded child whose parent is the signalling shell"
}

test_the_log_shows_raw_arguments_target_and_ancestry() {
  local self line
  self=$THIS_SHELL
  guard "$self" TERM "$PPID" >/dev/null
  line=$(tail -n 1 "$LOG")
  assert_contains "$line" "raw: argc=2 [TERM] [$PPID]" "the log lost the raw arguments"
  assert_contains "$line" "target=$PPID command=" "the log lost the parsed target"
  assert_contains "$line" "ancestry: $PPID " "the log lost the target's ancestry"
  assert_contains "$line" "refused: pid $PPID is the test script's parent" "the log lost the verdict"
  pass "each logged call shows the raw arguments, the target, its command, the verdict and its ancestry"
}

test_fm_test_signal_refuses_without_sending() {
  local rc=0
  ( fm_test_signal TERM "$$" ) 2> "$TMP_ROOT/refusal.err" || rc=$?
  if fm_test_signal_dry_run; then
    [ "$rc" -eq 0 ] || fail "a log-only refusal failed the call"
    assert_contains "$(tail -n 1 "$FM_TEST_SIGNAL_LOG")" "refused: pid $$ is the test script itself" \
      "the log-only refusal was not logged"
  else
    [ "$rc" -ne 0 ] || fail "fm_test_signal accepted the test script itself"
    assert_grep "signal guard: refused: pid $$ is the test script itself" "$TMP_ROOT/refusal.err" \
      "fm_test_signal did not name the refusal"
  fi
  pass "fm_test_signal refuses a target the guard refuses and sends it nothing"
}

test_fm_test_signal_ends_its_own_recorded_child() {
  local release rc=0
  release="$TMP_ROOT/own-child.release"
  start_waiting_child "$release"
  fm_test_record_child "$WAITING_CHILD"
  fm_test_signal TERM "$WAITING_CHILD"
  if fm_test_signal_dry_run; then
    assert_contains "$(tail -n 1 "$FM_TEST_SIGNAL_LOG")" "accepted $WAITING_CHILD" \
      "the log-only call did not log the accepted child"
    : > "$release"
    wait "$WAITING_CHILD" || fail "the waiting child did not end by itself"
  else
    wait "$WAITING_CHILD" || rc=$?
    [ "$rc" -eq 143 ] || fail "the recorded child did not end by TERM (status $rc)"
  fi
  pass "fm_test_signal sends its signal to a recorded child of the calling shell"
}

test_crash_point_holds_the_stand_in_until_its_victim_is_gone() {
  local dir="$TMP_ROOT/crash-point" fakebin pid rc=0 i
  fakebin=$(fm_fakebin "$dir")
  fm_fake_crash_point "$fakebin"
  cat > "$fakebin/step" <<'SH'
#!/usr/bin/env bash
fm-crash-point "$1" step || exit 1
: > "$1/resumed"
SH
  chmod +x "$fakebin/step"
  PATH="$fakebin:$PATH" bash -c '"$0" "$1"; : > "$1/victim-went-on"' "$fakebin/step" "$dir" &
  pid=$!
  fm_test_record_child "$pid"
  fm_test_crash_at "$dir" step KILL "$pid"
  wait "$pid" || rc=$?
  if fm_test_signal_dry_run; then
    [ "$rc" -eq 0 ] || fail "the unsignalled victim did not finish (status $rc)"
  else
    [ "$rc" -eq 137 ] || fail "the victim did not end by KILL at the crash point (status $rc)"
    assert_absent "$dir/victim-went-on" "the victim went on past the crash point"
  fi
  i=0
  while [ ! -e "$dir/resumed" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  assert_present "$dir/resumed" "the released stand-in did not return from its crash point"
  i=0
  while running_under "$dir/" && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  ! running_under "$dir/" || fail "the released stand-in is still running"
  pass "a stand-in stops at its crash point until the test has signalled its own child"
}

test_crash_point_gives_up_without_resuming() {
  local dir="$TMP_ROOT/abandoned" fakebin rc=0
  fakebin=$(fm_fakebin "$dir")
  fm_fake_crash_point "$fakebin"
  FM_TEST_STUB_MAX_BLOCK_SECONDS=1 "$fakebin/fm-crash-point" "$dir" never 2> "$dir/err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unreleased crash point did not give up with status 1 (got $rc)"
  assert_grep "never was never released" "$dir/err" "the abandoned crash point did not say why"
  pass "an unreleased crash point gives up at its bound instead of resuming"
}

# A tree the --below form is judged on: the recorded child R (a bash -c) runs
# victim.sh M, which runs a subshell with M's own command line, which runs a
# stand-in S that stops at crash point below. Sets BELOW_DIR, BELOW_R,
# BELOW_STANDIN and BELOW_GLOB; release with `: > "$BELOW_DIR/below.release"`.
start_below_tree() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin i=0
  fakebin=$(fm_fakebin "$dir")
  fm_fake_crash_point "$fakebin"
  cat > "$fakebin/stand-in" <<'SH'
#!/usr/bin/env bash
fm-crash-point "$1" below || exit 1
SH
  cat > "$dir/victim.sh" <<'SH'
#!/usr/bin/env bash
( "$1/fakebin/stand-in" "$1"; : > "$1/subshell-went-on" )
: > "$1/victim-went-on"
SH
  chmod +x "$fakebin/stand-in" "$dir/victim.sh"
  PATH="$fakebin:$PATH" bash -c '"$0" "$1"; :' "$dir/victim.sh" "$dir" &
  BELOW_R=$!
  while [ ! -s "$dir/below.reached" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$dir/below.reached" ] || fail "the --below tree's stand-in never reached its crash point"
  BELOW_DIR=$dir
  BELOW_STANDIN=$(cut -d' ' -f1 < "$dir/below.reached")
  BELOW_GLOB="bash $dir/victim.sh *"
}

victim_pid() {  # <dir>: the pid running victim.sh <dir> whose parent does not.
  ps -ww -eo pid=,ppid=,args= | VICTIM="bash $1/victim.sh $1" awk '
    { pid = $1; ppid = $2; $1 = ""; $2 = ""; sub(/^  /, ""); args[pid] = $0; parent[pid] = ppid }
    END { for (p in args) if (args[p] == ENVIRON["VICTIM"] && args[parent[p]] != ENVIRON["VICTIM"]) print p }'
}

test_below_accepts_only_the_one_matching_process_under_the_recorded_child() {
  local self verdict victim other
  self=$THIS_SHELL
  start_below_tree below-verdicts
  victim=$(victim_pid "$BELOW_DIR")
  [ -n "$victim" ] || fail "the --below tree has no victim.sh process"
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R" guard "$self" KILL --below "$BELOW_R" "$BELOW_GLOB" "$BELOW_STANDIN")
  [ "$verdict" = "accepted $victim" ] \
    || fail "--below did not pick victim.sh $victim over its own subshell: $verdict"
  verdict=$(guard "$self" KILL --below "$BELOW_R" "$BELOW_GLOB" "$BELOW_STANDIN")
  assert_contains "$verdict" "the recorded child: pid $BELOW_R is not a recorded child" \
    "--below accepted a child that was never recorded"
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R" guard "$self" KILL --below "$BELOW_R" "bash -c *" "$BELOW_STANDIN")
  assert_contains "$verdict" "refused: 0 processes" "--below accepted the recorded child itself, whose command line matched"
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R" guard "$self" KILL --below "$BELOW_R" "bash $BELOW_DIR/no-such.sh *" "$BELOW_STANDIN")
  assert_contains "$verdict" "refused: 0 processes" "--below accepted a process under the child that does not match"
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R" guard "$self" KILL --below "$BELOW_R" "*victim.sh*" "$BELOW_STANDIN")
  assert_contains "$verdict" "starts with *" "--below accepted a glob that starts with *"
  for other in "$$" "$PPID" 1; do
    verdict=$(FM_TEST_RECORDED_CHILDREN=" $other" guard "$self" KILL --below "$other" "$BELOW_GLOB" "$BELOW_STANDIN")
    expect_refused "$verdict" "--below with pid $other as the recorded child"
  done
  other=$(user_manager_pid)
  if [ -n "$other" ]; then
    verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R $other" guard "$self" KILL --below "$other" "$BELOW_GLOB" "$BELOW_STANDIN")
    expect_refused "$verdict" "--below with the user manager $other as the recorded child"
    verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R" guard "$self" KILL --below "$BELOW_R" "$BELOW_GLOB" "$other")
    expect_refused "$verdict" "--below with the user manager $other as the stand-in"
  fi
  : > "$BELOW_DIR/below.release"
  wait "$BELOW_R" || fail "the --below tree did not end by itself"
  pass "--below accepts only the one process under the recorded child that matches, never the child, the test or the manager"
}

test_below_refuses_a_matching_process_outside_the_recorded_child() {
  local self verdict outside i
  self=$THIS_SHELL
  start_below_tree below-outside
  # A second copy of the same tree that this shell starts but never records:
  # its victim.sh matches the glob too, but it is not under the recorded child.
  mkdir -p "$TMP_ROOT/below-outside-2"
  cp -R "$BELOW_DIR/fakebin" "$TMP_ROOT/below-outside-2/"
  PATH="$BELOW_DIR/fakebin:$PATH" bash -c '"$0" "$1"; :' "$BELOW_DIR/victim.sh" "$TMP_ROOT/below-outside-2" &
  outside=$!
  i=0
  while [ ! -s "$TMP_ROOT/below-outside-2/below.reached" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  verdict=$(FM_TEST_RECORDED_CHILDREN=" $BELOW_R" guard "$self" KILL --below "$BELOW_R" \
    "bash $BELOW_DIR/victim.sh *" "$(cut -d' ' -f1 < "$TMP_ROOT/below-outside-2/below.reached")")
  assert_contains "$verdict" "is not below the recorded child $BELOW_R" \
    "--below accepted a matching process that is not under the recorded child"
  : > "$TMP_ROOT/below-outside-2/below.release"
  : > "$BELOW_DIR/below.release"
  wait "$outside" || fail "the unrecorded tree did not end by itself"
  wait "$BELOW_R" || fail "the --below tree did not end by itself"
  pass "--below refuses a matching process that is not under the recorded child"
}

test_crash_at_below_signals_the_process_under_the_child() {
  local rc=0 victim i
  start_below_tree below-crash
  fm_test_record_child "$BELOW_R"
  victim=$(victim_pid "$BELOW_DIR")
  fm_test_crash_at "$BELOW_DIR" below KILL "$BELOW_R" "$BELOW_GLOB"
  wait "$BELOW_R" || rc=$?
  [ "$rc" -eq 0 ] || fail "the recorded child did not go on after its own child (status $rc)"
  if fm_test_signal_dry_run; then
    assert_contains "$(tail -n 1 "$FM_TEST_SIGNAL_LOG")" "accepted $victim" \
      "the log-only --below call did not log victim.sh as accepted"
  else
    assert_absent "$BELOW_DIR/victim-went-on" "victim.sh went on past the crash point"
  fi
  i=0
  while running_under "$BELOW_DIR/" && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  ! running_under "$BELOW_DIR/" || fail "the --below tree is still running"
  pass "fm_test_crash_at with a command line signals the one process under the recorded child"
}

fm_test_run \
  test_forms_without_one_explicit_pid_are_refused \
  test_the_suite_its_parent_and_the_user_manager_are_refused \
  test_only_a_recorded_child_of_the_signalling_shell_is_accepted \
  test_the_log_shows_raw_arguments_target_and_ancestry \
  test_fm_test_signal_refuses_without_sending \
  test_fm_test_signal_ends_its_own_recorded_child \
  test_crash_point_holds_the_stand_in_until_its_victim_is_gone \
  test_crash_point_gives_up_without_resuming \
  test_below_accepts_only_the_one_matching_process_under_the_recorded_child \
  test_below_refuses_a_matching_process_outside_the_recorded_child \
  test_crash_at_below_signals_the_process_under_the_child
