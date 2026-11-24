#!/usr/bin/env bash
# Behavior tests for the remote job worker lock when a holder dies while
# publishing its records.
#
# The wedge this pins: a worker stops between creating a temporary record
# inside worker.lock and publishing it, and the leftover temporary file makes
# every later reclaim's rmdir fail, so no replacement can ever take ownership
# and all remote transport to that host times out. A pre-fix worker killed by
# an update can leave such a file behind, so the replacement must clear the
# temporary names this code creates once their holder is proven dead, and must
# still never remove the temporary of a live worker that is publishing.
#
# Each case drives the real worker against its own disposable state root and
# either places the leftover state directly or stops a worker inside the
# window with a PATH fake for ln, never by timing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-lock-temps)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FIXTURE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKE_BIN=$(fm_fakebin "$TMP_ROOT/lock-gate")
REAL_LN=$(command -v ln)
REAL_MV=$(command -v mv)
mkdir -p "$FIXTURE_ROOT/bin" "$ACCOUNT_HOME" "$REMOTE_HOME"
chmod 700 "$ACCOUNT_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$FIXTURE_ROOT/bin/"
printf 'fixture\n' > "$FIXTURE_ROOT/AGENTS.md"
cat > "$FIXTURE_ROOT/bin/fm-append-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' >> "$1"
SH
chmod +x "$FIXTURE_ROOT/bin"/*.sh
# The worker executes only tracked commands.
git -C "$FIXTURE_ROOT" init -q -b main
git -C "$FIXTURE_ROOT" config user.email test@example.com
git -C "$FIXTURE_ROOT" config user.name Test
git -C "$FIXTURE_ROOT" add AGENTS.md bin
git -C "$FIXTURE_ROOT" commit -qm 'lock temporaries fixture'
WORKER="$FIXTURE_ROOT/bin/fm-remote-job-worker.sh"

# The fake ln acts only on the worker lock record named by FM_TEST_GATE_DEST,
# whose publication runs in the worker's own shell. kill and term stop there at
# crash point FM_TEST_GATE (see serve), where the case KILLs the worker inside
# the window or sends it the TERM an update's restart sends; hold keeps the
# worker alive inside the window until the case releases it. The fake mv stops
# the same way for term on start and command, which are published with mv.
fm_fake_crash_point "$FAKE_BIN"
cat > "$FAKE_BIN/mv" <<'SH'
#!/bin/bash
last=${!#}
if [ "$last" = "${FM_TEST_GATE_DEST:-}" ] && [ "$FM_TEST_GATE_MODE" = term ]; then
  fm-crash-point "${FM_TEST_GATE%/*}" "${FM_TEST_GATE##*/}"
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$FAKE_BIN/mv"
cat > "$FAKE_BIN/ln" <<'SH'
#!/bin/bash
last=${!#}
if [ "$last" = "${FM_TEST_GATE_DEST:-}" ]; then
  case "$FM_TEST_GATE_MODE" in
    kill | term)
      fm-crash-point "${FM_TEST_GATE%/*}" "${FM_TEST_GATE##*/}"
      exit 1
      ;;
    hold)
      : > "$FM_TEST_GATE.observed"
      for _ in $(seq 1 600); do
        [ -f "$FM_TEST_GATE.release" ] && break
        /bin/sleep 0.05
      done
      [ -f "$FM_TEST_GATE.release" ] || exit 1
      ;;
  esac
fi
exec "$FM_TEST_REAL_LN" "$@"
SH
chmod +x "$FAKE_BIN/ln"

TRACKED_PIDS=()
lock_temps_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap lock_temps_cleanup EXIT

