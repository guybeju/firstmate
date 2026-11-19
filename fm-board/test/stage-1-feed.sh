#!/usr/bin/env bash
# AT4.1: fm-board.sh feed, the board's feed contract on Firstmate's side. It
# prints one home's report with the aggregator's additions, reads a local
# secondmate with --in-home and a remote one through fm-on.sh, and turns a
# remote checkout that has no reader into exit 4 with one line.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-board-stage-1-feed)
CONTRACT="$ROOT/myshape/test/contract"

# Only scratch homes are read: drop anything that points a run at another home.
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_TASK_INBOX
export FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z
export TB_LOG="$TMP_ROOT/calls.log" TB_PLAY="$TMP_ROOT/play" TB_REMOTES="$TMP_ROOT/remotes"
export FEED_ON_LOG="$TMP_ROOT/fm-on.log" FEED_ON_FAIL="$TMP_ROOT/fm-on-fail"
mkdir -p "$TB_PLAY" "$TB_REMOTES" "$FEED_ON_FAIL"
: > "$TB_LOG"

# FM_HOME is a decoy home: feed must read MYSHAPE_HOME instead.
DECOY=$(tb_make_home decoy)
export FM_HOME="$DECOY"
MAIN=$(tb_make_home main)
SM=$(tb_make_secondmate_home sm sm1)
FAR=$(tb_make_secondmate_home remotes/far1 far1)
tb_write_registry "$MAIN" "$SM"

# The code root every feed runs from: this checkout's scripts, except that
# fm-on.sh logs its argv and, when $FEED_ON_FAIL/<id> exists, fails with that
# file's first line as exit code and the rest as stderr; otherwise it hands over
# to the helpers' stand-in, which reads $TB_REMOTES/<id> and reaches no host.
FAKE="$TMP_ROOT/root"
tb_make_fake_root "$FAKE"
mv "$FAKE/bin/fm-on.sh" "$FAKE/bin/tb-fm-on.sh"
cat > "$FAKE/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'fm-on.sh'; printf ' %s' "$@"; printf '\n'; } >> "$FEED_ON_LOG"
id=$1
[ "$id" != --stdin ] || id=$2
if [ -f "$FEED_ON_FAIL/$id" ]; then
  IFS= read -r code < "$FEED_ON_FAIL/$id"
  tail -n +2 "$FEED_ON_FAIL/$id" >&2
  exit "$code"
fi
exec "$(dirname "$0")/tb-fm-on.sh" "$@"
SH
chmod +x "$FAKE/bin/fm-on.sh"

NOT_ON_FORK="還沒換到 fork：在那台的 code root 加上 fork remote、寫 config/self-update-source 為「fork carry」，再回主 home 跑 /updatefirstmate。它的 agent 不會顯示。"

write_main_fleet() {
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] run-a - Running A (repo: sample) (kind: ship) (since 2026-07-07)

## Queued
- [ ] call-close - Merge it? (repo: sample) (kind: captain) (hold: 要合併嗎？) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
  Captain hold origin: run-a
  Captain hold on answer: close
- [ ] call-later - Later call (repo: sample) (kind: captain) (hold: 之後再看) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] q-parked - Parked (repo: sample) (kind: ship) (hold: 等 CI 修好)
- [ ] q-ready - Ready item (repo: sample) (kind: ship)
  topic: billing
- [ ] q-after - After run-a (repo: sample) (kind: ship) (blocked-by: run-a)

## Done
EOF
  mkdir -p "$home/projects/w" "$home/data/run-a" "$home/data/gone-merged"
  fm_write_meta "$home/state/run-a.meta" "window=firstmate:fm-run-a" "worktree=$home/projects/w" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship" "yolo=off"
  printf 'needs-decision: choose an API shape\n' > "$home/state/run-a.status"
  printf 'billing 2026-07-01T00:00:00Z\nt2 2026-07-02T00:00:00Z\n' > "$home/data/run-a/topic"
  printf 'solo 2026-07-03T00:00:00Z\n' > "$home/data/gone-merged/topic"
}

# write_one_task <home> <task>: a home whose only work is one in-flight task.
write_one_task() {
  local home=$1 task=$2
  printf '## In flight\n- [ ] %s - Only here (repo: sample) (kind: ship) (since 2026-07-07)\n\n## Queued\n\n## Done\n' \
    "$task" > "$home/data/backlog.md"
  mkdir -p "$home/projects/w"
  fm_write_meta "$home/state/$task.meta" "window=firstmate:fm-$task" "worktree=$home/projects/w" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship" "yolo=off"
}

