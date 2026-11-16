#!/usr/bin/env bash
# tests/fm-remote-herdr-guard.test.sh - the fm-remote launch agent's guard.
#
# Drives the real bin/fm-remote-herdr-guard.sh (and the owner library it
# sources) against a fake herdr CLI, a fake lsof that names a real holder
# process as the session-socket owner, and real holder processes whose
# environment and ancestry carry the birth markers the guard reads. It pins
# the decision table: no server -> start; an Aqua-born owner -> leave it; an
# SSH-born or unprovable owner -> stop it, wait for the socket, and start, but
# only on a start the operator's --fix authorized, else leave it. It also pins
# the start shape: the server leads its own session as a child of the guard's
# process, whose exit status is the server's and which forwards TERM to it.
# Where herdr is installed, a final case starts one real server through the
# guard on an isolated fm-lab- session that bin/fm-herdr-lab.sh prepares,
# stops, and tears down, and reads its detached_server_daemon capability.
# Nothing here touches the runner's own fleet herdr session, launch agents, or
# login session, and no live harness guard applies: the birth verdict comes
# from process environment and ancestry, which are kernel facts rather than
# vendor output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the guard parses herdr's JSON, and jq is the holder process)"; exit 0; }
command -v mkfifo >/dev/null 2>&1 || { echo "skip: mkfifo not found (holder processes block on a fifo)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-guard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOLDER_PIDS=()
HOLDER_FD=5
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_SESSION=
LAB_AGENT_PID=
cleanup() {
  [ -z "$LAB_AGENT_PID" ] || kill -TERM "$LAB_AGENT_PID" 2>/dev/null || true
  [ -z "$LAB_SESSION" ] || "$LAB_HELPER" teardown "$LAB_SESSION" >/dev/null 2>&1 \
    || printf 'warning: lab session %s needs a manual teardown through %s\n' "$LAB_SESSION" "$LAB_HELPER" >&2
  if [ "${#HOLDER_PIDS[@]}" -gt 0 ]; then kill "${HOLDER_PIDS[@]}" 2>/dev/null || true; fi
  fm_test_cleanup || true
}
trap cleanup EXIT

GUARD="$ROOT/bin/fm-remote-herdr-guard.sh"
JQ=$(command -v jq)
HOLDER_JQ=$(fm_test_nonplatform_binary "$JQ" "$TMP_ROOT") ||
  fail "cannot build a non-platform jq holder on this host"
SESSION=fm-remote

# The guard must see only the fixture and the system tools it really needs,
# so a case can also present a host with NO lsof.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
for tool in ps awk sed grep tr dirname basename sleep cat cp mv rm env bash sh id head uname perl; do
  real=$(command -v "$tool") || fail "test host lacks $tool"
  ln -sf "$real" "$TOOLS/$tool"
done
ln -sf "$JQ" "$TOOLS/jq"
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE"
cat > "$FAKE/lsof" <<'SH'
#!/usr/bin/env bash
# Prints the -F pn shape for every pid listed in the owner file.
[ -f "$FM_FAKE_SOCKET_OWNER" ] || exit 0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  printf 'p%s\n' "$pid"
  printf 'n%s\n' "$FM_FAKE_HERDR_SOCKET"
done < "$FM_FAKE_SOCKET_OWNER"
SH
cat > "$FAKE/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = print ] || exit 0
domain=${2:-}
scope=${domain%%/*}
label=${domain#*/}
label=${label#*/}
state="$FM_FAKE_STATE/launchctl-$scope-$label"
[ -f "$state" ] || exit 113
cat "$state"
SH
cat > "$FAKE/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
running=$(cat "$FM_FAKE_HERDR_RUNNING" 2>/dev/null || printf 'false')
case "$*" in
  "status --json --session "*)
    if [ -f "$FM_FAKE_STATE/release-after" ]; then
      left=$(cat "$FM_FAKE_STATE/release-after")
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$FM_FAKE_STATE/release-after"
      else
        rm -f "$FM_FAKE_STATE/release-after"
        printf 'false\n' > "$FM_FAKE_HERDR_RUNNING"
        running=false
      fi
    fi
    printf '{"server":{"running":%s,"socket":"%s","version":"0.9.0"},"client":{"version":"0.9.0"}}\n' \
      "$running" "$FM_FAKE_HERDR_SOCKET"
    ;;
  "server stop --session "*)
    if [ -f "$FM_FAKE_STATE/stop-ignored" ]; then
      exit 0
    elif [ -f "$FM_FAKE_STATE/stop-releases-after" ]; then
      cp "$FM_FAKE_STATE/stop-releases-after" "$FM_FAKE_STATE/release-after"
    else
      printf 'false\n' > "$FM_FAKE_HERDR_RUNNING"
    fi
    ;;
  "server --session "*)
    # Records the process shape the guard gave the server (ps sid is Linux
    # only; macOS prints no session id), then behaves as the case asks.
    sid=$(ps -o sid= -p "$$" 2>/dev/null | tr -d ' ')
    pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
    printf 'pid=%s ppid=%s sid=%s pgid=%s session=%s\n' "$$" "$PPID" "$sid" "$pgid" "${3:-}" > "$FM_FAKE_STATE/started.tmp"
    mv "$FM_FAKE_STATE/started.tmp" "$FM_FAKE_STATE/started"
    if [ -f "$FM_FAKE_STATE/server-runs" ]; then
      trap 'printf "terminated\n" > "$FM_FAKE_STATE/server-terminated"; exit 0' TERM
      while :; do sleep 0.1; done
    fi
    [ ! -f "$FM_FAKE_STATE/server-killed" ] || kill -KILL "$$"
    exit "$(cat "$FM_FAKE_STATE/server-exit" 2>/dev/null || printf 0)"
    ;;
