#!/usr/bin/env bash
# fm-dispatch-plan.sh queues-push: the main home sends its queue copy to each
# secondmate on another machine. Every push runs from a scratch code root whose
# bin/fm-on.sh is a stub, so nothing here reaches another machine: the stub
# hands the copy to a real queues-in in a scratch "far" home, or fails the way
# a transfer can fail.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot dispatch-plan-stage-4-queues-push)
# shellcheck source=dispatch-plan/test/helpers.sh
. "$ROOT/dispatch-plan/test/helpers.sh"

# push_setup <name> <remote-id>...: a scratch main home with topics, one local
# and the given remote secondmates registered, and a scratch code root whose
# fm-on.sh is the stub. Sets MAIN, CODE and STUB.
push_setup() {
  local name=$1 id script
  shift
  MAIN=$(tb_make_home "$name-main")
  tb_write_topics "$MAIN"
  CODE="$TMP_ROOT/$name-code"
  STUB="$TMP_ROOT/$name-stub"
  mkdir -p "$CODE/bin" "$STUB/far"
  for script in fm-dispatch-plan.sh fm-primary-scope-lib.sh myshape-lib.sh fm-secondmate-registry-lib.sh; do
    cp "$ROOT/bin/$script" "$CODE/bin/"
  done
  {
    printf '# Secondmates\n'
    printf -- '- sm1 - Local helper (home: %s; scope: sample work; projects: alpha; added 2026-11-01)\n' "$TMP_ROOT/$name-sm1"
    for id in "$@"; do
      printf -- '- %s - Remote helper (host: farbox; root: /srv/fm; home: /srv/fm-home; scope: remote work; projects: beta; added 2026-11-01)\n' "$id"
      mkdir -p "$STUB/far/$id/state" "$STUB/far/$id/data"
      printf '%s\n' "$id" > "$STUB/far/$id/.fm-secondmate-home"
    done
  } > "$MAIN/data/secondmates.md"
  write_stub
}

# The stub stands in for bin/fm-on.sh. It records each call in $STUB/calls and
# behaves as $STUB/<id>.mode says: ok (the default), sleep <s> (then ok), down
# (exit 255), silent (exit 0, no output), old (exit 2, no such subcommand) or
# missing (exit 64, no such command on the far side).
write_stub() {
  cat > "$CODE/bin/fm-on.sh" <<EOF
#!/usr/bin/env bash
set -u
[ "\$1" = --stdin ] || { echo "stub: --stdin missing" >&2; exit 90; }
mate=\$2
shift 2
printf '%s %s\n' "\$mate" "\$*" >> "$STUB/calls"
mode=\$(cat "$STUB/\$mate.mode" 2>/dev/null || echo ok)
case "\$mode" in
  sleep*) sleep "\${mode#sleep }" ;;
esac
case "\$mode" in
  ok | sleep*)
    exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$STUB/far/\$mate" "$ROOT/bin/\$1" "\${@:2}" ;;
  down) cat > /dev/null; echo "ssh: connect to host farbox port 22: No route to host" >&2; exit 255 ;;
  silent) cat > /dev/null; exit 0 ;;
  old) cat > /dev/null; echo "fm-dispatch-plan.sh: 不認得的子命令：queues-in" >&2; exit 2 ;;
  missing) cat > /dev/null; echo "error: command is not a genuine executable in the configured remote root" >&2; exit 64 ;;
esac
exit 91
EOF
  chmod +x "$CODE/bin/fm-on.sh"
}

# push [--check]: run queues-push in the scratch main home from the scratch
# code root; prints stdout only.
push() {
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$CODE" "$CODE/bin/fm-dispatch-plan.sh" queues-push "$@" 2>/dev/null
}

calls() {
  if [ -f "$STUB/calls" ]; then
    awk '{ printf "%s ", $1 }' "$STUB/calls"
  fi
}

reset_calls() {
  rm -f "$STUB/calls"
}

mode() {  # <id> <mode>
  printf '%s\n' "$2" > "$STUB/$1.mode"
}

move_topic() {  # put t2 at the front of high
  jq '.queues.high = ["t2", "billing"] | .queues.normal = []' "$MAIN/data/topics.json" > "$MAIN/data/topics.json.new"
  mv "$MAIN/data/topics.json.new" "$MAIN/data/topics.json"
}

# backdate_delivery <id> <minutes>: make the last delivery to <id> that old.
backdate_delivery() {
  local record="$MAIN/state/dispatch-plan/pushed/$1"
  jq -c --arg at "$(dp_minutes_ago "$2")" '.at = $at' "$record" > "$record.new"
  mv "$record.new" "$record"
}

