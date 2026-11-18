#!/usr/bin/env bash
# Behavior of fm-topic.sh order against the real fm-fleet-snapshot.sh and a
# fixture backlog.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot topic-board-stage-1-order)

# Queued items, in backlog order:
#   n1 (t2/normal)  h1 (billing/high)  h2 (billing/high)  u1 (untagged)
#   p1 (idea, a leftover proposal in no queue yet, so ranked as untagged)
#   l1 (parked/later, not held)
#   l2 (parked/later, held by the board)  r1 (billing/high, held by the board)
#   a1 (gone/archived, not held)       o1 (billing/high, held by something else)
#   b1 (billing/high, blocked by n1)   c1 (billing/high, a captain hold)
#   d1 (untagged, a captain decision that was answered and released)
write_backlog() {
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] running - Already running (repo: sample) (kind: ship) (since 2026-07-07)

## Queued
- [ ] n1 - Normal one (repo: sample) (kind: ship)
- [ ] h1 - High one (repo: sample) (kind: ship)
- [ ] h2 - High two (repo: sample) (kind: ship)
- [ ] u1 - Untagged (repo: sample) (kind: ship)
- [ ] p1 - Proposed topic item (repo: sample) (kind: ship)
- [ ] l1 - Later not held (repo: sample) (kind: ship)
- [ ] l2 - Later held (repo: sample) (kind: ship) (hold: topic-board：議題 parked 在待辦)
- [ ] r1 - Release me (repo: sample) (kind: ship) (hold: topic-board：議題 billing 在待辦)
- [ ] a1 - Archived not held (repo: sample) (kind: ship)
- [ ] o1 - Other hold (repo: sample) (kind: ship) (hold: waiting for a vendor)
- [ ] b1 - Blocked blocked-by: n1 (repo: sample) (kind: ship)
- [ ] c1 - Captain call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] d1 - Decided call (repo: sample) (kind: captain)

## Done
EOF
}

write_tags() {
  local home=$1 pair
  for pair in n1:t2 h1:billing h2:old-billing l1:parked l2:parked r1:billing a1:gone \
    o1:billing b1:billing c1:billing running:parked; do
    mkdir -p "$home/data/${pair%%:*}"
    printf '%s 2026-07-01T00:00:00Z\n' "${pair##*:}" > "$home/data/${pair%%:*}/topic"
  done
  # A task tagged with a leftover proposal, not yet in any queue, ranks as untagged.
  mkdir -p "$home/data/p1"
  printf 'idea 2026-07-01T00:00:00Z\n' > "$home/data/p1/topic"
}

# section <output> <header>: the task ids listed under one section header.
section() {
  printf '%s\n' "$1" | awk -v header="$2" '
    /^[^ ]/ { active = ($0 == header) ; next }
    active { sub(/^  /, ""); split($0, cols, "\t"); printf "%s ", cols[1] }
  '
}

test_sections() {
  local home out
  home=$(tb_make_home order)
  tb_write_topics "$home"
  write_backlog "$home"
  write_tags "$home"
  out=$(tb_run "$home" "$TOPIC" order)
  assert_equals "h1 h2 r1 n1 u1 p1 d1 " "$(section "$out" "可派：")" \
    "dispatch order must be high, normal, then untagged, in backlog order within a topic"
  assert_equals "l1 a1 " "$(section "$out" "該 hold：")" "items of parked or archived topics must be listed to hold"
  assert_equals "r1 " "$(section "$out" "該解除：")" "a board hold on a non-parked topic must be listed to release"
  assert_equals "l2 " "$(section "$out" "停著：")" "a board hold on a parked topic must be listed as parked"
  assert_contains "$out" 'bin/fm-tasks-axi.sh hold l1 --reason "topic-board：議題 parked 在待辦"' \
    "the hold line must carry the command to run"
  assert_contains "$out" 'bin/fm-tasks-axi.sh hold a1 --reason "topic-board：議題 gone 在封存"' \
    "an archived topic must say so in the hold reason"
  assert_contains "$out" "bin/fm-tasks-axi.sh unhold r1" "the release line must carry the command to run"
  printf '%s\n' "$out" | awk '/^可派：/ { on = 1; next } /^[^ ]/ { on = 0 } on' | grep '^  r1	' | grep -q '先照「該解除」解除' ||
    fail "a dispatchable item still under the board's hold must say so"
  printf '%s\n' "$out" | awk '/^可派：/ { on = 1; next } /^[^ ]/ { on = 0 } on' | grep '^  h1	' | grep -q '解除' &&
    fail "an item that is not held must not be marked as held"
  printf '%s\n' "$out" | grep '^  d1	' | grep -q '決定事項' ||
    fail "a released captain decision must be marked as a decision, not as work to dispatch"
  printf '%s\n' "$out" | grep '^  u1	' | grep -q '決定事項' &&
    fail "ordinary work must not be marked as a decision"
  assert_contains "$out" "$(printf 'h1\t帳務重構\t高')" "lines must show the topic name and queue"
  assert_not_contains "$out" "running" "in-flight items must never be listed"
  assert_not_contains "$(section "$out" "可派：")" "o1" "an item held by something else must not be dispatchable"
  assert_not_contains "$(section "$out" "可派：")" "b1" "a blocked item must not be dispatchable"
  assert_not_contains "$(section "$out" "可派：")" "c1" "a captain hold must not be dispatchable"
  pass "order prints dispatchable, to-hold, to-release, and parked sections"
}

