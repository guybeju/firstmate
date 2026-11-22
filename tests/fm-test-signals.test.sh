#!/usr/bin/env bash
# Behaviour tests for tests/check-signals.sh, the static check that no test
# signals a computed target outside the guarded helper, and the check itself
# over the test directories.
#
# The fixtures are files this script writes; their signal words come from a
# variable, so this file's own text is not a finding. Nothing here sends a
# signal or starts a process beyond the checker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/tests/check-signals.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-signals)
sig='kill'

check_fixture() {  # <name>: runs the checker on fixture <name>; sets CHECK_RC and CHECK_OUT.
  CHECK_RC=0
  CHECK_OUT=$(bash "$CHECK" "$TMP_ROOT/$1.sh" 2>&1) || CHECK_RC=$?
}

expect_finding() {  # <name> <expected text> <label>
  check_fixture "$1"
  [ "$CHECK_RC" -eq 1 ] || fail "$3 was not refused (status $CHECK_RC): $CHECK_OUT"
  assert_contains "$CHECK_OUT" "$2" "$3 was refused for the wrong reason"
}

expect_clean() {  # <name> <label>
  check_fixture "$1"
  [ "$CHECK_RC" -eq 0 ] || fail "$2 was refused: $CHECK_OUT"
}

test_a_stand_in_that_signals_its_parent_is_refused() {
  cat > "$TMP_ROOT/one-level.sh" <<EOF
cat > "\$fakebin/cp" <<'SH'
#!/usr/bin/env bash
$sig -TERM "\$PPID"
exit 0
SH
EOF
  expect_finding one-level "a stand-in that reads parentage (line 3) and signals (line 3)" \
    "a stand-in signalling its \$PPID"
  assert_contains "$CHECK_OUT" "a signal and a parentage read on one line" \
    "the one-line form was not named"
  pass "a stand-in that signals \$PPID is refused"
}

test_a_stand_in_that_signals_a_grandparent_on_another_line_is_refused() {
  cat > "$TMP_ROOT/two-level.sh" <<EOF
cat > "\$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
spawn_pid=\\\$(ps -o ppid= -p "\\\$PPID" | tr -d ' ')
case "\\\$spawn_pid" in ''|*[!0-9]*) exit 1 ;; esac
$sig -TERM "\\\$spawn_pid"
SH
EOF
  expect_finding two-level "a stand-in that reads parentage (line 3) and signals (line 5)" \
    "a stand-in signalling the parent of its \$PPID"
  cat > "$TMP_ROOT/proc-walk.sh" <<EOF
cat > "\$fakebin/herdr" <<SH
#!/usr/bin/env bash
read_shell=\\\$(sed 's/^[^)]*) //' /proc/\\\$pid/stat | awk '{print \\\$2}')
$sig -KILL "\\\$read_shell"
SH
EOF
  expect_finding proc-walk "a stand-in that reads parentage (line 3) and signals (line 4)" \
    "a stand-in walking /proc stat"
  cat > "$TMP_ROOT/pattern.sh" <<EOF
cat > "\$fakebin/x" <<'SH'
p=\$PPID
p$sig -P "\$p"
SH
EOF
  expect_finding pattern "a stand-in that reads parentage" "a stand-in using a pattern-based signal command"
  pass "a stand-in that reads parentage on one line and signals on another is refused"
}

test_the_removed_crash_shim_is_refused() {
  printf '%s\n' "fm-crash-""inject \"\$handoff_pid\" || exit 1" > "$TMP_ROOT/shim.sh"
  expect_finding shim "uses the removed crash-inject shim" "a call of the removed crash shim"
  pass "any use of the removed crash-inject shim is refused"
}

