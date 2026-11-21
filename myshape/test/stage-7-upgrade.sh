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
# Hands-on items stored by the board, B2 to B3 (AT5.4): the B2 board, fed a
# 動手： hold by stub-plain, records the captain's 做完了 as a mark in
# topics.json and is left with a message waiting for a retry; then this
# working tree's board files are committed on top. The next command replaces
# the service; its first start writes data/myshape/todos.json with that mark
# waiting for adoption, topics.json still carries the mark for an older
# reader, and the message reaches the stub once more and is delivered.
#
# Every change saves its record, B3 to the record guarantee: the B3 board
# opens a topic and a hands-on item, records the captain's 做完了 and leaves a
# close proposal, all as lines with no record id and files with no outbox;
# then this working tree's board files are committed on top. The next command
# replaces the service; its first start finds no outbox and replays nothing,
# so events.jsonl is byte-identical; the next changes write records with ids
# and the commit files carry their outbox; the closed item lists the B3
# board's lines with the new close. Going back to B3 code, its board reads
# the new lines, shows them, and its next change drops the outbox.
#
# Decisions recorded from the feed, the record guarantee to decision records:
# the board at carry's commit before this change runs with a Firstmate-shaped
# stub whose report has no hold_set and no closed decisions, as an older
# reader prints it; then this working tree's board files are committed on top
# and the stub's report turns into one of a home full of past decisions: an
# open hold set long ago, answered and released ones, and one the page
# answered. The next command replaces the service; its first reads write no
# decision record and leave events.jsonl byte-identical, even when a past
# decision is reported again after it moved into the archive. Then a new hold
# writes one opening and its chat answer one close at the time the home gave;
# a stub that refuses the closed decisions' cursor, as an older reader would,
# is read again without it. Going back to the earlier code, its board shows
# the new lines as text and keeps changing the board.
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
BASE_B3=c5a54085
BASE_RECORDS=0c320a14
BASE_DECISIONS=18f63f43
# The board's files at the base, under the names they had before the rename.
BASE_BOARD_FILES="bin/fm-topic.sh bin/fm-topic-lib.sh topic-board/dist topic-board/public topic-board/package.json"
for tool in jq node curl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
for rev in "$BASE" "$BASE_B2" "$BASE_B3" "$BASE_RECORDS" "$BASE_DECISIONS"; do
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
  # Until now the old service kept reading through the programs it was built to
  # run, which are tripwires on the new side; only the new side is checked.
  : > "$SA_TRIP_LOG"
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
  sa "$MAIN" create "Old C" --goal "c" --id old-c --queue later >/dev/null
  sa "$MAIN" archive old-c >/dev/null
  sa "$MAIN" merge old-b old-a --reason "same thing" >/dev/null
  sa "$MAIN" create "Old B2" --goal "b" --id old-b2 >/dev/null
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
  : > "$SA_TRIP_LOG"
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

# --- B2 to B3 -------------------------------------------------------------------

B3_DIR=""
B3_MESSAGE=""
B3_OLD_PID=""

