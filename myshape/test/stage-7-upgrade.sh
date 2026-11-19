#!/usr/bin/env bash
# Boards that are running when a change lands, board-only (AT5 of the
# board-interface test plan). Two steps, each from its own pinned base:
#
# The rename to myshape (AT5.1, AT5.2 and AT5.6, in the form the rename
# plan's rollout step 1 gives). One board-only root moves forward by commits:
# first the base's board files under their old names, whose service makes the
# data and is left running with a message in flight; then this working tree's
# board files committed on top. The test plays Firstmate's part with three
# plain mv lines, the old names to the new ones. Before them every subcommand
# of the new command refuses with exit 69 naming the move, ahead of the token
# guard, and writes nothing; after them the next command replaces the old
# service and finds every record the old code made.
#
# The feed and action contracts, B1 to B2 (AT5.1, AT5.3 and AT5.6): the B1
# board, given stand-ins for the Firstmate programs it ran, settles a relay,
# an answer and a tag, and is left with a note waiting for a retry and a
# direct message under way; then this working tree's board files and a stub
# aggregator under bin/fm-board.sh are committed on top. The next command
# replaces the service; the note reaches the stub once under its old write
# id, the direct message is marked uncertain and not sent again, and the
# settled writes stay in the history.
#
# Each base is pinned to carry's commit before its change, not computed as a
# merge base: once the change is merged, the merge base is the change itself
# and the step would test nothing. In both steps the new side runs with a stub
# aggregator, since the new board hands writes only to bin/fm-board.sh.
# shellcheck disable=SC2016 # jq filters are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"
# shellcheck source=myshape/test/standalone-lib.sh
. "$ROOT/myshape/test/standalone-lib.sh"
# shellcheck source=myshape/test/signal-lib.sh
. "$ROOT/myshape/test/signal-lib.sh"

BASE=5324261c
BASE_B2=990ffb88
# The board's files at the base, under the names they had before the rename.
BASE_BOARD_FILES="bin/fm-topic.sh bin/fm-topic-lib.sh topic-board/dist topic-board/public topic-board/package.json"
for tool in jq node curl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
for rev in "$BASE" "$BASE_B2"; do
  git -C "$ROOT" cat-file -e "$rev^{commit}" 2>/dev/null || { echo "not ok - base $rev is not in this checkout" >&2; exit 1; }