esac
exit 0
SH
chmod +x "$FAKE/lsof" "$FAKE/launchctl" "$FAKE/herdr"
cp "$FAKE/lsof" "$TMP_ROOT/lsof.fake"

# hold <marker-env...> -> HOLDER_PID: a real non-platform process (jq blocked
# on a fifo this test keeps open) whose environment is exactly the markers.
hold() {
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  # Open read-write so this never blocks on the reader; the holder sees EOF
  # only when the descriptor closes at exit.
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  env -i "$@" "$HOLDER_JQ" . "$fifo" &
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
  HOLDER_FD=$((HOLDER_FD + 1))
}

# hold_under <argv0> <arg...> -- : a marker-free holder whose PARENT process
# carries the given argv[0] and arguments (the ancestry the guard inspects).
hold_under() {
  local argv0=$1 fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo" pidfile="$TMP_ROOT/holder-$HOLDER_FD.pid"
  shift
  rm -f "$fifo" "$pidfile"
  mkfifo "$fifo"
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  ( export FM_HOLDER_JQ="$HOLDER_JQ" FM_HOLDER_FIFO="$fifo" FM_HOLDER_PIDFILE="$pidfile"
    exec -a "$argv0" bash -c 'env -i FM_HOLDER=1 "$FM_HOLDER_JQ" . "$FM_HOLDER_FIFO" & printf "%s\n" "$!" > "$FM_HOLDER_PIDFILE"; wait' "$@" ) &
  HOLDER_PIDS+=("$!")
  HOLDER_FD=$((HOLDER_FD + 1))
  local i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "holder under $argv0 did not report its pid"
  HOLDER_PID=$(cat "$pidfile")
  HOLDER_PIDS+=("$HOLDER_PID")
}

# hold_child <marker-env...> -> HOLDER_PID, HOLDER_PARENT_PID: a holder with
# exactly the markers whose parent is a separate live process, the shape the
# launch agent's supervisor gives its session-leader server.
hold_child() {
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo" pidfile="$TMP_ROOT/holder-$HOLDER_FD.pid"
  rm -f "$fifo" "$pidfile"
  mkfifo "$fifo"
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  # shellcheck disable=SC2016 # the inner bash expands its own arguments
  env FM_HOLDER_JQ="$HOLDER_JQ" FM_HOLDER_FIFO="$fifo" FM_HOLDER_PIDFILE="$pidfile" \
    bash -c 'env -i "$@" "$FM_HOLDER_JQ" . "$FM_HOLDER_FIFO" & printf "%s\n" "$!" > "$FM_HOLDER_PIDFILE"; wait' bash "$@" &
  HOLDER_PARENT_PID=$!
  HOLDER_PIDS+=("$HOLDER_PARENT_PID")
  HOLDER_FD=$((HOLDER_FD + 1))
  local i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "child holder did not report its pid"
  HOLDER_PID=$(cat "$pidfile")
  HOLDER_PIDS+=("$HOLDER_PID")
}