test_pushes_once_per_mate_whose_copy_differs() {
  local out check
  push_setup differs far1 far2
  out=$(push) || fail "queues-push failed: $out"
  assert_equals "far1 far2 " "$(calls)" "each remote mate, and no local one, must get one push"
  assert_contains "$(head -n 1 "$STUB/calls")" "fm-dispatch-plan.sh queues-in -" "the push must run queues-in on the far side"
  assert_contains "$out" "far1：已送出（" "the report must say the copy went out"
  assert_contains "$(FM_HOME="$STUB/far/far1" "$PLAN" order 2>/dev/null | head -n 1)" "照主 home 推來的佇列副本" \
    "the far side's order must rank by the pushed copy"
  assert_equals "billing t2" "$(jq -r '.queues.high + .queues.normal | join(" ")' "$STUB/far/far2/state/dispatch-plan/queues.json")" \
    "the far side must hold the main home's queues"
  assert_equals "gone" "$(jq -r '.archived | keys | join(" ")' "$STUB/far/far2/state/dispatch-plan/queues.json")" \
    "the copy must carry the archived topics"
  assert_equals "billing" "$(jq -r '.merged["old-billing"]' "$STUB/far/far2/state/dispatch-plan/queues.json")" \
    "the copy must carry the merged ids"
  assert_equals "drwx------" "$(tb_mode "$MAIN/state/dispatch-plan")" "the main home's push records must be private"
  reset_calls
  out=$(push)
  assert_equals "" "$(calls)" "an unchanged copy must not be sent again"
  assert_contains "$out" "far1：副本沒變，上次送達" "the report must say the copy is unchanged"
  move_topic
  check=$(push --check)
  assert_equals "far1 far2 " "$(calls)" "a queue change must be sent to every remote mate once"
  assert_equals "" "$check" "a push that worked must print nothing under --check"
  assert_equals "t2 billing" "$(jq -r '.queues.high | join(" ")' "$STUB/far/far1/state/dispatch-plan/queues.json")" \
    "the far side must get the moved topic"
  pass "queues-push sends one copy to each remote mate whose copy differs, and none when unchanged"
}

test_resends_an_unchanged_copy_after_30_minutes() {
  push_setup refresh far1 far2
  push >/dev/null
  reset_calls
  backdate_delivery far1 29
  backdate_delivery far2 30
  assert_equals "" "$(push --check)" "a refresh must print nothing under --check"
  assert_equals "far2 " "$(calls)" "only a copy delivered 30 minutes ago or more must be sent again"
  reset_calls
  jq -c '.at = "yesterday"' "$MAIN/state/dispatch-plan/pushed/far1" > "$MAIN/state/dispatch-plan/pushed/far1.new"
  mv "$MAIN/state/dispatch-plan/pushed/far1.new" "$MAIN/state/dispatch-plan/pushed/far1"
  push >/dev/null
  assert_equals "far1 " "$(calls)" "a delivery record without a readable time must count as no delivery"
  pass "queues-push sends an unchanged copy again once its last delivery is 30 minutes old"
}

test_retries_a_failed_transfer_at_the_next_run() {
  local out
  push_setup retry far1 far2
  mode far1 down
  mode far2 silent
  out=$(push)
  assert_contains "$out" "far1：送不出去（連不到，fm-on.sh 回 255" "the report must say why far1 failed"
  assert_contains "$out" "far2：送不出去（那邊沒有回 ok queues）" "an answer without the ok line is not a delivery"
  reset_calls
  assert_equals "" "$(push --check)" "a failure under an hour old must print nothing under --check"
  assert_equals "far1 far2 " "$(calls)" "a failed transfer must be retried at the next run"
  mode far1 ok
  mode far2 ok
  reset_calls
  out=$(push)
  assert_contains "$out" "far1：已送出" "the retry must deliver once the far side answers"
  assert_contains "$out" "far2：已送出" "the retry must deliver once the far side answers"
  reset_calls
  push >/dev/null
  assert_equals "" "$(calls)" "after the delivery nothing more may be sent"
  pass "queues-push retries a failed transfer at the next run"
}

test_does_not_hammer_a_mate_without_queues_in() {
  local out failing
  push_setup old far1 far2
  mode far1 old
  mode far2 missing
  push >/dev/null
  reset_calls
  out=$(push)
  assert_equals "" "$(calls)" "a mate whose far side cannot take the copy must not be tried at every run"
  assert_contains "$out" "far1：那邊還不能收副本（那邊的 fm-dispatch-plan.sh 沒有 queues-in（回 2），可能還沒更新到這一版）" \
    "the report must say why far1 is waiting"
  assert_contains "$out" "far2：那邊還不能收副本（那邊的 fm-dispatch-plan.sh 沒有 queues-in（回 64）" "far2 must wait too"
  move_topic
  push >/dev/null
  assert_equals "" "$(calls)" "a queue change alone must not retry it"
  failing="$MAIN/state/dispatch-plan/pushed/far1.failing"
  read -r since _ rc < "$failing"
  printf '%s %s %s\n' "$since" "$(($(date +%s) - 3600))" "$rc" > "$failing"
  mode far1 ok
  out=$(push)
  assert_equals "far1 " "$(calls)" "it must be tried again an hour after the last try"
  assert_contains "$out" "far1：已送出" "the hourly retry must deliver once the far side is updated"
  pass "queues-push tries a mate without queues-in at most once an hour"
}