test_b3_the_b2_board_keeps_a_mark_and_a_message_in_flight() {
  B3_DIR=$TMP_ROOT/b3
  SA_ROOT=$TMP_ROOT/root/b3-board
  tb_make_board_root "$SA_ROOT" "$BASE_B3" >/dev/null
  SA_ENV=(MYSHAPE_TEST=1 MYSHAPE_RETRY_MS=600000 MYSHAPE_READ_MS=300)
  sa_install_stub plain "$B3_DIR/agg"
  jq -n '{holds: [{id: "h-todo", title: "Log in", question: "動手：登入 VPN", hold_bucket: "live", hold_until: null,
           unresolved_blocker_ids: [], hold_age_days: 0, origin: "", on_answer: "close"}],
          topics: {"h-todo": "old-a 2026-11-19T00:00:00Z"}}' > "$B3_DIR/agg/plain/main.json"
  MAIN=$(sa_home b3-main)
  RUNTIME=$MAIN/state/myshape
  sa_decoys "$MAIN"
  sa "$MAIN" open >/dev/null || fail "the B2 board did not start"
  sa "$MAIN" create "Old A" --goal "a" --id old-a >/dev/null
  api refresh '{}' >/dev/null
  wait_for "the B2 page to show the hands-on hold" is_handson
  [ "$(api todos/claim '{"task":"h-todo"}' | jq -r '.ok')" = true ] || fail "做完了 on the B2 page failed"
  assert_equals '"claimed"' "$(jq -c '.todos["h-todo"].state' "$MAIN/data/topics.json")" "the B2 board must keep the mark in topics.json"
  assert_absent "$MAIN/data/myshape/todos.json" "the B2 board has no store of its own"
  # The stub logs a record before it reads its next outcome, so the claim's
  # notice must be settled before the message's scripted retry is written.
  wait_for "the claim notice to be delivered" claim_delivered
  printf '%s\n' '{"outcome":"retry","error":"later"}' > "$B3_DIR/agg/play"
  B3_MESSAGE=$(api messages '{"topic":"old-a","text":"還在路上"}' | jq -r '.write_id')
  wait_for "the message to wait for a retry" write_is "$B3_MESSAGE" retrying
  B3_OLD_PID=$(tb_board_pid "$MAIN")
  pass "the B2 board recorded the captain's claim in topics.json and left a message waiting for a retry"
}

claim_delivered() {
  [ "$(api_state '[.writes[] | select(.kind == "notice" and .state == "delivered")] | length')" -ge 1 ]
}

is_handson() {
  [ "$(api_state '[.holds[] | select(.task == "h-todo" and .todo != null)] | length')" = 1 ]
}

test_b3_the_first_start_keeps_the_mark() {
  local path
  for path in $TB_BOARD_FILES; do
    rm -rf "${SA_ROOT:?}/$path"
    mkdir -p "$SA_ROOT/$(dirname "$path")"
    cp -R "$ROOT/$path" "$SA_ROOT/$path"
  done
  sa_install_stub plain "$B3_DIR/agg"
  printf '{}\n' > "$B3_DIR/agg/plain/main.json"
  sa_trip_root "$SA_ROOT"
  ps -p "$B3_OLD_PID" >/dev/null 2>&1 || fail "the B2 board must still be running when B3 lands"
  sa "$MAIN" open >/dev/null || fail "the next command after B3 landed failed"
  : > "$SA_TRIP_LOG"
  assert_not_equals "$B3_OLD_PID" "$(tb_board_pid "$MAIN")" "the next command must replace the B2 service"
  assert_contains "$(sa "$MAIN" status)" "程式版本：$ROOT_COMMIT" "status must name the new commit"
  assert_equals '{"h-todo":"claimed"}' "$(jq -c '.marks | map_values(.state)' "$MAIN/data/myshape/todos.json")" \
    "the first start must keep the mark, waiting for its item"
  assert_equals '{}' "$(jq -c '.items' "$MAIN/data/myshape/todos.json")" "no item is made from a mark alone"
  assert_equals '"claimed"' "$(jq -c '.todos["h-todo"].state' "$MAIN/data/topics.json")" \
    "topics.json must still carry the mark for an older reader"
  pass "the first start of B3 keeps the B2 board's marks in todos.json and in topics.json"
}

test_b3_the_message_in_flight_arrives_once() {
  wait_for "the message to be delivered" write_is "$B3_MESSAGE" delivered
  # Installing the stub on the new side started a fresh log, so it holds only what B3 sent.
  assert_equals 1 "$(jq -r -s --arg id "$B3_MESSAGE" '[.[] | select(.id == $id)] | length' "$B3_DIR/agg/received.jsonl")" \
    "the message must reach the stub once from B3"
  sa "$MAIN" restart >/dev/null
  sleep 1
  assert_equals 1 "$(jq -r -s --arg id "$B3_MESSAGE" '[.[] | select(.id == $id)] | length' "$B3_DIR/agg/received.jsonl")" \
    "a delivered message must not be sent again"
  sa "$MAIN" stop >/dev/null
  sa_check_decoys "$MAIN"
  sa_assert_no_boards
  sa_assert_no_trips
  pass "the message in flight across B2 to B3 is delivered once, and the new side reaches no Firstmate file"
}

