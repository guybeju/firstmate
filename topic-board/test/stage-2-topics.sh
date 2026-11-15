#!/usr/bin/env bash
# Every topic operation fm-topic.sh sends to the board: what it does once, that
# repeating it unchanged is harmless, and what it refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot tb-s2t)
trap 'tb_stop_boards; fm_test_cleanup' EXIT

HOME_DIR=$(tb_make_service_home topics)

t() {
  tb_run "$HOME_DIR" "$TOPIC" "$@"
}

code() {
  tb_code "$HOME_DIR" "$TOPIC" "$@"
}

# queue <name>: the ids in one queue, space separated.
queue() {
  jq -r --arg q "$1" '.queues[$q] | join(" ")' "$HOME_DIR/data/topics.json"
}

field() {  # <jq filter over topics.json>
  jq -r "$1" "$HOME_DIR/data/topics.json"
}

test_propose() {
  local out
  out=$(t propose "Billing rework" --goal "move charges to the new service")
  assert_equals "ok billing-rework 已提議，等使用者確認" "$out" "propose must print the new id"
  assert_equals "proposed|firstmate|" "$(field '.topics["billing-rework"] | "\(.status)|\(.proposed_by)|\(.suggested_queue // "")"')" \
    "a proposal must be stored as proposed by firstmate"
  assert_equals "" "$(queue high)$(queue normal)$(queue later)" "a proposal must not enter any queue"
  out=$(t propose "Billing rework" --goal "move charges to the new service")
  assert_contains "$out" "ok billing-rework " "repeating a proposal must return the same id"
  assert_equals 1 "$(field '.topics | length')" "repeating a proposal must not create a second topic"
  out=$(t propose "Billing rework" --goal "a different goal")
  assert_contains "$out" "ok billing-rework-2 " "the same name with another goal must get a numbered id"
  out=$(t propose "帳務重構" --goal "純中文名稱" --queue high)
  assert_contains "$out" "ok t1 " "a name with no usable slug must get t<n>"
  assert_equals high "$(field '.topics.t1.suggested_queue')" "--queue must be kept as the suggested queue"
  assert_equals 2 "$(field '.next_seq')" "next_seq must advance past the id it handed out"
  out=$(t propose "Custom" --goal "own id" --id my.id-1)
  assert_contains "$out" "ok my.id-1 " "--id must be used as given"
  expect_code 1 "$(code propose "Dup" --goal "g" --id t1)" "--id of an existing topic"
  expect_code 1 "$(code propose "Bad" --goal "g" --id "-lead")" "--id starting with a dash"
  expect_code 1 "$(code propose "   " --goal "g")" "an empty name"
  expect_code 1 "$(code propose "Name" --goal "$(printf 'two\nlines')")" "a two-line goal"
  expect_code 1 "$(code propose "$(printf 'x%.0s' $(seq 1 81))" --goal "g")" "a name over 80 characters"
  expect_code 2 "$(code propose "No goal")" "propose without --goal"
  expect_code 2 "$(code propose)" "propose without a name"
  expect_code 2 "$(code propose "Name" --goal "g" --queue urgent)" "propose with an unknown queue"
  expect_code 2 "$(code propose "Name" --goal "g" --bogus x)" "propose with an unknown flag"
  pass "propose creates a proposed topic, is repeatable, and validates its input"
}

test_confirm() {
  local out
  out=$(t confirm t1)
  assert_equals "ok t1 已確認，放進「高」" "$out" "confirm must use the suggested queue"
  out=$(t confirm t1)
  assert_contains "$out" "本來就已確認" "confirming twice must be a no-op"
  assert_equals "t1" "$(queue high)" "confirming twice must not queue the topic twice"
  t confirm billing-rework >/dev/null
  t confirm billing-rework-2 --queue later >/dev/null
  t confirm my.id-1 >/dev/null
  assert_equals "billing-rework my.id-1" "$(queue normal)" "confirm must default to the end of the normal queue"
  assert_equals "billing-rework-2" "$(queue later)" "--queue must override the default"
  expect_code 1 "$(code confirm nope)" "confirming an unknown topic"
  expect_code 2 "$(code confirm)" "confirm without an id"
  grep -q '"kind":"topic.confirmed","topic":"t1"' "$HOME_DIR/data/topic-board/events.jsonl" ||
    fail "confirm must write a system record"
  assert_equals 4 "$(grep -c '"kind":"topic.confirmed"' "$HOME_DIR/data/topic-board/events.jsonl")" \
    "a repeated confirm must not write a second system record"
  pass "confirm queues a proposal once and records it"
}

test_move() {
  local out
  out=$(t move my.id-1 high)
  assert_contains "$out" "ok my.id-1 已移到「高」" "move must report the new queue"
  assert_equals "t1 my.id-1" "$(queue high)" "a move without a position must append"
  t move billing-rework high --first >/dev/null
  assert_equals "billing-rework t1 my.id-1" "$(queue high)" "--first must put the topic at the front"
  t move my.id-1 high --before t1 >/dev/null
  assert_equals "billing-rework my.id-1 t1" "$(queue high)" "--before must insert ahead of the anchor"
  out=$(t move my.id-1 high)
  assert_contains "$out" "本來就在" "moving to the same queue without a position must not move it"
  assert_equals "billing-rework my.id-1 t1" "$(queue high)" "a repeated move must not send the topic to the end"
  out=$(t move my.id-1 high --before t1)
  assert_contains "$out" "本來就在" "repeating a positioned move must be a no-op"
  t move billing-rework-2 normal >/dev/null
  assert_equals "" "$(queue later)" "moving out of a queue must remove the topic from it"
  expect_code 1 "$(code move my.id-1 high --before billing-rework-2)" "--before a topic in another queue"
  expect_code 1 "$(code move my.id-1 high --before my.id-1)" "--before itself"
  expect_code 1 "$(code move nope high)" "moving an unknown topic"
  expect_code 2 "$(code move my.id-1 urgent)" "moving to an unknown queue"
  expect_code 2 "$(code move my.id-1)" "move without a queue"
  expect_code 2 "$(code move my.id-1 high --first --before t1)" "move with both positions"
  pass "move changes queue and position, and repeats leave the order alone"
}

test_rename_goal_and_close_propose() {
  local out
  out=$(t rename t1 "帳務")
  assert_contains "$out" "ok t1 名稱已改" "rename must report the change"
  assert_equals "帳務" "$(field '.topics.t1.name')" "rename must store the new name"
  assert_contains "$(t rename t1 "帳務")" "沒有變" "renaming to the same name must be a no-op"
  t goal t1 "新的目標" >/dev/null
  assert_equals "新的目標" "$(field '.topics.t1.goal')" "goal must store the new goal"
  expect_code 1 "$(code rename t1 "")" "an empty name"
  expect_code 1 "$(code goal nope "x")" "the goal of an unknown topic"
  expect_code 2 "$(code rename t1)" "rename without a name"

  out=$(t close-propose t1 --reason "三個 PR 都已合併")
  assert_contains "$out" "ok t1 已提議關閉" "close-propose must report the proposal"
  assert_equals "三個 PR 都已合併" "$(field '.topics.t1.close_proposal.reason')" "close-propose must store the reason"
  assert_contains "$(t close-propose t1 --reason "三個 PR 都已合併")" "已經提議過" "the same reason must be a no-op"
  t close-propose t1 --reason "換一個理由" >/dev/null
  assert_equals "換一個理由" "$(field '.topics.t1.close_proposal.reason')" "another reason must replace the first"
  expect_code 2 "$(code close-propose t1)" "close-propose without --reason"
  t propose "Pending" --goal "not confirmed" --id pending >/dev/null
  expect_code 1 "$(code close-propose pending --reason "x")" "close-propose on a proposed topic"
  pass "rename, goal, and close-propose store their text and repeats are no-ops"
}

test_archive_and_reopen() {
  local out
  out=$(t archive t1)
  assert_equals "ok t1 已封存" "$out" "archive must report success"
  assert_equals "null" "$(field '.topics.t1')" "an archived topic must leave topics.json"
  assert_equals "billing-rework my.id-1" "$(queue high)" "an archived topic must leave its queue"
  assert_equals "帳務|null" "$(jq -r '.topics.t1 | "\(.name)|\(.close_proposal)"' "$HOME_DIR/data/topics-archive.json")" \
    "the archive must keep the topic and drop its close proposal"
  assert_contains "$(t archive t1)" "本來就已封存" "archiving twice must be a no-op"
  expect_code 1 "$(code move t1 high)" "moving an archived topic"
  expect_code 1 "$(code propose "Reuse" --goal "g" --id t1)" "reusing an archived id"
  assert_not_contains "$(t list)" "t1" "list must hide an archived topic"
  assert_contains "$(t list --all)" "$(printf 't1\tarchived')" "list --all must show the archived topic"

  out=$(t reopen t1)
  assert_equals "ok t1 已重開，放進「一般」" "$out" "reopen must default to the normal queue"
  assert_equals "billing-rework-2 t1" "$(queue normal)" "reopen must append to the queue"
  assert_equals "{}" "$(jq -c '.topics' "$HOME_DIR/data/topics-archive.json")" "reopen must empty the archive entry"
  assert_contains "$(t reopen t1)" "本來就沒有封存" "reopening twice must be a no-op"
  t archive pending >/dev/null || fail "a proposed topic must be archivable, to turn a proposal down"
  t reopen pending --queue high >/dev/null
  assert_equals "confirmed" "$(field '.topics.pending.status')" "reopening a turned-down proposal accepts it"
  expect_code 1 "$(code archive nope)" "archiving an unknown topic"
  expect_code 1 "$(code reopen nope)" "reopening an unknown topic"
  expect_code 2 "$(code archive)" "archive without an id"
  pass "archive and reopen move a topic between the two files and are repeatable"
}

test_merge() {
  local out
  t propose "Side idea" --goal "fold into billing" --id side >/dev/null
  out=$(t merge side billing-rework)
  assert_equals "ok side 已併入 billing-rework" "$out" "merge must report the alias"
  assert_equals "billing-rework|null" "$(field '"\(.merged.side)|\(.topics.side)"')" \
    "merge must record the alias and drop the old topic"
  assert_contains "$(t merge side billing-rework)" "本來就已併入" "merging twice must be a no-op"
  t merge my.id-1 billing-rework >/dev/null
  assert_equals "billing-rework pending" "$(queue high)" "a merged topic must leave its queue"
  assert_contains "$(t rename side "Billing")" "ok billing-rework " "an old id must act on the topic it was merged into"
  tb_run "$HOME_DIR" "$TOPIC" tag task-1 side >/dev/null
  assert_equals billing-rework "$(cut -d' ' -f1 "$HOME_DIR/data/task-1/topic")" "tag must follow the merged id"
  expect_code 1 "$(code propose "Reuse" --goal "g" --id side)" "reusing a merged id"
  expect_code 1 "$(code merge billing-rework billing-rework)" "merging a topic into itself"
  t propose "Unconfirmed" --goal "target" --id unconfirmed >/dev/null
  expect_code 1 "$(code merge t1 unconfirmed)" "merging into a proposed topic"
  expect_code 1 "$(code merge nope t1)" "merging an unknown topic"
  expect_code 2 "$(code merge t1)" "merge with one id"
  pass "merge aliases the old id, and old ids keep working everywhere"
}

test_reset_token() {
  local before
  before=$(cat "$HOME_DIR/state/topic-board/token")
  assert_contains "$(t reset-token)" "ok reset-token" "reset-token must report success"
  assert_not_equals "$before" "$(cat "$HOME_DIR/state/topic-board/token")" "reset-token must replace the token"
  [ "$(wc -c < "$HOME_DIR/state/topic-board/token" | tr -d ' ')" -eq 65 ] || fail "the token must be 64 hex characters"
  assert_equals "-rw-------" "$(tb_mode "$HOME_DIR/state/topic-board/token")" "the new token must be 0600"
  pass "reset-token replaces the token file"
}

fm_test_run test_propose test_confirm test_move test_rename_goal_and_close_propose \
  test_archive_and_reopen test_merge test_reset_token
t stop >/dev/null