done
TMP_ROOT=$(fm_test_tmproot tb-s7u)
case "$TMP_ROOT" in /*) ;; *) echo "not ok - no scratch root" >&2; exit 1 ;; esac
trap 'tb_stop_boards; sig_leftovers; fm_test_cleanup' EXIT
sig_init

sa_init
mkdir -p "$TMP_ROOT/root"
SA_ROOT=$TMP_ROOT/root/board
tb_make_board_root "$SA_ROOT" "$BASE" "$BASE_BOARD_FILES" >/dev/null
# The old code's own note program, the one stand-in this step gives it. It
# exits as $TMP_ROOT/inbox-exit says and logs each call.
INBOX_LOG=$TMP_ROOT/inbox.log
printf '3\n' > "$TMP_ROOT/inbox-exit"
cat > "$SA_ROOT/bin/fm-inbox.sh" <<SH
#!/bin/sh
code=\$(cat "$TMP_ROOT/inbox-exit")
cat >/dev/null
printf '%s %s\n' "\$code" "\$*" >> "$INBOX_LOG"
exit "\$code"
SH
chmod +x "$SA_ROOT/bin/fm-inbox.sh"
tb_commit_root "$SA_ROOT" "the old note program's stand-in" >/dev/null
SA_ENV=(MYSHAPE_TEST=1 MYSHAPE_RETRY_MS=600000 MYSHAPE_READ_MS=300)
MAIN=$(sa_home main)
# The old code reads its port under the old name: both names hold the same
# free port, so neither side ever falls back to the live board's.
cp "$MAIN/config/myshape-port" "$MAIN/config/topic-board-port"
sa_decoys "$MAIN"

# old <op...>: the base's own command, under its old name and old timing
# variables, against the same root, home and port.
old() {
  env -i HOME="$TMP_ROOT/h" PATH="$SA_PATH" LANG=C.UTF-8 TMPDIR="$SA_TMPDIR" FM_HOME="$MAIN" \
    FM_TOPIC_BOARD_TEST=1 FM_TOPIC_BOARD_RETRY_MS=600000 FM_TOPIC_BOARD_LOCAL_MS=300 \
    "$SA_ROOT/bin/fm-topic.sh" "$@"
}

# The runtime directory of whichever side runs now: the old name until the move.
RUNTIME=$MAIN/state/topic-board

api() {  # <route> <json body>
  local base
  base="http://127.0.0.1:$(cat "$MAIN/config/myshape-port")"
  curl -s -m 20 -H "Authorization: Bearer $(cat "$RUNTIME/token")" -H "Origin: $base" \
    -H 'Content-Type: application/json' -d "$2" "$base/api/$1"
}

api_state() {  # [jq arguments...] <jq filter>
  curl -s -m 20 -H "Authorization: Bearer $(cat "$RUNTIME/token")" \
    "http://127.0.0.1:$(cat "$MAIN/config/myshape-port")/api/state" | jq -c -r "$@"
}

wait_for() {  # <description> <command...>: retry the command for up to 15 seconds
  local what=$1 tries=0
  shift
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "timed out waiting for $what"
    sleep 0.15
  done
}

write_is() {  # <write-id> <state>
  [ "$(api_state --arg id "$1" '.writes[] | select(.id == $id) | .state')" = "$2" ]
}

# What the old code made, kept to compare after the upgrade.
snapshot_data() {
  jq -S '{queues, topics, merged, history}' "$MAIN/data/topics.json"
  jq -S '.topics' "$MAIN/data/topics-archive.json"
}

OLD_PID=""
NEW_COMMIT=""
WRITE_ID=""
REQUEST_ID=""
SNAPSHOT=""

test_the_old_board_makes_its_data() {
  local out
  old open >/dev/null || fail "the old board did not start"
  old create "Old A" --goal "a" --id old-a >/dev/null || fail "the old board did not create a topic"
  old create "Old B" --goal "b" --id old-b >/dev/null
  old create "Old C" --goal "c" --id old-c --queue later >/dev/null
  old move old-b normal --first >/dev/null
  old archive old-c >/dev/null
  old create "Old D" --goal "d" --id old-d >/dev/null
  old merge old-d old-a --reason "same thing" >/dev/null || fail "the old board did not merge"
  old close-propose old-b --reason "looks done" >/dev/null
  out=$(printf '做到一半。\n' | old summary t1 report -) || fail "the old board did not store a summary: $out"
  WRITE_ID=$(api messages '{"topic":"old-a","text":"還在路上"}' | jq -r '.write_id')
  [ -n "$WRITE_ID" ] && [ "$WRITE_ID" != null ] || fail "the old page did not take the message"
  wait_for "the old note to wait for a retry" write_is "$WRITE_ID" retrying
  REQUEST_ID=$(grep "\"write_id\":\"$WRITE_ID\"" "$RUNTIME/audit.jsonl" | head -n 1 | jq -r '.sending.plan.requestId')
  [[ "$REQUEST_ID" =~ ^tb-[0-9a-f]{16}$ ]] || fail "the old note must carry a request id: $REQUEST_ID"
  assert_grep "3 note --request-id $REQUEST_ID -" "$INBOX_LOG" "the old board must have tried the note once"
  OLD_PID=$(tb_board_pid_in "$RUNTIME")
  SNAPSHOT=$(snapshot_data)
  cp "$MAIN/data/topic-board/events.jsonl" "$TMP_ROOT/events.before"
  cp "$MAIN/data/topic-board/summaries.jsonl" "$TMP_ROOT/summaries.before"
  pass "the old board made topics, history, a summary, and a message left in flight"
}

# tb_board_pid_in <runtime-dir>: the pid a board recorded in that directory.
tb_board_pid_in() {
  cat "$1/pid" 2>/dev/null || true
}

test_the_new_code_refuses_until_the_move() {
  local path new_commit sub rc out
  for path in $BASE_BOARD_FILES; do
    rm -rf "${SA_ROOT:?}/$path"
  done
  rmdir "$SA_ROOT/topic-board"
  for path in $TB_BOARD_FILES; do
    mkdir -p "$SA_ROOT/$(dirname "$path")"
    cp -R "$ROOT/$path" "$SA_ROOT/$path"
  done
  sa_trip_root "$SA_ROOT"
  sa_install_stub plain "$TMP_ROOT/agg"
  printf '{}\n' > "$TMP_ROOT/agg/plain/main.json"
  new_commit=$ROOT_COMMIT
  NEW_COMMIT=$new_commit
  printf '0\n' > "$TMP_ROOT/inbox-exit"
  ps -p "$OLD_PID" >/dev/null 2>&1 || fail "the old board must still be running when the change lands"
  for sub in open list status stop restart reset-token create find which todo summary merge move; do
    rc=0
    out=$(sa "$MAIN" "$sub" 2>&1 </dev/null) || rc=$?
    assert_equals 69 "$rc" "$sub must refuse with 69 before the move"
    assert_equals "看板服務無法啟動：這個 home 還有改名前的 $MAIN/state/topic-board。先跑 bin/fm-board.sh migrate-myshape 搬到新名字。這次的要求沒有寫入。" \
      "$out" "$sub must name the move, ahead of the token guard"
  done
  assert_absent "$MAIN/state/myshape" "a refused command must write nothing"
  assert_absent "$MAIN/data/myshape" "a refused command must write nothing"
  ps -p "$OLD_PID" >/dev/null 2>&1 || fail "a refused command must leave the old board alone"
  pass "before the move every subcommand of the new command refuses with 69, names the move, and writes nothing"
}

test_the_next_command_after_the_move_replaces_the_board() {
  local events_before summaries_before
  # Firstmate's part, played here with plain mv lines.
  mv "$MAIN/state/topic-board" "$MAIN/state/myshape"
  mv "$MAIN/data/topic-board" "$MAIN/data/myshape"
  mv "$MAIN/config/topic-board-port" "$MAIN/config/myshape-port"
  RUNTIME=$MAIN/state/myshape

  sa "$MAIN" open >/dev/null || fail "the next command after the move failed"
  assert_equals 1 "$(tb_board_count "$MAIN")" "exactly one service must serve the home"
  assert_not_equals "$OLD_PID" "$(tb_board_pid "$MAIN")" "the next command must replace the old service"
  ps -p "$OLD_PID" >/dev/null 2>&1 && fail "the old service must be gone"
  assert_absent "$MAIN/state/topic-board" "the old service must not bring its old directory back"
  assert_absent "$MAIN/data/topic-board" "the old service must not bring its old data directory back"
  assert_contains "$(sa "$MAIN" status)" "程式版本：$NEW_COMMIT" "status must name the new commit"
  assert_equals "$SNAPSHOT" "$(snapshot_data)" "topics, queue order, archive and history must be intact"
  events_before=$(wc -c < "$TMP_ROOT/events.before" | tr -d ' ')
  summaries_before=$(wc -c < "$TMP_ROOT/summaries.before" | tr -d ' ')
  cmp -s "$TMP_ROOT/events.before" <(head -c "$events_before" "$MAIN/data/myshape/events.jsonl") ||
    fail "the old events must be kept as they were"
  cmp -s "$TMP_ROOT/summaries.before" <(head -c "$summaries_before" "$MAIN/data/myshape/summaries.jsonl") ||
    fail "the old summaries must be kept as they were"
  assert_equals "old-b old-a" "$(sa "$MAIN" list --json | jq -r '[.[] | select(.queue == "normal") | .id] | join(" ")')" \
    "the new command must read the old queue order"
  assert_contains "$(sa "$MAIN" find old-d)" "「Old D」（old-d）併入「Old A」（用指令；原因：same thing）" \
    "the new code must read the old history"
  pass "after the move the next command replaces the running board, and every record the old code made is intact"
}

test_the_note_in_flight_arrives_once() {
  wait_for "the note to be delivered" write_is "$WRITE_ID" delivered
  assert_equals "$WRITE_ID|message|$REQUEST_ID|old-a|還在路上" \
    "$(jq -r -s 'map("\(.id)|\(.kind)|\(.legacy_request_id)|\(.topic.id)|\(.text)") | join(" ")' "$TMP_ROOT/agg/received.jsonl")" \
    "the new code must hand the old note over once, as a message under its write id and request id"
  sleep 1
  assert_equals 1 "$(grep -c '' "$TMP_ROOT/agg/received.jsonl")" "the note must not be sent again"
  assert_equals 1 "$(grep -c '' "$INBOX_LOG")" "the old note program must not run again"
  assert_equals 1 "$(api_state --arg id "$WRITE_ID" '[.writes[] | select(.id == $id)] | length')" \
    "the write history must still list the old write"
  pass "the message left in flight is handed over once by the new code, under the same write and request id"
}

test_the_new_side_reaches_no_firstmate_file() {
  sa "$MAIN" stop >/dev/null
  sa_check_decoys "$MAIN"
  sa_assert_no_boards
  sa_assert_no_trips
  pass "the upgraded board ran in the hardened environment and reached no Firstmate file"
}

# --- B1 to B2 -------------------------------------------------------------------

# b2_standins <root> <dir>: the Firstmate programs the B1 board ran, as
# stand-ins that log each call to <dir>/calls.log. The reader prints
# <dir>/report-<home>.json; the note program exits as <dir>/inbox-exit says;
# the send program sleeps <dir>/send-sleep seconds first; the answer program
# and fm-on.sh's answers close the hold; fm-board.sh tag succeeds.
b2_standins() {
  local root=$1 dir=$2 name
  cat > "$root/bin/b2-standin" <<SH
#!/bin/sh
name=\$(basename "\$0")
input=\$(cat)
printf '%s %s\n' "\$name" "\$*" >> "$dir/calls.log"
[ "\$1" != --stdin ] || shift
case "\$name" in
  fm-topic-board-read.sh)
    if [ "\$1" = --in-home ]; then cat "$dir/report-\$2.json"; else cat "$dir/report-main.json"; fi ;;
  fm-on.sh)
    case "\$2" in
      fm-topic-board-read.sh) cat "$dir/report-\$1.json" ;;
      fm-captain-hold.sh) printf 'closed: %s\n' "\${input%%	*}" ;;
    esac ;;
  fm-inbox.sh) exit "\$(cat "$dir/inbox-exit")" ;;
  fm-send.sh) sleep "\$(cat "$dir/send-sleep")" ;;
  fm-captain-hold.sh) printf 'closed: %s\n' "\${input%%	*}" ;;
esac
exit 0
SH
  chmod +x "$root/bin/b2-standin"
  for name in fm-topic-board-read.sh fm-on.sh fm-inbox.sh fm-send.sh fm-captain-hold.sh fm-board.sh; do
    ln -s b2-standin "$root/bin/$name"
  done
  jq -n '{schema: 1, code_commit: "b1", ledger_enabled: true,
    tasks: [{id: "ship-a", kind: "ship", state: "working", source: "pane", detail: ""}],
    queued: [], status_decisions: [], topics: {},
    holds: [{id: "call-1", title: "T", question: "要合併嗎？", hold_bucket: "live", hold_until: null,
      unresolved_blocker_ids: [], hold_age_days: 0, origin: "", on_answer: "close"}],
    ledger: {status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: []},
    secondmates: [{id: "far1", remote: true, home: "/srv/far1"}]}' > "$dir/report-main.json"
  jq -n '{schema: 1, code_commit: "b1", ledger_enabled: true,
    tasks: [{id: "far-work", kind: "ship", state: "working", source: "pane", detail: ""}],
    queued: [], holds: [], status_decisions: [], topics: {},
    ledger: {status: "absent", to_offset: 0, to_prefix_sha256: "-", more: false, lines: []}}' > "$dir/report-far1.json"
  printf '0\n' > "$dir/inbox-exit"
  printf '0\n' > "$dir/send-sleep"
}

B2_DIR=""
B2_MESSAGE=""
B2_REQUEST=""
B2_SEND=""
B2_SETTLED=""
B2_OLD_PID=""

test_b2_the_b1_board_leaves_writes_settled_and_in_flight() {
  local code answer tag relay
  B2_DIR=$TMP_ROOT/b2
  mkdir -p "$B2_DIR"
  SA_ROOT=$TMP_ROOT/root/b2-board
  tb_make_board_root "$SA_ROOT" "$BASE_B2" >/dev/null
  b2_standins "$SA_ROOT" "$B2_DIR"
  tb_commit_root "$SA_ROOT" "stand-ins for the programs B1 runs" >/dev/null
  SA_ENV=(MYSHAPE_TEST=1 MYSHAPE_RETRY_MS=600000 MYSHAPE_LOCAL_MS=300 MYSHAPE_READ_MS=300)
  MAIN=$(sa_home b2-main)
  RUNTIME=$MAIN/state/myshape
  sa_decoys "$MAIN"
  sa "$MAIN" open >/dev/null || fail "the B1 board did not start"
  sa "$MAIN" create "Old A" --goal "a" --id old-a >/dev/null
  sa "$MAIN" create "Old B" --goal "b" --id old-b >/dev/null
  sa "$MAIN" move old-b normal --first >/dev/null
  api refresh '{}' >/dev/null
  sleep 1
  code=$(api holds/answer '{"home":"main","task":"call-1","answer":"合併","label":"合併"}' | jq -r '.confirm')
  answer=$(api holds/answer "{\"home\":\"main\",\"task\":\"call-1\",\"answer\":\"合併\",\"label\":\"合併\",\"confirm\":\"$code\"}" | jq -r '.write_id')
  tag=$(api agents/tag '{"home":"main","task":"ship-a","topic":"old-a"}' | jq -r '.write_id')
  relay=$(api direct '{"home":"far1","task":"far-work","text":"轉過去"}' | jq -r '.write_id')
  wait_for "the answer to settle" write_is "$answer" delivered
  wait_for "the tag to settle" write_is "$tag" delivered
  wait_for "the relay to settle" write_is "$relay" delivered
  B2_SETTLED="$answer $tag $relay"
  printf '3\n' > "$B2_DIR/inbox-exit"
  B2_MESSAGE=$(api messages '{"topic":"old-a","text":"還在路上"}' | jq -r '.write_id')
  wait_for "the note to wait for a retry" write_is "$B2_MESSAGE" retrying
  B2_REQUEST=$(grep "\"write_id\":\"$B2_MESSAGE\"" "$RUNTIME/audit.jsonl" | head -n 1 | jq -r '.sending.plan.requestId')
  [[ "$B2_REQUEST" =~ ^tb-[0-9a-f]{16}$ ]] || fail "the B1 note must carry a request id: $B2_REQUEST"
  printf '6\n' > "$B2_DIR/send-sleep"
  B2_SEND=$(api direct '{"home":"main","task":"ship-a","text":"看一下"}' | jq -r '.write_id')
  wait_for "the direct message to be under way" grep -q '^fm-send.sh ship-a 看一下$' "$B2_DIR/calls.log"
  B2_OLD_PID=$(tb_board_pid "$MAIN")
  SNAPSHOT=$(snapshot_data)
  cp "$MAIN/data/myshape/events.jsonl" "$TMP_ROOT/b2-events.before"
  pass "the B1 board settled an answer, a tag and a relay, and left a note and a direct message unfinished"
}

test_b2_the_next_command_replaces_the_board() {
  local path events_before
  for path in $TB_BOARD_FILES; do
    rm -rf "${SA_ROOT:?}/$path"
    mkdir -p "$SA_ROOT/$(dirname "$path")"
    cp -R "$ROOT/$path" "$SA_ROOT/$path"
  done
  find "$SA_ROOT/bin" -name 'fm-*.sh' -type l -delete
  rm -f "$SA_ROOT/bin/b2-standin"
  sa_trip_root "$SA_ROOT"
  sa_install_stub plain "$B2_DIR/agg"
  printf '{}\n' > "$B2_DIR/agg/plain/main.json"
  ps -p "$B2_OLD_PID" >/dev/null 2>&1 || fail "the B1 board must still be running when B2 lands"
  sa "$MAIN" open >/dev/null || fail "the next command after B2 landed failed"
  assert_equals 1 "$(tb_board_count "$MAIN")" "exactly one service must serve the home"
  assert_not_equals "$B2_OLD_PID" "$(tb_board_pid "$MAIN")" "the next command must replace the B1 service"
  assert_contains "$(sa "$MAIN" status)" "程式版本：$ROOT_COMMIT" "status must name the new commit"
  assert_equals "$SNAPSHOT" "$(snapshot_data)" "topics, queue order, archive and history must be intact"
  events_before=$(wc -c < "$TMP_ROOT/b2-events.before" | tr -d ' ')
  cmp -s "$TMP_ROOT/b2-events.before" <(head -c "$events_before" "$MAIN/data/myshape/events.jsonl") ||
    fail "the B1 events must be kept as they were"
  pass "after B2 lands the next command replaces the running B1 board, and its records are intact"
}

test_b2_unfinished_writes_resume_or_show_once() {
  wait_for "the note to be delivered" write_is "$B2_MESSAGE" delivered
  sleep 1
  assert_equals "$B2_MESSAGE|message|$B2_REQUEST|old-a|Old A|還在路上" \
    "$(jq -r -s 'map("\(.id)|\(.kind)|\(.legacy_request_id)|\(.topic.id)|\(.topic.name)|\(.text)") | join(" ")' "$B2_DIR/agg/received.jsonl")" \
    "the note B1 left must reach the deliverer once, as a message under its write id and request id"
  assert_equals "unknown" "$(api_state --arg id "$B2_SEND" '.writes[] | select(.id == $id) | .state')" \
    "the direct message under way must become uncertain"
  assert_equals "answer:delivered direct:delivered tag:delivered" \
    "$(api_state --arg ids "$B2_SETTLED" '[.writes[] | select(.id as $id | $ids | split(" ") | index($id))] | map("\(.kind):\(.state)") | sort | join(" ")')" \
    "the settled relay, answer and tag must still show in the history, under the new kinds"
  pass "the unfinished note is handed over once, the unfinished direct message is not resent, and settled writes stay in the history"
}

test_b2_the_new_side_reaches_no_firstmate_file() {
  sa "$MAIN" stop >/dev/null
  sa_check_decoys "$MAIN"
  sa_assert_no_boards
  sa_assert_no_trips
  pass "the B2 board ran in the hardened environment and reached no Firstmate file"
}

fm_test_run test_the_old_board_makes_its_data test_the_new_code_refuses_until_the_move \
  test_the_next_command_after_the_move_replaces_the_board test_the_note_in_flight_arrives_once test_the_new_side_reaches_no_firstmate_file \
  test_b2_the_b1_board_leaves_writes_settled_and_in_flight test_b2_the_next_command_replaces_the_board \
  test_b2_unfinished_writes_resume_or_show_once test_b2_the_new_side_reaches_no_firstmate_file