# wait_exit <pid> <what> -> WAIT_RC: the exit status of a background child,
# failing instead of hanging when it does not exit within ten seconds.
wait_exit() {
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$1" 2>/dev/null; then
    kill -KILL "$1" 2>/dev/null || true
    fail "$2 did not exit within ten seconds"
  fi
  set +e
  wait "$1"
  WAIT_RC=$?
  set -e
}

CASE_N=0
new_case() { # [running|stopped]
  CASE_N=$((CASE_N + 1))
  CASE_STATE="$TMP_ROOT/case$CASE_N"
  mkdir -p "$CASE_STATE"
  CASE_LOG="$CASE_STATE/herdr.log"
  : > "$CASE_LOG"
  CASE_RUNNING="$CASE_STATE/running"
  printf '%s\n' "$([ "${1:-running}" = running ] && printf true || printf false)" > "$CASE_RUNNING"
  CASE_OWNER="$CASE_STATE/socket-owner"
  CASE_SOCKET="$CASE_STATE/herdr.sock"
  CASE_PATH="$FAKE:$TOOLS"
}

load_job() { # <gui|user> <label> [pid]
  if [ -n "${3:-}" ]; then
    printf 'pid = %s\n' "$3" > "$CASE_STATE/launchctl-$1-$2"
  else
    printf 'state = running\n' > "$CASE_STATE/launchctl-$1-$2"
  fi
}

guard() { # [extra env assignments...]
  set +e
  GUARD_OUT=$(
    env -i PATH="$CASE_PATH" HOME="$TMP_ROOT" \
      FM_FAKE_STATE="$CASE_STATE" FM_FAKE_HERDR_LOG="$CASE_LOG" FM_FAKE_HERDR_RUNNING="$CASE_RUNNING" \
      FM_FAKE_SOCKET_OWNER="$CASE_OWNER" FM_FAKE_HERDR_SOCKET="$CASE_SOCKET" \
      FM_HOLDER_JQ="$HOLDER_JQ" \
      FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS=8 \
      "$@" "$GUARD" "$FAKE/herdr" "$SESSION" 2>&1
  )
  GUARD_RC=$?
  set -e
}

herdr_calls() { cat "$CASE_LOG"; }
TAKEOVER_MARKER="$TMP_ROOT/.firstmate/remote-herdr-takeover-$SESSION"
# authorize [pid]: construct the doctor/guard two-line authorization protocol.
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
authorize() {
  local pid=${1:-$$} start
  mkdir -p "${TAKEOVER_MARKER%/*}"
  start=$(fm_remote_job_process_start "$pid") || start=finished-process
  printf '%s\n%s\n' "$pid" "$start" > "$TAKEOVER_MARKER"
}
assert_started() { # <msg>
  [ -f "$CASE_STATE/started" ] || fail "$1"
  assert_grep "session=$SESSION" "$CASE_STATE/started" "the server was started for the wrong session"
}
assert_not_started() { assert_absent "$CASE_STATE/started" "$1"; }
assert_stop_before_start() {
  local calls stop_line start_line
  calls=$(herdr_calls)
  stop_line=$(printf '%s\n' "$calls" | grep -n "^server stop --session $SESSION$" | head -1 | cut -d: -f1)
  start_line=$(printf '%s\n' "$calls" | grep -n "^server --session $SESSION$" | head -1 | cut -d: -f1)
  [ -n "$stop_line" ] || fail "the guard never asked the foreign server to stop"
  [ -n "$start_line" ] || fail "the guard never started its own server"
  [ "$stop_line" -lt "$start_line" ] || fail "the guard started its server before stopping the foreign one"
}

# Prove the holder construction on this host: the environment of a jq holder
# must be readable, or every marker case would be vacuous.
hold FM_PROBE_MARKER=1
PROBE_PID=$HOLDER_PID
sleep 0.2
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$ROOT/bin/fm-remote-herdr-owner-lib.sh"
probe_env=$(fm_remote_herdr_process_env "$PROBE_PID")
case "$probe_env" in
  *FM_PROBE_MARKER=1*) ;;
  *) fail "this host does not expose a holder's environment (macOS hides platform-binary environments; the jq holder at $HOLDER_JQ must be a non-platform binary): $probe_env" ;;
esac
pass "holder processes expose their environment to the owner library"

# --- no server: the guard becomes the server ---------------------------------