# --- B3 to the record guarantee ---------------------------------------------------

R_DIR=""
R_OLD_PID=""

# install_board_files <revision or empty for this tree> [stub] [agg-dir]: the
# board's files in SA_ROOT, with the stub aggregator (plain in R_DIR/agg unless
# named), committed.
install_board_files() {
  local path stub=${2:-plain} agg=${3:-$R_DIR/agg}
  for path in $TB_BOARD_FILES; do
    rm -rf "${SA_ROOT:?}/$path"
    mkdir -p "$SA_ROOT/$(dirname "$path")"
    if [ -z "$1" ]; then
      cp -R "$ROOT/$path" "$SA_ROOT/$path"
    else
      # shellcheck disable=SC2086 # one path, which may be a directory.
      git -C "$ROOT" archive "$1" $path | tar -x -C "$SA_ROOT"
    fi
  done
  sa_install_stub "$stub" "$agg"
  [ -f "$agg/plain/main.json" ] || printf '{}\n' > "$agg/plain/main.json"
  sa_trip_root "$SA_ROOT"
}

test_r_the_b3_board_leaves_lines_without_ids() {
  R_DIR=$TMP_ROOT/records
  SA_ROOT=$TMP_ROOT/root/records-board
  tb_make_board_root "$SA_ROOT" "$BASE_RECORDS" >/dev/null
  SA_ENV=(MYSHAPE_TEST=1 MYSHAPE_READ_MS=300)
  sa_install_stub plain "$R_DIR/agg"
  printf '{}\n' > "$R_DIR/agg/plain/main.json"
  MAIN=$(sa_home records-main)
  RUNTIME=$MAIN/state/myshape
  sa_decoys "$MAIN"
  sa "$MAIN" open >/dev/null || fail "the B3 board did not start"
  sa "$MAIN" create "Rec A" --goal "a" --id rec-a >/dev/null
  sa "$MAIN" todo add it1 "Log in" --topic rec-a --do "log in" >/dev/null
  [ "$(api todos/claim '{"task":"it1"}' | jq -r '.ok')" = true ] || fail "做完了 on the B3 page failed"
  sa "$MAIN" close-propose rec-a --reason "done" >/dev/null
  assert_equals 4 "$(grep -c '"src":"board"' "$MAIN/data/myshape/events.jsonl")" "the B3 board must write one line per step"
  assert_equals 0 "$(grep -c '"rid"' "$MAIN/data/myshape/events.jsonl" || true)" "B3 lines carry no record id"
  assert_equals "false false" "$(jq 'has("outbox")' "$MAIN/data/topics.json") $(jq 'has("outbox")' "$MAIN/data/myshape/todos.json")" \
    "B3 files carry no outbox"
  cp "$MAIN/data/myshape/events.jsonl" "$TMP_ROOT/records-events.before"
  R_OLD_PID=$(tb_board_pid "$MAIN")
  pass "the B3 board writes its lines without record ids and its files without an outbox"
}

test_r_the_first_start_replays_nothing() {
  install_board_files ""
  ps -p "$R_OLD_PID" >/dev/null 2>&1 || fail "the B3 board must still be running when the change lands"
  sa "$MAIN" open >/dev/null || fail "the next command after the change landed failed"
  : > "$SA_TRIP_LOG"
  assert_not_equals "$R_OLD_PID" "$(tb_board_pid "$MAIN")" "the next command must replace the B3 service"
  assert_contains "$(sa "$MAIN" status)" "程式版本：$ROOT_COMMIT" "status must name the new commit"
  cmp -s "$TMP_ROOT/records-events.before" "$MAIN/data/myshape/events.jsonl" ||
    fail "the first start must find no outbox and replay nothing"
  assert_equals "false" "$(jq 'has("outbox")' "$MAIN/data/topics.json")" "a start alone must not rewrite topics.json"
  pass "the first start of the new code on B3 files replays nothing and rewrites nothing"
}