test_verifying_recording_probing_and_self_signals_pass() {
  cat > "$TMP_ROOT/allowed.sh" <<EOF
# $sig -TERM "\$PPID" in a comment is not code
cat > "\$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'pid=%s ppid=%s\n' "\$\$" "\$PPID" > "\$FM_FAKE_STATE/started"
[ ! -f "\$FM_FAKE_STATE/server-killed" ] || $sig -KILL "\$\$"
SH
while $sig -0 "\$PPID" 2>/dev/null; do sleep 0.05; done
cat > "\$fakebin/fm-crash-point" <<'SH'
pid=\$PPID
while [ "\$pid" -gt 1 ]; do pid=\$(ps -o ppid= -p "\$pid" | tr -d ' '); done
SH
$sig -TERM "\$WATCHER_PID"
EOF
  expect_clean allowed "a stand-in recording \$PPID and signalling only \$\$, a probe, or a verify-only walk"
  pass "recording or verifying parentage, signal-0 probes and a stand-in's own \$\$ pass"
}

expect_form() {  # <name> <what> <label>: fixture <name> is refused as a signal to <what>.
  expect_finding "$1" "a signal to $2 outside the guarded helper" "$3"
}

test_a_pid_read_from_a_file_is_refused() {
  printf '%s\n' "$sig -TERM \"\$(cat \"\$home/state/x.pid\")\" 2>/dev/null || true" > "$TMP_ROOT/pidfile-inline.sh"
  expect_form pidfile-inline "a pid read from a file" "a pid file read inside the signal"
  cat > "$TMP_ROOT/pidfile-var.sh" <<EOF
stop_server() {
  local pid
  pid=\$(sed -n '1p' "\$home/server.pid")
  $sig "\$pid"
}
EOF
  expect_form pidfile-var "a pid read from a file" "a pid file read into a variable"
  cat > "$TMP_ROOT/pidfile-read.sh" <<EOF
while read -r pid; do $sig "\$pid"; done < "\$TMP_ROOT/pids"
EOF
  expect_form pidfile-read "a pid read from a file" "pids read from a file in a loop"
  cat > "$TMP_ROOT/pidfile-trap.sh" <<EOF
trap '$sig "\$(cat "\$home/lock/pid")" 2>/dev/null || true' EXIT
EOF
  expect_form pidfile-trap "a pid read from a file" "a pid file read inside a trap string"
  pass "a signal to a pid read from a file is refused, inline, through a variable, a loop or a trap"
}

test_a_process_group_is_refused() {
  printf '%s\n' "$sig -TERM -- \"-\$pgid\" 2>/dev/null || true" > "$TMP_ROOT/group-dashdash.sh"
  expect_form group-dashdash "a process group" "a group after --"
  printf '%s\n' "$sig -KILL -\"\$leader\"" > "$TMP_ROOT/group-dash.sh"
  expect_form group-dash "a process group" "a negative pid after the signal name"
  printf '%s\n' "case \"\$x\" in *) $sig -KILL -- \"-\$WORKER_PGID\" ;; esac" > "$TMP_ROOT/group-case.sh"
  expect_form group-case "a process group" "a group signal in a case arm"
  cat > "$TMP_ROOT/group-perl.sh" <<EOF
perl -e '
  $sig "KILL", -\$runner if \$runner;
'
EOF
  expect_form group-perl "a process group" "a Perl group signal"
  printf '%s\n' "    os.${sig}pg(process.pid, signal.SIGTERM)" > "$TMP_ROOT/group-python.sh"
  expect_form group-python "a process group" "a Python group signal"
  printf '%s\n' "process.$sig(-child.pid, \"SIGTERM\");" > "$TMP_ROOT/group-node.sh"
  expect_form group-node "a process group" "a Node group signal"
  pass "a signal to a process group is refused in shell, Perl, Python and Node"
}