# Start one serving worker on <state>; with a gate mode the fakes are first on
# PATH and act on publishing <record> (default pid). Sets SERVE_PID. With kill
# or term it returns once the worker has been sent that signal at the gate.
serve() { # <state> <label> [kill|term|hold] [record]
  local state=$1 label=$2 mode=${3:-} record=${4:-pid}
  if [ -n "$mode" ]; then
    PATH="$FAKE_BIN:$PATH" FM_TEST_REAL_LN="$REAL_LN" FM_TEST_REAL_MV="$REAL_MV" \
      FM_TEST_GATE_MODE="$mode" FM_TEST_GATE_DEST="$state/worker.lock/$record" FM_TEST_GATE="$state.gate" \
      HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$FIXTURE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$state" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$WORKER" --serve \
      > "$TMP_ROOT/$label.out" 2> "$TMP_ROOT/$label.err" &
  else
    HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$FIXTURE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$state" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$WORKER" --serve \
      > "$TMP_ROOT/$label.out" 2> "$TMP_ROOT/$label.err" &
  fi
  SERVE_PID=$!
  TRACKED_PIDS+=("$SERVE_PID")
  case "$mode" in
    kill | term)
      fm_test_record_child "$SERVE_PID"
      fm_test_crash_at "${state%/*}" "${state##*/}.gate" "$(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')" "$SERVE_PID"
      ;;
  esac
}