test_r_changes_now_save_their_records() {
  local kept done_rid
  [ "$(api topics/keep '{"id":"rec-a"}' | jq -r '.ok')" = true ] || fail "先不關 on the page failed"
  kept=$(grep '"kind":"topic.kept"' "$MAIN/data/myshape/events.jsonl" | jq -r '"\(.rid) \(.by) \(.text)"')
  assert_contains "$kept" " captain 議題「Rec A」先不關（你在頁面上）" "先不關 must save a record by the captain"
  assert_equals "${kept%% *}" "$(jq -r '.outbox[0].rid' "$MAIN/data/topics.json")" "topics.json must carry the record in its outbox"
  sa "$MAIN" todo "done" it1 >/dev/null || fail "todo done failed"
  done_rid=$(grep '"kind":"todo.done"' "$MAIN/data/myshape/events.jsonl" | jq -r '.rid')
  assert_equals "$done_rid" "$(jq -r '.outbox[0].rid' "$MAIN/data/myshape/todos.json")" "todos.json must carry the close in its outbox"
  assert_equals "todo.done todo.claimed todo.opened" \
    "$(api_state '.closed_todos[] | select(.item == "it1") | .records | map(.event) | join(" ")')" \
    "the closed item must list the B3 board's lines with the new close"
  pass "after the upgrade every change saves a record with an id, and old lines still show in the item's history"
}

test_r_going_back_drops_only_the_outbox() {
  local pid
  pid=$(tb_board_pid "$MAIN")
  install_board_files "$BASE_RECORDS"
  sa "$MAIN" open >/dev/null || fail "the next command after going back failed"
  : > "$SA_TRIP_LOG"
  assert_not_equals "$pid" "$(tb_board_pid "$MAIN")" "the next command must replace the new service with the B3 one"
  assert_contains "$(api_state '[.updates[].text] | join("\n")')" "議題「Rec A」先不關（你在頁面上）" \
    "the B3 board must show the new records as text"
  sa "$MAIN" goal rec-a "a2" >/dev/null || fail "a change on the B3 board after going back failed"
  assert_equals "false" "$(jq 'has("outbox")' "$MAIN/data/topics.json")" "the B3 board's next change drops the outbox"
  assert_equals 1 "$(grep -c '"kind":"topic.kept"' "$MAIN/data/myshape/events.jsonl")" "the saved records stay, once"
  sa "$MAIN" stop >/dev/null
  sa_check_decoys "$MAIN"
  sa_assert_no_boards
  sa_assert_no_trips
  pass "going back to B3 code keeps every record and drops only the outbox"
}

# --- the record guarantee to decision records ------------------------------------

D_DIR=""
D_OLD_PID=""

# d_report <jq filter>: the stub's main report, an edit of the one before.
d_report() {
  local file=$D_DIR/agg/fm/main.json
  jq "$1" "$file" > "$file.next" && mv "$file.next" "$file"
}

# d_board_lines: the board's own lines in events.jsonl.
d_board_lines() {
  grep -c '"src":"board"' "$MAIN/data/myshape/events.jsonl" || true
}

# d_last_feed: the arguments of the stub's last feed call, without its time.
d_last_feed() {
  awk '$1 == "feed" && $2 == "main" { line = $0 } END { print line }' "$D_DIR/agg/calls.log" | sed 's/ [0-9.]*$//'
}

# d_read: one read of every home, as the page's refresh asks for.
d_read() {
  [ "$(api refresh '{}' | jq -r '.ok')" = true ] || fail "a refresh failed"
}

test_d_the_earlier_board_runs_with_an_older_reader() {
  D_DIR=$TMP_ROOT/decisions
  SA_ROOT=$TMP_ROOT/root/decisions-board
  tb_make_board_root "$SA_ROOT" "$BASE_DECISIONS" >/dev/null
  SA_ENV=(MYSHAPE_TEST=1 MYSHAPE_READ_MS=600000)
  sa_install_stub fm "$D_DIR/agg"
  MAIN=$(sa_home decisions-main)
  RUNTIME=$MAIN/state/myshape
  sa_decoys "$MAIN"
  jq -n '{schema: 1, code_commit: "older-reader", ledger_enabled: false, tasks: [], queued: [],
    holds: [{id: "old-open", title: "舊的", question: "還沒答的舊問題", hold_bucket: "live", hold_until: null,
      unresolved_blocker_ids: [], hold_age_days: 30, origin: "", on_answer: "close"}],
    status_decisions: [], topics: {"old-open": "nas 2026-10-01T00:00:00Z", "new-1": "nas 2026-11-20T00:00:00Z"},
    aggregator: {name: "firstmate", label: "first mate"}}' > "$D_DIR/agg/fm/main.json"
  sa "$MAIN" open >/dev/null || fail "the earlier board did not start"
  sa "$MAIN" create "NAS" --goal "n" --id nas >/dev/null
  d_read
  assert_equals 'feed main 0 -' "$(d_last_feed)" "the earlier board reads with the ledger cursor only"
  cp "$MAIN/data/myshape/events.jsonl" "$TMP_ROOT/decisions-events.before"
  D_OLD_PID=$(tb_board_pid "$MAIN")
  pass "the earlier board runs on a report with no hold times and no closed decisions"
}