test_lists_hands_on_items_waiting_for_a_check() {
  local home out
  home=$(tb_make_home order-todo)
  tb_write_topics "$home"
  write_backlog "$home"
  write_tags "$home"
  out=$(tb_run "$home" "$TOPIC" order)
  assert_not_contains "$out" "等你驗證" "the section must be absent while nothing waits for a check"
  {
    printf '## In flight\n\n## Queued\n'
    printf -- '- [ ] td1 - Restart x (repo: sample) (kind: captain) (hold: 動手：重啟 x) (hold-kind: captain)\n'
    printf -- '- [ ] td2 - Log in (repo: sample) (kind: captain) (hold: 動手：登入) (hold-kind: captain)\n'
    printf -- '- [ ] td3 - A call (repo: sample) (kind: captain) (hold: 要不要？) (hold-kind: captain)\n'
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
  mkdir -p "$home/data/td1"
  printf 'billing 2026-07-01T00:00:00Z\n' > "$home/data/td1/topic"
  jq '.todos = {td1: {state: "claimed", at: "t"}, td2: {state: "rejected", at: "t", reason: "r"},
                td3: {state: "claimed", at: "t"}, gone: {state: "claimed", at: "t"}}' \
    "$home/data/topics.json" > "$home/data/topics.json.new"
  mv "$home/data/topics.json.new" "$home/data/topics.json"
  out=$(tb_run "$home" "$TOPIC" order)
  assert_equals "td1 " "$(section "$out" "等你驗證：")" \
    "only an open hands-on item the captain says is done waits for a check"
  assert_contains "$out" "$(printf 'td1\t帳務重構\t高\t← 使用者說做完了；驗證後跑 bin/fm-topic.sh todo done td1，沒成功就跑 bin/fm-topic.sh todo failed td1 --reason <一行>')" \
    "the line must carry both commands"
  assert_not_contains "$(section "$out" "可派：")" "td" "a hands-on item is never dispatchable"
  pass "order lists the hands-on items the captain says are done"
}

test_falls_open_without_a_usable_topic_file() {
  local home out
  home=$(tb_make_home order-nofile)
  write_backlog "$home"
  write_tags "$home"
  out=$(tb_run "$home" "$TOPIC" order) || fail "order failed without a topic file"
  assert_contains "$out" "還沒有議題檔" "order did not explain the missing topic file"
  assert_equals "n1 h1 h2 u1 p1 l1 a1 d1 " "$(section "$out" "可派：")" \
    "without a topic file every unheld, unblocked item is dispatchable in backlog order"
  assert_equals "" "$(section "$out" "該 hold：")" "without a topic file nothing may be listed to hold"
  assert_equals "" "$(section "$out" "該解除：")" "without a topic file nothing may be listed to release"
  assert_equals "l2 r1 " "$(section "$out" "停著：")" "items the board held earlier must stay visible without a topic file"
  printf 'not json' > "$home/data/topics.json"
  out=$(tb_run "$home" "$TOPIC" order) || fail "order failed on an unreadable topic file"
  assert_contains "$out" "讀不懂" "order did not explain the unreadable topic file"
  assert_equals "" "$(section "$out" "該 hold：")" "an unreadable topic file must not produce holds"
  home=$(tb_make_secondmate_home order-sm sm1)
  write_backlog "$home"
  out=$(tb_run "$home" "$TOPIC" order) || fail "order failed in a secondmate home"
  assert_contains "$out" "secondmate home" "order did not explain it is in a secondmate home"
  assert_equals "" "$(section "$out" "該 hold：")" "a secondmate home must not produce holds"
  pass "order lets dispatch proceed when the topic file is missing, unreadable, or elsewhere"
}

test_falls_open_when_the_snapshot_fails() {
  local home root out
  home=$(tb_make_home order-nosnap)
  tb_write_topics "$home"
  root="$TMP_ROOT/order-root"
  mkdir -p "$root/bin"
  cp "$ROOT"/bin/fm-topic.sh "$ROOT"/bin/fm-topic-lib.sh "$ROOT"/bin/fm-primary-scope-lib.sh \
    "$ROOT"/bin/fm-secondmate-registry-lib.sh "$root/bin/"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/fm-fleet-snapshot.sh"
  chmod +x "$root/bin/fm-fleet-snapshot.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-topic.sh" order) ||
    fail "order must exit 0 when the snapshot fails"
  assert_equals "讀不到 backlog，照平常的方式派工。" "$out" "order did not fall open on a failed snapshot"
  pass "order tells firstmate to dispatch as usual when the backlog cannot be read"
}

fm_test_run test_sections test_lists_hands_on_items_waiting_for_a_check \
  test_falls_open_without_a_usable_topic_file test_falls_open_when_the_snapshot_fails