write_main_fleet "$MAIN"
write_one_task "$SM" sm-only
write_one_task "$FAR" far-only
write_one_task "$DECOY" decoy-only

# feed <root> <args...>: run fm-board.sh feed from <root> for the main home.
feed() {
  local root=$1
  shift
  MYSHAPE_HOME="$MAIN" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-board.sh" feed "$@"
}

# feed_code <root> <args...>: run feed, discard output, print the exit code.
feed_code() {
  local rc=0
  feed "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# key_paths: every key path of the JSON on stdin that ends in an object key,
# with array indexes collapsed and the task ids under topics replaced.
key_paths() {
  jq -c '[paths | select(.[-1] | type == "string")
    | map(if type == "number" then 0 else . end)
    | if .[0] == "topics" and length == 2 then ["topics", "<task>"] else . end] | unique'
}

with_ledger_on() {
  : > "$1/config/fleet-ledger"
}

with_ledger_off() {
  rm -f "$1/config/fleet-ledger"
}

test_main_report_carries_the_backlog() {
  local out
  with_ledger_on "$MAIN"
  out=$(feed "$FAKE" main 0 -) || fail "feed main failed"
  assert_equals 'run-a|ship|unknown|false' \
    "$(jq -r '.tasks[] | "\(.id)|\(.kind)|\(.state)|\(.unstarted)"' <<< "$out")" \
    "tasks[] must carry the in-flight task with its kind and state word"
  assert_equals 'call-close|live|close|run-a|要合併嗎？|Merge it? call-later|dated|null||之後再看|Later call' \
    "$(jq -r '[.holds[] | "\(.id)|\(.hold_bucket)|\(.on_answer)|\(.origin)|\(.question)|\(.title)"] | join(" ")' <<< "$out")" \
    "holds[] must carry each captain hold with its bucket, answer outcome, origin, question and title"
  assert_equals '2026-12-01' "$(jq -r '.holds[] | select(.id == "call-later") | .hold_until' <<< "$out")" \
    "a dated hold must carry its date"
  assert_equals 'call-close|true|null call-later|true|null q-parked|false|null q-ready|false|billing q-after|false|null' \
    "$(jq -r '[.queued[] | "\(.id)|\(.captain)|\(.topic_hint)"] | join(" ")' <<< "$out")" \
    "queued[] must list every queued item, whether the captain holds it, and its topic_hint"
  assert_equals '等 CI 修好' "$(jq -r '.queued[] | select(.id == "q-parked") | .hold' <<< "$out")" \
    "a parked item must carry its hold reason"
  assert_equals '["run-a"]' "$(jq -c '.queued[] | select(.id == "q-after") | .blockers' <<< "$out")" \
    "an item blocked by an unfinished task must name it"
  assert_equals 'run-a|default|choose an API shape' \
    "$(jq -r '.status_decisions[] | "\(.id)|\(.key)|\(.summary)"' <<< "$out")" \
    "status_decisions[] must carry the worker's question"
  assert_equals "$(cat "$MAIN/data/run-a/topic")" "$(jq -r '.topics["run-a"]' <<< "$out")" \
    "topics must carry a tag file verbatim"
  assert_equals "$(cat "$MAIN/data/gone-merged/topic")" "$(jq -r '.topics["gone-merged"]' <<< "$out")" \
    "topics must carry the tag file of a task no longer in the backlog"
  assert_equals '' "$(jq -r '.tasks[] | select(.id == "decoy-only") | .id' <<< "$out")" \
    "feed must read MYSHAPE_HOME, not FM_HOME"
  assert_equals 'decoy-only' \
    "$(env -u MYSHAPE_HOME FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-board.sh" feed main 0 - | jq -r '.tasks[].id')" \
    "without MYSHAPE_HOME, feed must read FM_HOME"
  pass "feed main reports tasks, holds, queued items, worker questions and tags from MYSHAPE_HOME"
}