test_d_the_first_reads_record_no_past_decision() {
  install_board_files "" fm "$D_DIR/agg"
  d_report '.code_commit = "newer-reader"
    | .holds[0].hold_set = "2026-10-01T00:00:00Z"
    | .closed_holds = [
        {id: "past-1", title: "早就答了", origin: "", mode: "answered", answer: "要", label: "", source: "",
         digest: "d-past-1", occurrence: 1, opened_at: 1790000000, closed_at: 1790000600},
        {id: "past-2", title: "放行過的", origin: "", mode: "released", answer: "繼續", label: "", source: "",
         digest: "d-past-2", occurrence: 1, opened_at: null, closed_at: null},
        {id: "past-3", title: "在頁面答的", origin: "", mode: "answered", answer: "好", label: "好", source: "myshape",
         digest: "d-past-3", occurrence: 1, opened_at: 1790000000, closed_at: 1790000100}]
    | .closed_cursor = {status: "start", to_offset: 4096, to_prefix_sha256: "'"$(printf 'a%.0s' $(seq 64))"'", more: false}'
  ps -p "$D_OLD_PID" >/dev/null 2>&1 || fail "the earlier board must still be running when the change lands"
  sa "$MAIN" open >/dev/null || fail "the next command after the change landed failed"
  : > "$SA_TRIP_LOG"
  assert_not_equals "$D_OLD_PID" "$(tb_board_pid "$MAIN")" "the next command must replace the earlier service"
  d_read
  assert_equals 'feed main 0 -' "$(d_last_feed)" "the first read has no closed decisions' cursor to pass"
  # The home's past decisions are read again, one moved into the archive, the
  # released one's work finished: still nothing is new.
  d_report '.closed_cursor.status = "delta"'
  d_read
  d_read
  assert_equals "feed main 0 - 4096 $(printf 'a%.0s' $(seq 64))" "$(d_last_feed)" \
    "a later read passes the cursor the home reported"
  cmp -s "$TMP_ROOT/decisions-events.before" "$MAIN/data/myshape/events.jsonl" ||
    fail "the first reads of a home full of past decisions must write no record: $(tail -n 3 "$MAIN/data/myshape/events.jsonl")"
  assert_equals "newer-reader old-open	2026-10-01T00:00:00Z past-1	d-past-1" \
    "$(jq -r '.homes.main | "\(.code_commit) \(.open_seen[0]) \(.closed_seen[0])"' "$MAIN/data/myshape/decisions.json")" \
    "the board must remember what it saw, so later reads record only what is new"
  pass "the first reads after the upgrade record none of the home's past decisions"
}