test_a_process_found_by_name_or_command_line_is_refused() {
  printf '%s\n' "p$sig -P \"\$holder\" 2>/dev/null || true" > "$TMP_ROOT/name-p.sh"
  expect_form name-p "a process found by name or pattern" "the p- signal command"
  printf '%s\n' "${sig}all sleep" > "$TMP_ROOT/name-all.sh"
  expect_form name-all "a process found by name or pattern" "the -all signal command"
  printf '%s\n' "pgrep -f fixture | xargs $sig" > "$TMP_ROOT/name-xargs.sh"
  expect_form name-xargs "a process found by name or pattern" "a signal through xargs"
  printf '%s\n' "for pid in \$(pgrep -f \"\$TMP_ROOT/srv\"); do $sig \"\$pid\"; done" > "$TMP_ROOT/name-pgrep.sh"
  expect_form name-pgrep "a process found by name or pattern" "pids from pgrep"
  printf '%s\n' "pid=\$(ps -eo pid=,args= | awk '/worker/ {print \$1}')" "$sig -STOP \"\$pid\"" > "$TMP_ROOT/cmdline.sh"
  expect_form cmdline "a process found by its command line" "a pid matched by command line"
  printf '%s\n' "$sig -TERM \"\$(ps -o ppid= -p \$\$)\"" > "$TMP_ROOT/ancestry.sh"
  expect_form ancestry "a process found through the process tree" "the parent of the test"
  pass "a signal to a process found by name, command line or the process tree is refused"
}

test_a_pid_from_another_commands_output_is_refused() {
  cat > "$TMP_ROOT/subst.sh" <<EOF
start_holder() { sleep 300 & echo "\$!"; }
holder=\$(start_holder)
$sig "\$holder" 2>/dev/null || true
EOF
  expect_form subst "a pid taken from another command's output" "a pid printed by a function in a subshell"
  cat > "$TMP_ROOT/bash-c.sh" <<EOF
bash -c '$sig -TERM "\$(cat "\$1")"' _ "\$pidfile"
EOF
  expect_form bash-c "a pid read from a file" "a pid file read inside a bash -c string"
  pass "a signal to a pid taken from another command's output is refused"
}

test_own_children_probes_data_and_the_helper_pass() {
  cat > "$TMP_ROOT/clean.sh" <<EOF
sleep 300 &
pid=\$!
$sig -TERM "\$pid" 2>/dev/null || true
$sig -0 "\$(cat "\$home/x.pid")" 2>/dev/null
$sig -s 0 -- "-\$pgid" 2>/dev/null
try { process.$sig(-child.pid, 0); } catch (error) { }
os.${sig}pg(leader, 0)
$sig -KILL "\$\$"
matrix_case D19 deny "p$sig -f '/bin/fm-watch.sh'"
"\$CHECK" --command "echo 'p$sig -f fm-watch'"
fm_test_signal TERM --identity "\$(cat "\$home/x.pid")"
verdict=\$("\$SIGNAL_CHECK" "\$\$" "" cleanup "\$1")
$sig -KILL "\${verdict#accepted }"
pass "$sig must stay best-effort"
EOF
  expect_clean clean "an own \$!, probes, the test's own \$\$, data strings, and the guarded helper"
  pass "own children, signal-0 probes, data strings and the guarded helper pass"
}

test_the_test_tree_passes() {
  local out rc=0
  out=$(bash "$CHECK" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a test signals a computed target outside the guarded helper: $out"
  assert_contains "$out" "ok - no test in" "the check over the test directories did not report what it checked"
  pass "no test in the test directories signals a computed target outside the guarded helper"
}

fm_test_run \
  test_a_stand_in_that_signals_its_parent_is_refused \
  test_a_stand_in_that_signals_a_grandparent_on_another_line_is_refused \
  test_the_removed_crash_shim_is_refused \
  test_verifying_recording_probing_and_self_signals_pass \
  test_a_pid_read_from_a_file_is_refused \
  test_a_process_group_is_refused \
  test_a_process_found_by_name_or_command_line_is_refused \
  test_a_pid_from_another_commands_output_is_refused \
  test_own_children_probes_data_and_the_helper_pass \
  test_the_test_tree_passes
