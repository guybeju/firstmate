#!/usr/bin/env bash
# A board that is running when this change lands needs no manual step (AT5.1,
# AT5.2 and AT5.6 of the board-interface test plan, step B0 to B1). One
# board-only root moves forward by commits: first the base's board files, whose
# service makes the data and is left running with a message in flight; then
# this working tree's board files committed on top, run with the hardening and
# the tripwires of the other stage-7 scripts.
#
# The base is pinned to carry's commit before the command split, not computed
# as a merge base: once the change is merged, the merge base is the change
# itself and the step would test nothing.
# shellcheck disable=SC2016 # jq filters are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"
# shellcheck source=topic-board/test/standalone-lib.sh
. "$ROOT/topic-board/test/standalone-lib.sh"

BASE=e5ead862
for tool in jq node curl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || { echo "not ok - base $BASE is not in this checkout" >&2; exit 1; }
TMP_ROOT=$(fm_test_tmproot tb-s7u)
case "$TMP_ROOT" in /*) ;; *) echo "not ok - no scratch root" >&2; exit 1 ;; esac
trap 'tb_stop_boards; fm_test_cleanup' EXIT

sa_init
mkdir -p "$TMP_ROOT/root"
SA_ROOT=$TMP_ROOT/root/board
OLD_COMMIT=$(tb_make_board_root "$SA_ROOT" "$BASE")
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
OLD_COMMIT=$(tb_commit_root "$SA_ROOT" "the old note program's stand-in")
SA_ENV=(FM_TOPIC_BOARD_TEST=1 FM_TOPIC_BOARD_RETRY_MS=600000 FM_TOPIC_BOARD_LOCAL_MS=300)
MAIN=$(sa_home main)
sa_decoys "$MAIN"

# old <op...>: the base's node client, which needs no Firstmate library (the
# base's fm-topic.sh does), against the same root, home and port.
old() {
  env -i HOME="$TMP_ROOT/h" PATH="$SA_PATH" LANG=C.UTF-8 TMPDIR="$SA_TMPDIR" FM_HOME="$MAIN" "${SA_ENV[@]}" \
    node "$SA_ROOT/topic-board/dist/board-client.js" --home "$MAIN" --root "$SA_ROOT" --commit "$OLD_COMMIT" \
    --port "$(cat "$MAIN/config/topic-board-port")" --state "$MAIN/state" --data "$MAIN/data" -- "$@"
}

api() {  # <route> <json body>
  local base
  base="http://127.0.0.1:$(cat "$MAIN/config/topic-board-port")"
  curl -s -m 20 -H "Authorization: Bearer $(cat "$MAIN/state/topic-board/token")" -H "Origin: $base" \
    -H 'Content-Type: application/json' -d "$2" "$base/api/$1"
}

api_state() {  # [jq arguments...] <jq filter>
  curl -s -m 20 -H "Authorization: Bearer $(cat "$MAIN/state/topic-board/token")" \
    "http://127.0.0.1:$(cat "$MAIN/config/topic-board-port")/api/state" | jq -c -r "$@"
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
WRITE_ID=""
REQUEST_ID=""
SNAPSHOT=""

test_the_old_board_makes_its_data() {
  local out
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
  REQUEST_ID=$(grep "\"write_id\":\"$WRITE_ID\"" "$MAIN/state/topic-board/audit.jsonl" | head -n 1 | jq -r '.sending.plan.requestId')
  [[ "$REQUEST_ID" =~ ^tb-[0-9a-f]{16}$ ]] || fail "the old note must carry a request id: $REQUEST_ID"
  assert_grep "3 note --request-id $REQUEST_ID -" "$INBOX_LOG" "the old board must have tried the note once"
  OLD_PID=$(tb_board_pid "$MAIN")
  SNAPSHOT=$(snapshot_data)
  cp "$MAIN/data/topic-board/events.jsonl" "$TMP_ROOT/events.before"
  cp "$MAIN/data/topic-board/summaries.jsonl" "$TMP_ROOT/summaries.before"
  pass "the old board made topics, history, a summary, and a message left in flight"
}

test_the_new_code_replaces_the_running_board() {
  local path new_commit events_before summaries_before
  for path in $TB_BOARD_FILES; do
    rm -rf "${SA_ROOT:?}/$path"
    mkdir -p "$SA_ROOT/$(dirname "$path")"
    cp -R "$ROOT/$path" "$SA_ROOT/$path"
  done
  sa_trip_root "$SA_ROOT"
  new_commit=$(tb_commit_root "$SA_ROOT" "this change")
  printf '0\n' > "$TMP_ROOT/inbox-exit"
  kill -0 "$OLD_PID" 2>/dev/null || fail "the old board must still be running when the change lands"

  sa "$MAIN" open >/dev/null || fail "the next command after the change failed"
  assert_equals 1 "$(tb_board_count "$MAIN")" "exactly one service must serve the home"
  assert_not_equals "$OLD_PID" "$(tb_board_pid "$MAIN")" "the next command must replace the old service"
  kill -0 "$OLD_PID" 2>/dev/null && fail "the old service must be gone"
  assert_contains "$(sa "$MAIN" status)" "程式版本：$new_commit" "status must name the new commit"
  assert_equals "$SNAPSHOT" "$(snapshot_data)" "topics, queue order, archive and history must be intact"
  events_before=$(wc -c < "$TMP_ROOT/events.before" | tr -d ' ')
  summaries_before=$(wc -c < "$TMP_ROOT/summaries.before" | tr -d ' ')
  cmp -s "$TMP_ROOT/events.before" <(head -c "$events_before" "$MAIN/data/topic-board/events.jsonl") ||
    fail "the old events must be kept as they were"
  cmp -s "$TMP_ROOT/summaries.before" <(head -c "$summaries_before" "$MAIN/data/topic-board/summaries.jsonl") ||
    fail "the old summaries must be kept as they were"
  assert_equals "old-b old-a" "$(sa "$MAIN" list --json | jq -r '[.[] | select(.queue == "normal") | .id] | join(" ")')" \
    "the new command must read the old queue order"
  assert_contains "$(sa "$MAIN" find old-d)" "「Old D」（old-d）併入「Old A」（用指令；原因：same thing）" \
    "the new code must read the old history"
  pass "the next command replaces the running board, and every record the old code made is intact"
}

test_the_note_in_flight_arrives_once() {
  wait_for "the note to be delivered" write_is "$WRITE_ID" delivered
  assert_equals 1 "$(grep -c "^0 note --request-id $REQUEST_ID -$" "$INBOX_LOG")" \
    "the new code must deliver the old note once, with its request id"
  assert_equals 0 "$(grep -vc -e "--request-id $REQUEST_ID -" "$INBOX_LOG")" "no other note may be sent"
  sleep 1
  assert_equals 1 "$(grep -c "^0 note --request-id $REQUEST_ID -$" "$INBOX_LOG")" "the note must not be sent again"
  assert_equals 1 "$(api_state --arg id "$WRITE_ID" '[.writes[] | select(.id == $id)] | length')" \
    "the write history must still list the old write"
  pass "the message left in flight is delivered once by the new code, with the same request id"
}

test_the_new_side_reaches_no_firstmate_file() {
  sa "$MAIN" stop >/dev/null
  sa_check_decoys "$MAIN"
  sa_assert_no_boards
  sa_assert_no_trips
  pass "the upgraded board ran in the hardened environment and reached no Firstmate file"
}

fm_test_run test_the_old_board_makes_its_data test_the_new_code_replaces_the_running_board \
  test_the_note_in_flight_arrives_once test_the_new_side_reaches_no_firstmate_file