test_main_report_has_the_contract_keys() {
  local out expected actual
  with_ledger_on "$MAIN"
  out=$(feed "$FAKE" main 0 -) || fail "feed main failed"
  expected=$(key_paths < "$CONTRACT/report-main.json")
  actual=$(key_paths <<< "$out")
  assert_equals "$expected" "$actual" "feed main's key paths must equal contract/report-main.json's"
  with_ledger_on "$SM"
  assert_equals "$(jq -c '.tasks[0] | keys' "$CONTRACT/report-sm1.json")" \
    "$(feed "$FAKE" sm1 0 - | jq -c '.tasks[0] | keys')" "an sm1 task must have the keys of contract/report-sm1.json"
  assert_equals "$(jq -c 'keys' "$CONTRACT/report-sm1.json")" "$(feed "$FAKE" sm1 0 - | jq -c 'keys')" \
    "feed sm1's top-level keys must equal contract/report-sm1.json's"
  with_ledger_off "$FAR"
  assert_equals "$(jq -c '.tasks[0] | keys' "$CONTRACT/report-far1.json")" \
    "$(feed "$FAKE" far1 0 - | jq -c '.tasks[0] | keys')" "a far1 task must have the keys of contract/report-far1.json"
  assert_equals "$(jq -c 'keys' "$CONTRACT/report-far1.json")" "$(feed "$FAKE" far1 0 - | jq -c 'keys')" \
    "feed far1's top-level keys must equal contract/report-far1.json's"
  pass "feed's key paths equal the board's contract reports"
}

test_aggregator_block_and_read_hints() {
  local out
  with_ledger_on "$MAIN"
  out=$(feed "$FAKE" main 0 -) || fail "feed main failed"
  assert_equals '{"name":"firstmate","label":"first mate","update_hint":"請在主 home 跑 /updatefirstmate。"}' \
    "$(jq -c '.aggregator' <<< "$out")" "the main report must carry the aggregator block"
  assert_equals "sm1|false|$SM|null|null far1|true|/srv/fm-home|60|400" \
    "$(jq -r '[.secondmates[] | "\(.id)|\(.remote)|\(.home)|\(.read_every_s)|\(.read_timeout_s)"] | join(" ")' <<< "$out")" \
    "a remote secondmate must get read hints of 60 s and 400 s, a local one none, and both keep remote and home"
  assert_equals 'false false' \
    "$(feed "$FAKE" sm1 0 - | jq -r 'has("aggregator")') $(feed "$FAKE" far1 0 - | jq -r 'has("aggregator")')" \
    "only the main report carries the aggregator block"
  pass "the main report carries the aggregator block and read hints for remote secondmates"
}

test_ledger_hint_only_when_the_ledger_is_off() {
  local out
  with_ledger_on "$MAIN"
  with_ledger_on "$SM"
  with_ledger_on "$FAR"
  assert_equals 'true|false true|false true|false' \
    "$(feed "$FAKE" main 0 - | jq -r '"\(.ledger_enabled)|\(has("ledger_hint"))"') $(feed "$FAKE" sm1 0 - |
      jq -r '"\(.ledger_enabled)|\(has("ledger_hint"))"') $(feed "$FAKE" far1 0 - | jq -r '"\(.ledger_enabled)|\(has("ledger_hint"))"')" \
    "a home whose ledger is on must have no ledger_hint"
  with_ledger_off "$MAIN"
  with_ledger_off "$SM"
  with_ledger_off "$FAR"
  out=$(feed "$FAKE" main 0 -) || fail "feed main failed"
  assert_equals 'false|home main 的帳本未開，它的 task 不會有更新。在主 home 的終端機跑 bin/fm-board.sh setup' \
    "$(jq -r '"\(.ledger_enabled)|\(.ledger_hint)"' <<< "$out")" "the main home's hint must name setup"
  assert_equals 'false|home sm1 的帳本未開，它的 task 不會有更新。在主 home 的終端機跑 bin/fm-board.sh --in-home sm1 setup' \
    "$(feed "$FAKE" sm1 0 - | jq -r '"\(.ledger_enabled)|\(.ledger_hint)"')" \
    "a local secondmate's hint must name --in-home setup"
  assert_equals 'false|home far1 的帳本未開，它的 task 不會有更新。在主 home 的終端機跑 bin/fm-on.sh far1 fm-board.sh setup' \
    "$(feed "$FAKE" far1 0 - | jq -r '"\(.ledger_enabled)|\(.ledger_hint)"')" \
    "a remote secondmate's hint must name fm-on.sh setup"
  pass "ledger_hint appears exactly when a home's ledger is off, with the command for that home"
}