new_case stopped
guard
expect_code 0 "$GUARD_RC" "the guard failed when no server owned the session"
assert_started "the guard did not start the server when none owned the session"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped something when no server owned the session"
assert_contains "$GUARD_OUT" "no server owns session $SESSION" "the guard did not report the empty session"
pass "an empty session is started inside the launch agent"

# --- the server is a session leader under the launch agent's own process ----

started_field() { # <name> -> the value recorded by the fake server
  sed -n "s/.* $1=\([^ ]*\).*/\1/p; s/^$1=\([^ ]*\).*/\1/p" "$CASE_STATE/started" | head -1
}

assert_session_leader_child() { # <guard-pid>
  local pid
  pid=$(started_field pid)
  [ -n "$pid" ] || fail "the fake server did not record its pid"
  assert_equals "$1" "$(started_field ppid)" "the server's parent is not the launch agent's process (pid $1)"
  assert_equals "$pid" "$(started_field pgid)" "the server does not lead its own process group"
  if [ "$(uname -s)" = Linux ]; then
    assert_equals "$pid" "$(started_field sid)" "the server is not a session leader"
  fi
}

new_case stopped
guard
expect_code 0 "$GUARD_RC" "the guard failed to start a server that exited cleanly"
agent_pid=$(printf '%s\n' "$GUARD_OUT" | sed -n 's/.*inside this launch agent (pid \([0-9]*\)).*/\1/p' | head -1)
[ -n "$agent_pid" ] || fail "the guard did not name its own pid when it started the server: $GUARD_OUT"
assert_session_leader_child "$agent_pid"
pass "the server leads its own session while the launch agent's process stays its parent"

# --- the launch agent's exit status is the server's --------------------------

new_case stopped
printf '3\n' > "$CASE_STATE/server-exit"
guard
assert_started "the guard did not start the failing server"
expect_code 3 "$GUARD_RC" "a server that failed did not make the launch agent fail, so launchd would not retry"

new_case stopped
touch "$CASE_STATE/server-killed"
guard
assert_started "the guard did not start the crashing server"
expect_code 137 "$GUARD_RC" "a server killed by a signal did not make the launch agent exit 128+signal"
pass "a clean server exit rests the job, and a failure or crash exits non-zero for a launchd retry"

# --- a termination signal to the launch agent stops the server ---------------

new_case stopped
touch "$CASE_STATE/server-runs"
env -i PATH="$CASE_PATH" HOME="$TMP_ROOT" \
  FM_FAKE_STATE="$CASE_STATE" FM_FAKE_HERDR_LOG="$CASE_LOG" FM_FAKE_HERDR_RUNNING="$CASE_RUNNING" \
  FM_FAKE_SOCKET_OWNER="$CASE_OWNER" FM_FAKE_HERDR_SOCKET="$CASE_SOCKET" \
  "$GUARD" "$FAKE/herdr" "$SESSION" > "$CASE_STATE/guard.out" 2>&1 &