# 0 once <pid> owns the lock on <state> and has published readiness; 1 if it
# exits first or the bound passes.
wait_owner() { # <state> <pid>
  local state=$1 pid=$2
  for _ in $(seq 1 400); do
    if [ "$(cat "$state/worker.lock/pid" 2>/dev/null || true)" = "$pid" ] && [ -f "$state/worker.ready" ]; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

# Reaps <pid>, a worker this shell started, once it has ended; a worker still
# running after the fixture ceiling fails the case by name instead of holding
# the suite forever (the EXIT trap then ends every tracked worker).
wait_ended() { # <pid> <what>
  local i=0 limit=$((${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 20)) still
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt "$limit" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if kill -0 "$1" 2>/dev/null; then
    still=$(ps -o args= -p "$1" 2>/dev/null)
    fail "$2: worker $1 still running after ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}s: $still"
  fi
  wait "$1" 2>/dev/null || true
}

stop_worker() { # <pid>
  kill -TERM "$1" 2>/dev/null || true
  wait_ended "$1" "a worker sent TERM"
}

# A pid no process holds: a child that has already been reaped.
dead_pid() {
  local pid
  /bin/sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

# The entry names inside <dir> matching <glob>, one per line.
entries() { # <dir> <glob>
  find "$1" -mindepth 1 -maxdepth 1 -name "$2" -exec basename {} \; 2>/dev/null | sort
}

# A lock directory holding exactly <name>=<content> pairs, older than the
# reclaim recency window.
place_lock() { # <state> <name>=<content>...
  local state=$1 pair
  shift
  mkdir -p "$state"
  chmod 700 "$state"
  (umask 077; mkdir "$state/worker.lock")
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" > "$state/worker.lock/${pair%%=*}"
    chmod 600 "$state/worker.lock/${pair%%=*}"
  done
  touch -t 200001010000 "$state/worker.lock"
}

# A replacement must take over <state>'s lock and leave no leftover temporary.
assert_replacement_owns() { # <state> <label> <what>
  local state=$1 label=$2 what=$3
  serve "$state" "$label"
  wait_owner "$state" "$SERVE_PID" \
    || fail "$what left a lock no replacement could reclaim: $(cat "$TMP_ROOT/$label.err")"
  [ -z "$(entries "$state/worker.lock" '.*')" ] \
    || fail "$what: the replacement kept leftover temporaries: $(entries "$state/worker.lock" '.*' | tr '\n' ' ')"
  stop_worker "$SERVE_PID"
  assert_absent "$state/worker.lock" "the replacement did not release its lock after $what"
}

test_killed_before_pid_publish_is_reclaimed() {
  local state="$TMP_ROOT/killed"
  serve "$state" killed-first kill
  wait_ended "$SERVE_PID" "the worker signalled at its crash point"
  assert_present "$state/worker.lock" "the killed worker left no lock to reclaim"
  assert_absent "$state/worker.lock/pid" "the worker was killed after publishing its pid, not inside the window"
  [ "$(entries "$state/worker.lock" '*' | wc -l | tr -d ' ')" = 1 ] \
    && [ -n "$(entries "$state/worker.lock" '.pid.*')" ] \
    || fail "the killed worker did not leave only its pid temporary: $(entries "$state/worker.lock" '*' | tr '\n' ' ')"
  touch -t 200001010000 "$state/worker.lock"
  assert_replacement_owns "$state" killed-second "a worker killed before publishing its pid"
  pass "a lock holding only a killed worker's pid temporary is reclaimed"
}

test_terminated_before_pid_publish_releases_lock() {
  local state="$TMP_ROOT/terminated"
  serve "$state" terminated-first term
  wait_ended "$SERVE_PID" "the worker signalled at its crash point"
  [ -z "$(entries "$state/worker.lock" '*')" ] \
    || fail "a worker terminated before publishing its pid kept its temporaries: $(entries "$state/worker.lock" '*' | tr '\n' ' ')"
  assert_absent "$state/worker.lock" "a worker terminated before publishing its pid left its lock behind"
  pass "a worker terminated before publishing its pid releases the lock on exit"
}

test_terminated_before_command_publish_releases_lock() {
  local state="$TMP_ROOT/terminated-records"
  serve "$state" terminated-records term command
  wait_ended "$SERVE_PID" "the worker signalled at its crash point"
  [ -z "$(entries "$state/worker.lock" '*')" ] \
    || fail "a worker terminated before publishing its command kept its records: $(entries "$state/worker.lock" '*' | tr '\n' ' ')"
  assert_absent "$state/worker.lock" "a worker terminated before publishing its command left its lock behind"
  pass "a worker terminated after publishing its pid but before its command releases the lock on exit"
}

test_dead_owner_start_and_command_temporaries_are_reclaimed() {
  local state dead variant
  dead=$(dead_pid)
  for variant in with-pid without-pid; do
    state="$TMP_ROOT/records-$variant"
    if [ "$variant" = with-pid ]; then
      place_lock "$state" "pid=$dead" ".start.Ab12Cd=stale" ".command.Ab12Cd=stale"
    else
      place_lock "$state" ".start.Ab12Cd=stale" ".command.Ab12Cd=stale"
    fi
    assert_replacement_owns "$state" "records-$variant" \
      "a dead owner's start and command temporaries ($variant)"
  done
  pass "a dead owner's start and command temporaries are reclaimed with or without its pid"
}

test_dead_owner_quarantine_temporary_is_reclaimed() {
  local state="$TMP_ROOT/quarantine-temp" dead
  dead=$(dead_pid)
  place_lock "$state" "pid=$dead" "start=stale" "command=stale" \
    ".quarantine.Ab12Cd=active execution could not be confirmed stopped"
  assert_replacement_owns "$state" quarantine-temp "a dead owner's unpublished quarantine temporary"
  pass "a dead owner's unpublished quarantine temporary is reclaimed"
}

test_live_publisher_temporary_is_kept() {
  local state="$TMP_ROOT/live" first second temp
  serve "$state" live-first hold
  first=$SERVE_PID
  for _ in $(seq 1 400); do
    [ -f "$state.gate.observed" ] && break
    sleep 0.05
  done
  assert_present "$state.gate.observed" "the first worker did not reach its pid publication"
  temp=$(entries "$state/worker.lock" '.pid.*')
  [ -n "$temp" ] || fail "the held worker has no pid temporary inside its lock"
  touch -t 200001010000 "$state/worker.lock"
  serve "$state" live-second
  second=$SERVE_PID
  sleep 1
  assert_present "$state/worker.lock/$temp" "a contender removed a live worker's pid temporary"
  [ "$(cat "$state/worker.lock/pid" 2>/dev/null || true)" != "$second" ] \
    || fail "a contender took the lock from a live worker that was publishing"
  : > "$state.gate.release"
  wait_owner "$state" "$first" \
    || fail "the publishing worker did not take its lock: $(cat "$TMP_ROOT/live-first.err")"
  for _ in $(seq 1 400); do
    kill -0 "$second" 2>/dev/null || break
    sleep 0.05
  done
  ! kill -0 "$second" 2>/dev/null || fail "the contender kept running beside the lock owner"
  wait "$second" 2>/dev/null || true
  [ "$(cat "$state/worker.lock/pid")" = "$first" ] || fail "the publishing worker lost its lock"
  stop_worker "$first"
  pass "a contender keeps a live publishing worker's pid temporary"
}

test_symlinked_temporary_is_refused() {
  local state="$TMP_ROOT/symlink" target="$TMP_ROOT/symlink-target"
  printf 'keep\n' > "$target"
  place_lock "$state"
  ln -s "$target" "$state/worker.lock/.pid.Ab12Cd"
  touch -t 200001010000 "$state/worker.lock"
  serve "$state" symlink
  for _ in $(seq 1 400); do
    kill -0 "$SERVE_PID" 2>/dev/null || break
    sleep 0.05
  done
  ! kill -0 "$SERVE_PID" 2>/dev/null || fail "a worker took a lock holding a symlinked temporary"
  wait "$SERVE_PID" 2>/dev/null && fail "a worker took a lock holding a symlinked temporary"
  [ -L "$state/worker.lock/.pid.Ab12Cd" ] || fail "reclaim removed a symlinked temporary"
  [ "$(cat "$target")" = keep ] || fail "reclaim changed a symlinked temporary's target"
  pass "reclaim refuses a lock holding a symlinked temporary"
}

# Left unchanged: fm_remote_job_remove_claim_records already removes a dead
# lane's .owner.* and .owner_start.* temporaries with the claim.
test_dead_claim_owner_temporary_is_cleared() {
  local state="$TMP_ROOT/claim" runs="$TMP_ROOT/claim-runs" job dead
  dead=$(dead_pid)
  # shellcheck disable=SC2016 # The staging shell expands its own positional parameters.
  job=$(env FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_QUEUE_TIMEOUT=60 bash -c '
    . "$1"
    fm_remote_job_stage "$2" "$3" "$4" fm-append-job.sh "$5" </dev/null >/dev/null || exit 1
    printf "%s\n" "$FM_REMOTE_JOB_ID"
  ' _ "$ROOT/bin/fm-remote-job-lib.sh" "$ACCOUNT_HOME" "$FIXTURE_ROOT" "$REMOTE_HOME" "$runs") \
    || fail "could not stage the claim job"
  (umask 077; mkdir "$state/jobs/$job/.claim")
  printf '%s\n' "$dead" > "$state/jobs/$job/.claim/.owner.Ab12Cd"
  chmod 600 "$state/jobs/$job/.claim/.owner.Ab12Cd"
  serve "$state" claim
  for _ in $(seq 1 400); do
    [ "$(cat "$state/jobs/$job/state" 2>/dev/null || true)" = 'done' ] && break
    sleep 0.05
  done
  [ "$(cat "$state/jobs/$job/state" 2>/dev/null || true)" = 'done' ] \
    && [ "$(cat "$state/jobs/$job/exit" 2>/dev/null || true)" = 0 ] \
    || fail "a dead lane's claim temporary stranded its job: $(cat "$TMP_ROOT/claim.err")"
  [ "$(cat "$runs")" = ran ] || fail "the reclaimed job did not run exactly once"
  stop_worker "$SERVE_PID"
  pass "a dead lane's claim owner temporary does not strand its job"
}

fm_test_run \
  test_killed_before_pid_publish_is_reclaimed \
  test_terminated_before_pid_publish_releases_lock \
  test_terminated_before_command_publish_releases_lock \
  test_dead_owner_start_and_command_temporaries_are_reclaimed \
  test_dead_owner_quarantine_temporary_is_reclaimed \
  test_live_publisher_temporary_is_kept \
  test_symlinked_temporary_is_refused \
  test_dead_claim_owner_temporary_is_cleared