test_secondmates_are_read_in_their_own_homes() {
  local out
  out=$(feed "$FAKE" sm1 0 -) || fail "feed sm1 failed"
  assert_equals 'sm-only' "$(jq -r '[.tasks[].id] | join(" ")' <<< "$out")" "feed sm1 must read sm1's home"
  assert_equals false "$(jq -r 'has("secondmates")' <<< "$out")" "a secondmate's report lists no secondmates"
  : > "$FEED_ON_LOG"
  out=$(feed "$FAKE" far1 0 -) || fail "feed far1 failed"
  assert_equals 'fm-on.sh far1 fm-topic-board-read.sh 0 -' "$(cat "$FEED_ON_LOG")" \
    "feed far1 must run the reader through fm-on.sh"
  assert_equals 'far-only' "$(jq -r '[.tasks[].id] | join(" ")' <<< "$out")" "feed far1 must report far1's home"
  : > "$FEED_ON_LOG"
  feed "$FAKE" sm1 0 - >/dev/null || fail "feed sm1 from the fake root failed"
  feed "$FAKE" main 0 - >/dev/null || fail "feed main from the fake root failed"
  assert_equals '' "$(grep -F fm-topic-board-read.sh "$FEED_ON_LOG")" "a local home's reader must run without fm-on.sh"
  pass "feed reads a local secondmate with --in-home and a remote one through fm-on.sh"
}

test_remote_failures() {
  local out err rc text
  for text in "command is not tracked by the configured remote root" \
    "command is not a genuine executable in the configured remote root"; do
    printf '1\nfm-on.sh: fm-topic-board-read.sh: %s\nsecond line\n' "$text" > "$FEED_ON_FAIL/far1"
    rc=0
    out=$(feed "$FAKE" far1 0 - 2>"$TMP_ROOT/err") || rc=$?
    err=$(cat "$TMP_ROOT/err")
    expect_code 4 "$rc" "feed far1 when fm-on.sh says: $text"
    assert_equals "$NOT_ON_FORK" "$err" "the refusal must become exactly the one not-on-fork line"
    assert_equals '' "$out" "a refused read must print no report"
  done
  printf '255\nssh: connect to host farbox port 22: Connection refused\n' > "$FEED_ON_FAIL/far1"
  rc=0
  out=$(feed "$FAKE" far1 0 - 2>"$TMP_ROOT/err") || rc=$?
  expect_code 255 "$rc" "feed far1 when ssh fails"
  assert_equals 'ssh: connect to host farbox port 22: Connection refused' "$(cat "$TMP_ROOT/err")" \
    "another fm-on.sh failure must pass its stderr through"
  assert_equals '' "$out" "a failed read must print no report"
  printf '7\n' > "$FEED_ON_FAIL/far1"
  expect_code 7 "$(feed_code "$FAKE" far1 0 -)" "feed far1 when fm-on.sh exits 7"
  rm -f "$FEED_ON_FAIL/far1"
  pass "a remote checkout without the reader is exit 4 with one line; other fm-on.sh failures pass through"
}

test_usage_errors() {
  expect_code 2 "$(feed_code "$FAKE" nobody 0 -)" "feed of an unknown home"
  expect_code 2 "$(feed_code "$FAKE" '../x' 0 -)" "feed of a malformed home id"
  expect_code 2 "$(feed_code "$FAKE" main -1 -)" "feed with a negative offset"
  expect_code 2 "$(feed_code "$FAKE" main x -)" "feed with a non-numeric offset"
  expect_code 2 "$(feed_code "$FAKE" main '' -)" "feed with an empty offset"
  expect_code 2 "$(feed_code "$FAKE" main 0 nothex)" "feed with a malformed sha"
  expect_code 2 "$(feed_code "$FAKE" main 0 "$(printf 'A%.0s' $(seq 64))")" "feed with an upper-case sha"
  expect_code 2 "$(feed_code "$FAKE" main 0 "$(printf 'a%.0s' $(seq 63))")" "feed with a short sha"
  expect_code 2 "$(feed_code "$FAKE" main 0)" "feed with a missing argument"
  expect_code 2 "$(feed_code "$FAKE" main 0 - extra)" "feed with an extra argument"
  expect_code 0 "$(feed_code "$FAKE" main 0 "$(printf 'a%.0s' $(seq 64))")" "feed with a well-formed sha"
  pass "an unknown home and a malformed offset or sha are usage errors"
}

fm_test_run test_main_report_carries_the_backlog test_main_report_has_the_contract_keys \
  test_aggregator_block_and_read_hints test_ledger_hint_only_when_the_ledger_is_off \
  test_secondmates_are_read_in_their_own_homes test_remote_failures test_usage_errors