agent_pid=$!
HOLDER_PIDS+=("$agent_pid")
i=0
while [ ! -f "$CASE_STATE/started" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
assert_started "the guard did not start the long-running server"
assert_session_leader_child "$agent_pid"
server_pid=$(started_field pid)
kill -TERM "$agent_pid"
wait_exit "$agent_pid" "the launch agent sent TERM"
expect_code 0 "$WAIT_RC" "the launch agent did not exit with the server's clean-shutdown status after a forwarded TERM"
assert_present "$CASE_STATE/server-terminated" "the TERM sent to the launch agent never reached the server"
i=0
while kill -0 "$server_pid" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
kill -0 "$server_pid" 2>/dev/null && fail "the server (pid $server_pid) outlived the launch agent's TERM"
pass "a termination signal to the launch agent is forwarded to the server, which stops"

# --- without perl the guard refuses rather than start a non-leader server ---

TOOLS_NO_PERL="$TMP_ROOT/tools-no-perl"
mkdir -p "$TOOLS_NO_PERL"
for tool in "$TOOLS"/*; do
  [ "${tool##*/}" = perl ] || ln -sf "$(readlink "$tool")" "$TOOLS_NO_PERL/${tool##*/}"
done
new_case stopped
CASE_PATH="$FAKE:$TOOLS_NO_PERL"
guard
expect_code 1 "$GUARD_RC" "the guard did not fail when perl was missing"
assert_not_started "the guard started a server it could not make a session leader"
assert_contains "$GUARD_OUT" 'perl does not resolve' "the guard did not name the missing perl"
pass "a host without perl is refused before any server starts"

# --- an Aqua-born owner is left alone ----------------------------------------

hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
LAUNCHD_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
BACKGROUND_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=0
XPC_ZERO_PID=$HOLDER_PID
hold FM_REMOTE_JOB_ACTIVE=1
WORKER_PID=$HOLDER_PID
hold SSH_CONNECTION='100.102.217.78 51234 100.100.1.2 22' SSH_CLIENT='100.102.217.78 51234 22'
SSH_PID=$HOLDER_PID
hold FM_NOTHING_TO_SEE=1
UNMARKED_PID=$HOLDER_PID
hold_under herdr --session "$SESSION" remote-client-bridge
BRIDGE_CHILD_PID=$HOLDER_PID
hold_under 'sshd-session:' kunchen@notty
SSHD_CHILD_PID=$HOLDER_PID
hold_child XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
SUPERVISED_PID=$HOLDER_PID
SUPERVISOR_PID=$HOLDER_PARENT_PID
hold_child SSH_CONNECTION='100.102.217.78 51234 100.100.1.2 22' XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
SUPERVISED_SSH_PID=$HOLDER_PID
SUPERVISED_SSH_PARENT_PID=$HOLDER_PARENT_PID
sleep 0.3

new_case running
printf '%s\n' "$LAUNCHD_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for a gui-domain launchd owner"
assert_not_started "the guard started a second server over a gui-domain launchd owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a gui-domain launchd owner"
assert_contains "$GUARD_OUT" "pid $LAUNCHD_PID born in the Aqua login session (launchd)" \
  "the guard did not name the launchd owner"

new_case running
printf '%s\n' "$WORKER_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.remote-job
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for the gui-domain worker owner"
assert_not_started "the guard started a second server over a gui-domain worker owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a gui-domain worker owner"
assert_contains "$GUARD_OUT" "pid $WORKER_PID born in the Aqua login session (worker)" \
  "the guard did not name the worker owner"
pass "launchd and worker markers require gui-domain launchctl proof"

# The label is also loaded in the user domain in these cases, so only the
# gui job's own pid can prove the birth: the job is the supervisor and the
# socket owner is its session-leader child.
new_case running
printf '%s\n' "$SUPERVISED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$SUPERVISOR_PID"
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for a child of the gui-domain launchd job"
assert_not_started "the guard started a second server over a child of the launchd job"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a child of the launchd job"
assert_contains "$GUARD_OUT" "pid $SUPERVISED_PID born in the Aqua login session (launchd)" \
  "a server whose parent is the launchd job was not proven Aqua-born"

new_case running
printf '%s\n' "$SUPERVISED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 0 "$GUARD_RC" "the guard failed for a server whose parent is not the launchd job"
assert_contains "$GUARD_OUT" "pid $SUPERVISED_PID born outside the Aqua login session (unknown)" \
  "a server whose parent is not the launchd job was trusted as Aqua"

new_case running
printf '%s\n' "$SUPERVISED_SSH_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$SUPERVISED_SSH_PARENT_PID"
guard
expect_code 0 "$GUARD_RC" "the guard failed for an SSH-marked child of the launchd job"
assert_contains "$GUARD_OUT" "pid $SUPERVISED_SSH_PID born outside the Aqua login session (ssh)" \
  "an SSH-marked server was trusted because its parent is the launchd job"
pass "a server whose parent is the gui-domain launchd job is Aqua-born unless it carries SSH markers"

# The rolled-out macOS shape: the forked session-leader server sees
# XPC_SERVICE_NAME=0, so only launchd's record for the label the guard derives
# from its session can prove the birth.
hold_child XPC_SERVICE_NAME=0
FORKED_PID=$HOLDER_PID
FORKED_PARENT_PID=$HOLDER_PARENT_PID
hold_child SSH_CONNECTION='100.102.217.78 51234 100.100.1.2 22' XPC_SERVICE_NAME=0
FORKED_SSH_PID=$HOLDER_PID
FORKED_SSH_PARENT_PID=$HOLDER_PARENT_PID
SSHD_PARENT_PID=$(ps -o ppid= -p "$SSHD_CHILD_PID" | tr -d ' ')

new_case running
printf '%s\n' "$FORKED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$FORKED_PARENT_PID"
authorize
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for an XPC_SERVICE_NAME=0 child of the launchd job"
assert_not_started "the guard started a second server over an XPC_SERVICE_NAME=0 child of the launchd job"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped an XPC_SERVICE_NAME=0 child of the launchd job"
assert_contains "$GUARD_OUT" "pid $FORKED_PID born in the Aqua login session (launchd)" \
  "an XPC_SERVICE_NAME=0 child of the launchd job was not proven Aqua-born"
rm -f "$TAKEOVER_MARKER"

# None of the cases below may become launchd, and none is authorized, so the
# guard must leave each server alone.
forked_case() { # <what> <owner> <birth>
  guard
  expect_code 0 "$GUARD_RC" "the guard failed for $1"
  assert_not_started "the guard started a server over $1 without authorization"
  assert_contains "$GUARD_OUT" "pid $2 born outside the Aqua login session ($3)" "$1 was trusted as Aqua"
}
new_case running
printf '%s\n' "$FORKED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
forked_case "a forked server whose parent is not the launchd job" "$FORKED_PID" unknown
new_case running
printf '%s\n' "$FORKED_PID" > "$CASE_OWNER"
load_job user dev.firstmate.herdr.fm-remote "$FORKED_PARENT_PID"
forked_case "a forked server whose label is loaded only in the user domain" "$FORKED_PID" unknown
new_case running
printf '%s\n' "$FORKED_PID" > "$CASE_OWNER"
forked_case "a forked server whose launchctl print fails" "$FORKED_PID" unknown
new_case running
printf '%s\n' "$FORKED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote
forked_case "a forked server whose launchd job reports no pid" "$FORKED_PID" unknown
new_case running
printf '%s\n' "$FORKED_SSH_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$FORKED_SSH_PARENT_PID"
forked_case "an SSH-marked forked child of the launchd job" "$FORKED_SSH_PID" ssh
new_case running
printf '%s\n' "$SSHD_CHILD_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$SSHD_PARENT_PID"
forked_case "an sshd-born server whose parent is reported as the launchd job" "$SSHD_CHILD_PID" ssh

# A missing or empty expected label proves nothing even when the gui job's
# pid is the owner's parent; the guard always supplies one, so this case is
# read through the library the doctor and guard share.
new_case running
load_job gui dev.firstmate.herdr.fm-remote "$FORKED_PARENT_PID"
for expected in '' 0; do
  # shellcheck disable=SC2016 # the inner bash expands its own arguments
  birth=$(env -i PATH="$CASE_PATH" FM_FAKE_STATE="$CASE_STATE" \
    bash -c '. "$1"; fm_remote_herdr_owner_birth "$2" "$3"' bash \
    "$ROOT/bin/fm-remote-herdr-owner-lib.sh" "$FORKED_PID" "$expected")
  assert_equals unknown "$birth" "a forked server was proven Aqua-born with expected label '$expected'"
done
# shellcheck disable=SC2016 # the inner bash expands its own arguments
birth=$(env -i PATH="$CASE_PATH" FM_FAKE_STATE="$CASE_STATE" \
  bash -c '. "$1"; fm_remote_herdr_owner_birth "$2"' bash \
  "$ROOT/bin/fm-remote-herdr-owner-lib.sh" "$FORKED_PID")
assert_equals unknown "$birth" "a forked server was proven Aqua-born with no expected label"
pass "an XPC_SERVICE_NAME=0 server is Aqua-born only when the expected label's gui job is its parent"

# --- a foreign owner is stopped, then the guard becomes the server -----------

new_case running
printf '%s\n' "$BACKGROUND_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote
load_job user dev.firstmate.herdr.fm-remote
authorize
guard
expect_code 0 "$GUARD_RC" "the guard failed to take over a label also loaded in the user domain"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $BACKGROUND_PID born outside the Aqua login session (unknown)" \
  "a user-domain label was trusted as Aqua"

new_case running
printf '%s\n' "$XPC_ZERO_PID" > "$CASE_OWNER"
authorize
guard
expect_code 0 "$GUARD_RC" "the guard failed to take over an XPC_SERVICE_NAME=0 owner"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $XPC_ZERO_PID born outside the Aqua login session (unknown)" \
  "XPC_SERVICE_NAME=0 was trusted as Aqua"

for foreign in "ssh $SSH_PID" "ssh $BRIDGE_CHILD_PID" "ssh $SSHD_CHILD_PID" "unknown $UNMARKED_PID"; do
  new_case running
  printf '%s\n' "${foreign#* }" > "$CASE_OWNER"
  authorize
  guard
  expect_code 0 "$GUARD_RC" "the guard failed to take over from a ${foreign%% *} owner (pid ${foreign#* })"
  assert_stop_before_start
  assert_started "the guard did not start its own server after the ${foreign%% *} owner released the socket"
  assert_contains "$GUARD_OUT" "pid ${foreign#* } born outside the Aqua login session (${foreign%% *})" \
    "the guard did not name the foreign owner and its birth"
done
assert_absent "$TAKEOVER_MARKER" "the guard left its one-shot takeover authorization behind"
pass "background, inherited-XPC, SSH-born, SSH-descended, and unprovable owners are taken over when the operator authorizes it"

# --- without the operator's authorization a foreign owner is left alone -----

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
guard
expect_code 0 "$GUARD_RC" "an unauthorized start over a foreign server did not exit 0, so launchd would respawn it"
assert_not_contains "$(herdr_calls)" 'server stop' "an unauthorized start stopped a foreign server"
assert_not_started "an unauthorized start started a second server"
assert_contains "$GUARD_OUT" "pid $SSH_PID born outside the Aqua login session (ssh); leaving it alone" \
  "the guard did not report leaving the foreign server alone"

# A reused PID is modeled deterministically by pairing a live PID with a
# different start identity. The authorization contract requires both to match;
# PID-only acceptance would stop this foreign server.
for start in stale-process-start ''; do
  new_case running
  printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
  mkdir -p "${TAKEOVER_MARKER%/*}"
  printf '%s\n%s\n' "$$" "$start" > "$TAKEOVER_MARKER"
  guard
  expect_code 0 "$GUARD_RC" "a mismatched process identity made the guard fail"
  assert_not_contains "$(herdr_calls)" 'server stop' "a live PID revived stale takeover permission"
  assert_not_started "stale takeover permission started a replacement server"
  assert_absent "$TAKEOVER_MARKER" "stale takeover permission was not consumed"
done
pass "a live PID cannot revive a missing or mismatched process-start identity"

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
( exit 0 ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
authorize "$DEAD_PID"
guard
expect_code 0 "$GUARD_RC" "a stale authorization made the guard fail"
assert_not_contains "$(herdr_calls)" 'server stop' "an authorization from a finished doctor stopped a foreign server"
assert_absent "$TAKEOVER_MARKER" "a stale authorization was left for a later start to honor"

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
authorize
guard
assert_stop_before_start
: > "$CASE_LOG"
rm -f "$CASE_STATE/started"
printf 'true\n' > "$CASE_RUNNING"
guard
assert_not_contains "$(herdr_calls)" 'server stop' "one authorization took over the session twice"
pass "a login, KeepAlive, or automatic start never takes over a foreign server, and an authorization is honored once"

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
CASE_PATH="$FAKE:$TOOLS_NO_PERL"
authorize
guard
expect_code 1 "$GUARD_RC" "an authorized takeover without perl did not fail"
assert_not_contains "$(herdr_calls)" 'server stop' "an authorized takeover without perl stopped the foreign server it could not replace"
assert_not_started "an authorized takeover without perl started a server"
rm -f "$TAKEOVER_MARKER"
pass "an authorized takeover without perl leaves the foreign server running"

# --- an owner nobody can prove is treated as foreign -------------------------

new_case running
authorize
guard
expect_code 0 "$GUARD_RC" "the guard failed when lsof listed no owner"
assert_contains "$GUARD_OUT" 'no herdr process could be proven to own' "the guard did not report the unprovable owner"
assert_stop_before_start
pass "a running session with no provable owner is taken over rather than trusted"

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
rm -f "$FAKE/lsof"
authorize
guard
cp "$TMP_ROOT/lsof.fake" "$FAKE/lsof"
chmod +x "$FAKE/lsof"
expect_code 0 "$GUARD_RC" "the guard failed when lsof was absent"
assert_contains "$GUARD_OUT" 'lsof does not resolve' "the guard did not report the missing lsof"
assert_stop_before_start
pass "a host without lsof cannot prove an Aqua birth, so the session is taken over"

# --- a foreign owner that keeps the socket makes the guard fail for a retry --

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
touch "$CASE_STATE/stop-ignored"
authorize
guard
expect_code 1 "$GUARD_RC" "the guard did not exit 1 when the foreign server kept its socket"
assert_not_started "the guard started a server while the foreign one still held the socket"
assert_contains "$(herdr_calls)" "server stop --session $SESSION" "the guard never asked the foreign server to stop"
assert_contains "$GUARD_OUT" 'did not release its socket within 8 tenths' "the guard did not report the bounded wait"
pass "a foreign server that never releases the socket yields exit 1 so launchd retries"

# --- the release wait is polled, not assumed ---------------------------------

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
printf '3\n' > "$CASE_STATE/stop-releases-after"
authorize
guard
expect_code 0 "$GUARD_RC" "the guard gave up on a server that released its socket after a few polls"
assert_started "the guard did not start after the delayed release"
assert_contains "$GUARD_OUT" 'released its socket after' "the guard did not report the observed release"
[ "$(grep -c "^status --json --session $SESSION$" "$CASE_LOG")" -ge 4 ] \
  || fail "the guard did not keep polling the session status until the socket was released"
pass "the guard starts as soon as the foreign server releases the socket"

# --- usage errors never touch a server ---------------------------------------

new_case running
set +e
env -i PATH="$CASE_PATH" "$GUARD" "$FAKE/herdr" >/dev/null 2>&1
rc=$?
set -e
expect_code 2 "$rc" "a missing session argument was not a usage error"
set +e
env -i PATH="$CASE_PATH" "$GUARD" "$TMP_ROOT/no-such-herdr" "$SESSION" >/dev/null 2>&1
rc=$?
set -e
expect_code 1 "$rc" "a non-executable herdr path was not refused"
[ ! -s "$CASE_LOG" ] || fail "a refused invocation still called herdr"
pass "argument errors are refused before any herdr call"

# --- a real herdr server started by the guard reports a detached daemon ------
#
# Herdr derives its detached_server_daemon capability from the server process
# itself, so only a real server can prove the shape is the one herdr accepts.
# The guard starts it on an isolated fm-lab- session that bin/fm-herdr-lab.sh
# prepares, reads, stops, and tears down; the fleet session is never named.

lab_status() {
  "$LAB_HELPER" run "$LAB_SESSION" status --json 2>/dev/null || true
}

if ! command -v herdr >/dev/null 2>&1; then
  pass "real herdr: not installed, so the detached-daemon check did not run"
else
  LAB_SESSION=$("$LAB_HELPER" name guard-leader) || fail "could not name an isolated Herdr lab session"
  "$LAB_HELPER" prepare "$LAB_SESSION" || fail "could not prepare isolated Herdr lab session $LAB_SESSION"
  env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SESSION -u HERDR_ENV \
    "$GUARD" "$(command -v herdr)" "$LAB_SESSION" > "$TMP_ROOT/lab-guard.out" 2>&1 &
  LAB_AGENT_PID=$!
  i=0
  while [ "$(lab_status | jq -r '.server.running // false' 2>/dev/null)" != true ] && [ "$i" -lt 100 ]; do
    kill -0 "$LAB_AGENT_PID" 2>/dev/null || fail "the guard exited before the lab server ran: $(cat "$TMP_ROOT/lab-guard.out")"
    sleep 0.1
    i=$((i + 1))
  done
  LAB_STATUS=$(lab_status)
  assert_equals true "$(printf '%s' "$LAB_STATUS" | jq -r '.server.running // false')" \
    "the lab server started by the guard never reported running"
  assert_equals true "$(printf '%s' "$LAB_STATUS" | jq -r '.server.capabilities.detached_server_daemon // false')" \
    "herdr does not report the guard-started server as a detached daemon"
  LAB_OWNER=$(fm_remote_herdr_socket_owner "$(printf '%s' "$LAB_STATUS" | jq -r '.server.socket // empty')")
  if [ -n "$LAB_OWNER" ]; then
    assert_equals "$LAB_AGENT_PID" "$(ps -o ppid= -p "$LAB_OWNER" | tr -d ' ')" \
      "the real lab server's parent is not the guard's process"
  fi
  "$LAB_HELPER" stop "$LAB_SESSION" >/dev/null 2>&1 || fail "the guarded lab stop failed for $LAB_SESSION"
  wait_exit "$LAB_AGENT_PID" "the launch agent of the stopped lab server"
  LAB_AGENT_PID=
  expect_code 0 "$WAIT_RC" "a clean stop of the real server did not end the launch agent with exit 0"
  "$LAB_HELPER" teardown "$LAB_SESSION" || fail "the isolated lab teardown failed for $LAB_SESSION"
  LAB_SESSION=
  pass "real herdr: the guard-started server reports detached_server_daemon, and a clean stop exits 0"
fi