# Four mates whose transfers take 6 s each: transfers start at about 0, 6 and
# 12 s, and the fourth would start at about 18 s, at the bound. Each transfer
# ends on its own well inside the per-transfer limit, so nothing is signalled.
test_stops_starting_transfers_after_18_seconds() {
  local out id
  push_setup bound far1 far2 far3 far4
  for id in far1 far2 far3 far4; do
    mode "$id" "sleep 6"
  done
  out=$(push)
  assert_equals "far1 far2 far3 " "$(calls)" "no transfer may start after 18 s"
  assert_contains "$out" "far4：這一輪的時間用完，下一輪再送" "the report must name the mate left over"
  reset_calls
  out=$(push --check)
  assert_equals "far4 " "$(calls)" "the next run must send to the mate left over"
  assert_equals "" "$out" "the next run must print nothing under --check"
  pass "queues-push starts no transfer after 18 s and leaves the rest to the next run"
}

test_prints_the_behind_line_once_per_episode() {
  local out failing
  push_setup behind far1 far2
  push >/dev/null
  mode far1 down
  move_topic
  backdate_delivery far1 61
  out=$(push --check)
  assert_equals "看板佇列副本：far1 已經 61 分鐘沒收到主 home 的副本（連不到，fm-on.sh 回 255），它的 order 照舊的副本排；跑 bin/fm-dispatch-plan.sh queues-push 看細節。" \
    "$out" "a mate 60 minutes behind must get exactly one line"
  assert_equals "" "$(push --check)" "the line must not repeat while the episode lasts"
  assert_not_contains "$(push)" "看板佇列副本：" "the bare report must not print the wake line"
  mode far1 ok
  assert_equals "" "$(push --check)" "a delivery ends the episode silently"
  mode far1 down
  jq '.queues.later = []' "$MAIN/data/topics.json" > "$MAIN/data/topics.json.new"
  mv "$MAIN/data/topics.json.new" "$MAIN/data/topics.json"
  backdate_delivery far1 75
  assert_contains "$(push --check)" "看板佇列副本：far1 已經 75 分鐘" "a new episode must print its line again"
  push_setup never far1
  mode far1 down
  push >/dev/null
  failing="$MAIN/state/dispatch-plan/pushed/far1.failing"
  read -r _ last rc < "$failing"
  printf '%s %s %s\n' "$(($(date +%s) - 3700))" "$last" "$rc" > "$failing"
  assert_equals "看板佇列副本：far1 已經 61 分鐘沒收到主 home 的副本（連不到，fm-on.sh 回 255），它的 order 照 backlog 原本的順序排；跑 bin/fm-dispatch-plan.sh queues-push 看細節。" \
    "$(push --check)" "a mate never reached for an hour must get the line too"
  pass "queues-push --check prints the behind line once per episode"
}

test_runs_only_where_there_is_something_to_send() {
  local rc out
  push_setup none
  out=$(push) || fail "queues-push failed with no remote mates"
  assert_equals "沒有遠端的 second mate；沒有要送的。" "$out" "no remote mate must be said plainly"
  assert_equals "" "$(push --check)" "no remote mate must print nothing under --check"
  push_setup nofile far1
  rm "$MAIN/data/topics.json"
  out=$(push) || fail "queues-push failed without a topic file"
  assert_equals "主 home 沒有可用的議題檔，沒有東西可以送。" "$out" "a missing topic file must be said plainly"
  assert_equals "" "$(push --check)" "a missing topic file must print nothing under --check"
  assert_equals "" "$(calls)" "nothing may be sent without a topic file"
  rc=0
  out=$(FM_HOME="$STUB/far/far1" FM_ROOT_OVERRIDE="$CODE" "$CODE/bin/fm-dispatch-plan.sh" queues-push 2>&1) || rc=$?
  expect_code 1 "$rc" "queues-push in a secondmate home"
  assert_contains "$out" "queues-push 只能在主 home 跑" "the refusal must explain itself"
  expect_code 2 "$(tb_code "$MAIN" "$CODE/bin/fm-dispatch-plan.sh" queues-push --now)" "queues-push with an unknown flag"
  pass "queues-push refuses outside the main home and sends nothing without a topic file"
}

fm_test_run test_pushes_once_per_mate_whose_copy_differs test_resends_an_unchanged_copy_after_30_minutes \
  test_retries_a_failed_transfer_at_the_next_run test_does_not_hammer_a_mate_without_queues_in \
  test_stops_starting_transfers_after_18_seconds test_prints_the_behind_line_once_per_episode \
  test_runs_only_where_there_is_something_to_send