test_d_new_decisions_open_and_close_once() {
  local before set_s
  before=$(d_board_lines)
  set_s=$(date -u -d 2026-11-20T06:10:00Z +%s 2>/dev/null || date -j -u -f %Y-%m-%dT%H:%M:%SZ 2026-11-20T06:10:00Z +%s)
  d_report '.holds += [{id: "new-1", title: "NAS 兩步驗證", question: "NAS 要不要開兩步驗證？\n選項：要 | 不要",
    hold_bucket: "live", hold_until: null, unresolved_blocker_ids: [], hold_age_days: 0, origin: "",
    on_answer: "close", hold_set: "2026-11-20T06:10:00Z"}]'
  d_read
  d_read
  assert_equals "hold.opened new-1 $set_s nas board" \
    "$(tail -n +$((before + 1)) "$MAIN/data/myshape/events.jsonl" | jq -r 'select(.src == "board") | "\(.kind) \(.task) \(.ts) \(.topic) \(.by)"')" \
    "a new hold must leave one opening, at its set time, under its topic"
  before=$(d_board_lines)
  d_report '.holds |= map(select(.id != "new-1"))
    | .closed_holds += [{id: "new-1", title: "NAS 兩步驗證", origin: "", mode: "answered", answer: "要", label: "",
        source: "", digest: "d-new-1", occurrence: 1, opened_at: '"$set_s"', closed_at: '"$((set_s + 120))"'}]'
  d_read
  d_read
  assert_equals "hold.closed new-1 $((set_s + 120)) 待決事項「NAS 兩步驗證」已回答：要（經聊天）" \
    "$(tail -n +$((before + 1)) "$MAIN/data/myshape/events.jsonl" | jq -r 'select(.src == "board") | "\(.kind) \(.task) \(.ts) \(.text)"')" \
    "its chat answer must leave one close, at the time the home gave"
  pass "after the upgrade a new decision leaves one opening and one close"
}

test_d_a_reader_that_refuses_the_cursor_is_read_without_it() {
  printf 'usage feed takes three arguments\n' > "$D_DIR/agg/control/main"
  api refresh '{}' >/dev/null
  rm -f "$D_DIR/agg/control/main"
  d_report 'del(.closed_holds, .closed_cursor)'
  d_read
  assert_equals 'feed main 0 -' "$(d_last_feed)" "a home that refused the cursor must be read without it"
  d_read
  assert_equals 'feed main 0 -' "$(d_last_feed)" "a home that reports no closed decisions is never given a cursor"
  pass "a home on older code that refuses the cursor is read again as before"
}

test_d_going_back_shows_the_lines_as_text() {
  local pid
  pid=$(tb_board_pid "$MAIN")
  install_board_files "$BASE_DECISIONS" fm "$D_DIR/agg"
  sa "$MAIN" open >/dev/null || fail "the next command after going back failed"
  : > "$SA_TRIP_LOG"
  assert_not_equals "$pid" "$(tb_board_pid "$MAIN")" "the next command must replace the new service with the earlier one"
  assert_contains "$(api_state '[.updates[].text] | join("\n")')" "待決事項「NAS 兩步驗證」已回答：要（經聊天）" \
    "the earlier board must show the new records as text"
  sa "$MAIN" goal nas "n2" >/dev/null || fail "a change on the earlier board after going back failed"
  assert_equals 1 "$(grep -c '"kind":"hold.closed"' "$MAIN/data/myshape/events.jsonl")" "the saved records stay, once"
  sa "$MAIN" stop >/dev/null
  sa_check_decoys "$MAIN"
  sa_assert_no_boards
  sa_assert_no_trips
  pass "going back keeps every decision record and the earlier board goes on changing"
}

fm_test_run test_the_old_board_makes_its_data test_the_new_code_refuses_until_the_move \
  test_the_next_command_after_the_move_replaces_the_board test_the_note_in_flight_arrives_once test_the_new_side_reaches_no_firstmate_file \
  test_b2_the_b1_board_leaves_writes_settled_and_in_flight test_b2_the_next_command_replaces_the_board \
  test_b2_unfinished_writes_resume_or_show_once test_b2_the_new_side_reaches_no_firstmate_file \
  test_b3_the_b2_board_keeps_a_mark_and_a_message_in_flight test_b3_the_first_start_keeps_the_mark \
  test_b3_the_message_in_flight_arrives_once \
  test_r_the_b3_board_leaves_lines_without_ids test_r_the_first_start_replays_nothing \
  test_r_changes_now_save_their_records test_r_going_back_drops_only_the_outbox \
  test_d_the_earlier_board_runs_with_an_older_reader test_d_the_first_reads_record_no_past_decision \
  test_d_new_decisions_open_and_close_once test_d_a_reader_that_refuses_the_cursor_is_read_without_it \
  test_d_going_back_shows_the_lines_as_text
