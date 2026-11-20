#!/usr/bin/env bash
# Behaviour tests for tests/check-signals.sh, the static check that no test
# picks a process to signal by parentage, and the check itself over tests/.
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

test_the_test_tree_passes() {
  local out rc=0
  out=$(bash "$CHECK" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a test picks a process to signal by parentage: $out"
  assert_contains "$out" "ok - no test in" "the check over tests/ did not report what it checked"
  pass "no test under tests/ picks a process to signal by parentage"
}

fm_test_run \
  test_a_stand_in_that_signals_its_parent_is_refused \
  test_a_stand_in_that_signals_a_grandparent_on_another_line_is_refused \
  test_the_removed_crash_shim_is_refused \
  test_verifying_recording_probing_and_self_signals_pass \
  test_the_test_tree_passes
