#!/usr/bin/env bash
# What the board knows after reading its homes: agents and their lights,
# pending decisions, updates, per-home status, and the summary/which commands.
# The main home and a local secondmate home are read by the real scripts; a
# "remote" home is reached through a stand-in fm-on.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot tb-s3)
trap 'tb_stop_boards; fm_test_cleanup' EXIT

export FM_TOPIC_BOARD_TEST=1 FM_TOPIC_BOARD_LOCAL_MS=300 FM_TOPIC_BOARD_REMOTE_MS=300
export FM_TOPIC_BOARD_IDLE_MS=8000 FM_TOPIC_BOARD_STALE_MS=4000
export FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z

# A private code root: this checkout's scripts, its own git history (so every
# home reports the same commit), and a stand-in fm-on.sh.
CODE_ROOT="$TMP_ROOT/root"
fm_git_init_commit "$CODE_ROOT"
mkdir -p "$CODE_ROOT/bin" "$CODE_ROOT/topic-board"
ln -s "$ROOT"/bin/* "$CODE_ROOT/bin/"
ln -s "$ROOT/topic-board/dist" "$CODE_ROOT/topic-board/dist"
rm "$CODE_ROOT/bin/fm-on.sh"
cat > "$CODE_ROOT/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
# Stand-in for fm-on.sh: "remote" home <id> is the local directory
# $TB_REMOTES/<id>. Files in that directory steer what comes back.
set -u
id=$1
shift
remote="$TB_REMOTES/$id"
printf '%s\n' "$*" >> "$remote/fm-on.calls"
if [ -e "$remote/not-on-fork" ]; then
  echo "fm-remote-entrypoint: command is not tracked by the configured remote root" >&2
  exit 1
fi
[ ! -e "$remote/unreachable" ] || exit 255
out=$(FM_HOME="$remote" "$(dirname "$0")/$1" "${@:2}") || exit 1
if [ -e "$remote/schema" ]; then
  printf '%s' "$out" | jq --argjson schema "$(cat "$remote/schema")" '.schema = $schema'
elif [ -e "$remote/commit" ]; then
  printf '%s' "$out" | jq --arg commit "$(cat "$remote/commit")" '.code_commit = $commit'
else
  printf '%s\n' "$out"
fi
SH
chmod +x "$CODE_ROOT/bin/fm-on.sh"
export TB_REMOTES="$TMP_ROOT/remotes"

MAIN=$(tb_make_service_home main)
LOCAL_SM=$(tb_make_secondmate_home sm sm1)
mkdir -p "$TB_REMOTES"
REMOTE_SM="$TB_REMOTES/far1"
mkdir -p "$REMOTE_SM/state" "$REMOTE_SM/data" "$REMOTE_SM/config"
printf 'far1\n' > "$REMOTE_SM/.fm-secondmate-home"
cat > "$MAIN/data/secondmates.md" <<EOF
- sm1 - Local helper (home: $LOCAL_SM; scope: sample work; projects: alpha; added 2026-11-01)
- far1 - Remote helper (host: farbox; root: /srv/fm; home: /srv/fm-home; scope: remote work; projects: beta; added 2026-11-01)
EOF

t() {
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$CODE_ROOT" "$CODE_ROOT/bin/fm-topic.sh" "$@"
}

# view [jq filter]: read every home now, then print (part of) the board state.
view() {
  t open >/dev/null || fail "the board did not start"
  tb_op "$MAIN" dump '{"refresh":true}' | jq -r "${1:-.}"
}

# add_task <home> <id> <status line>: an in-flight worker with a status log.
add_task() {
  mkdir -p "$1/projects/$2"
  fm_write_meta "$1/state/$2.meta" "window=firstmate:fm-$2" "worktree=$1/projects/$2" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship" "yolo=off"
  printf '%s\n' "$3" > "$1/state/$2.status"
}

ledger() {  # <home> <json line>...
  local home=$1
  shift
  printf '%s\n' "$@" >> "$home/state/fleet-ledger.jsonl"
}

tag_at() {  # <home> <task> <topic> <iso time>
  mkdir -p "$1/data/$2"
  printf '%s %s\n' "$3" "$4" >> "$1/data/$2/topic"
}

setup_fleet() {
  t propose "Billing" --goal "rework billing" --id billing >/dev/null
  t propose "Login" --goal "new login page" --id login --queue high >/dev/null
  t propose "Later" --goal "someday" --id later --queue later >/dev/null
  t propose "Idea" --goal "not confirmed yet" --id idea >/dev/null
  t confirm billing >/dev/null
  t confirm login >/dev/null
  t confirm later >/dev/null
  cat > "$MAIN/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-a - Ship A (repo: sample) (kind: ship) (hold: merge it?) (hold-kind: captain)
  Captain hold set: 2026-07-24T00:00:00Z
- [ ] ship-b - Ship B (repo: sample) (kind: ship)

## Queued
- [ ] call-login - Pick a provider (repo: sample) (kind: captain) (hold: 用哪一家？ 選項：A 家 | B 家) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] call-origin - Follow-up call (repo: sample) (kind: captain) (hold: keep going?) (hold-kind: captain)
  Captain hold set: 2026-07-22T00:00:00Z
  Captain hold origin: ship-b
- [ ] call-loose - Loose call (repo: sample) (kind: captain) (hold: unrelated question) (hold-kind: captain)
  Captain hold set: 2026-07-23T00:00:00Z
- [ ] call-dated - Dated call (repo: sample) (kind: captain) (hold: revisit) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-20T00:00:00Z

## Done
EOF
  add_task "$MAIN" ship-a "working: on it"
  add_task "$MAIN" ship-b "needs-decision: which API shape"
  add_task "$MAIN" ship-idea "working: exploring"
  add_task "$MAIN" ship-loose "working: nobody tagged me"
  tag_at "$MAIN" ship-a billing 2026-07-01T00:00:00Z
  tag_at "$MAIN" ship-b later 2026-07-01T00:00:00Z
  tag_at "$MAIN" call-login login 2026-07-01T00:00:00Z
  tag_at "$MAIN" ship-idea idea 2026-07-01T00:00:00Z
  tag_at "$MAIN" gone-task billing 2026-07-01T00:00:00Z
  : > "$MAIN/config/fleet-ledger"
  # 1782864000 is 2026-07-01T00:00:00Z.
  ledger "$MAIN" \
    '{"v":1,"ts":1782864100,"event":"task.dispatched","task":"ship-a","kind":"ship","project":"sample","harness":"claude","model":null}' \
    '{"v":1,"ts":1782864200,"event":"task.status","task":"ship-a","state":"working","key":null,"text":" halfway"}' \
    '{"v":1,"ts":1782864300,"event":"task.pr_ready","task":"ship-a","pr":"https://example.invalid/pull/7"}' \
    '{"v":1,"ts":1782864400,"event":"task.dispatched","task":"gone-task","kind":"ship","project":"sample","harness":"claude","model":null}' \
    '{"v":1,"ts":1782864500,"event":"task.merged","task":"gone-task","via":"pr","pr":"https://example.invalid/pull/3"}' \
    '{"v":1,"ts":1782864600,"event":"task.cleaned_up","task":"gone-task"}'

  add_task "$LOCAL_SM" sm-work "blocked: waiting"
  tag_at "$LOCAL_SM" sm-work login 2026-07-01T00:00:00Z
  add_task "$REMOTE_SM" far-work "working: far away"
  tag_at "$REMOTE_SM" far-work billing 2026-07-01T00:00:00Z
}

test_agents_lights_and_placement() {
  local out
  out=$(view '.agents | map("\(.home)/\(.task)=\(.light):\(.topic // .unsorted_reason)") | sort | join(" ")')
  assert_contains "$out" "main/ship-a=decide:billing" "a task with a live captain hold must show the decide light"
  assert_contains "$out" "main/ship-b=unknown:later" "a tagged task must be placed in its topic"
  assert_contains "$out" "main/ship-idea=unknown:proposed" "a task tagged with a proposed topic must be unsorted"
  assert_contains "$out" "main/ship-loose=unknown:no-tag" "an untagged task must be unsorted"
  assert_contains "$out" "main/gone-task=done:billing" "a cleaned-up task must be done, from its last ledger event"
  assert_contains "$out" "sm1/sm-work=unknown:login" "a local secondmate's worker must be listed with its home"
  assert_contains "$out" "far1/far-work=unknown:billing" "a remote secondmate's worker must be listed with its home"
  assert_equals 7 "$(view '.agents | length')" "only workers are agents, never a secondmate or a queued call"
  pass "agents carry a light, their home, and the topic their tag resolves to"
}

test_holds_are_placed_and_ordered() {
  local out
  out=$(view '.holds | map("\(.task):\(.topic // "-"):\(if .live then "live" else .deferred_reason end)") | join(" ")')
  assert_equals "call-login:login:live ship-a:billing:live call-origin:later:live call-loose:-:live call-dated:-:延到 2026-12-01" "$out" \
    "holds must be ordered live first, by the topic's queue, with unsorted last, then deferred"
  assert_equals 'A 家|B 家' "$(view '.holds[] | select(.task == "call-login") | .options | join("|")')" \
    "an option line at the end of the question must become buttons"
  assert_equals 0 "$(view '.holds[] | select(.task == "ship-a") | .options | length')" \
    "a question without an option line has no buttons"
  assert_equals "main/ship-b:later:which API shape" \
    "$(view '.questions | map("\(.home)/\(.task):\(.topic):\(.summary)") | join(" ")')" \
    "a worker needs-decision must be listed with its topic"
  pass "pending decisions follow their task's or origin's topic and the queue order"
}

test_updates_and_topics() {
  local out
  out=$(view '.updates | map(select(.source == "ledger" and .topic == "billing")) | map("\(.task):\(.event)") | join(" ")')
  assert_equals "gone-task:task.cleaned_up gone-task:task.merged gone-task:task.dispatched ship-a:task.pr_ready ship-a:task.status ship-a:task.dispatched" "$out" \
    "ledger events must be listed newest first under their task's topic"
  assert_equals "https://example.invalid/pull/7|working：halfway" \
    "$(view '[.updates[] | select(.task == "ship-a")] | "\(.[0].pr)|\(.[1].text)"')" \
    "updates must carry the PR link and the status text"
  assert_equals 3 "$(view '[.updates[] | select(.source == "board" and .event == "topic.confirmed")] | length')" \
    "system records must appear among the updates"
  assert_equals "login|billing|later" "$(view '[.queues.high, .queues.normal, .queues.later] | map(join(",")) | join("|")')" \
    "the view must carry the queues"
  assert_equals "proposed" "$(view '.topics.idea.status')" "the view must carry proposed topics"
  pass "updates gather ledger events and system records under each topic"
}

test_event_follows_the_tag_in_effect() {
  # ship-a moves from billing to login after its first three events.
  tag_at "$MAIN" ship-a login 2026-07-02T00:00:00Z
  ledger "$MAIN" '{"v":1,"ts":1782960000,"event":"task.status","task":"ship-a","state":"done","key":null,"text":" finished"}'
  assert_equals "login" "$(view '.agents[] | select(.task == "ship-a") | .topic')" "the agent must follow its newest tag"
  assert_equals "login:1 billing:3" \
    "$(view '[.updates[] | select(.task == "ship-a")] | group_by(.topic) | map("\(.[0].topic):\(length)") | reverse | join(" ")')" \
    "events before a re-tag stay with the old topic; later events go to the new one"
  pass "each ledger event belongs to the topic tagged when it happened"
}

test_ledger_is_stored_once_and_survives_rewrites() {
  local events="$MAIN/data/topic-board/events.jsonl" before
  view >/dev/null
  before=$(grep -c '"src":"ledger"' "$events")
  assert_equals 7 "$before" "every ledger line must be stored exactly once"
  grep -q '"home":"main","raw":"{\\"v\\":1' "$events" || fail "stored ledger events must carry their home and raw line"
  # The home's ledger is rewritten: old lines again plus a new one.
  { head -n 3 "$MAIN/state/fleet-ledger.jsonl"; printf '%s\n' '{"v":1,"ts":1782970000,"event":"task.status","task":"ship-b","state":"working","key":null,"text":" new"}'; } > "$MAIN/state/ledger.new"
  mv "$MAIN/state/ledger.new" "$MAIN/state/fleet-ledger.jsonl"
  view >/dev/null
  assert_equals $((before + 1)) "$(grep -c '"src":"ledger"' "$events")" \
    "after a rewritten ledger only the unseen line may be added"
  # Crash between storing events and saving the cursor: the cursor goes back.
  t stop >/dev/null
  printf '{}\n' > "$MAIN/data/topic-board/offsets.json"
  view >/dev/null
  assert_equals $((before + 1)) "$(grep -c '"src":"ledger"' "$events")" \
    "re-reading a piece after a lost cursor must not duplicate events"
  pass "ledger events are stored once across rewrites, restarts, and lost cursors"
}

test_home_status() {
  local out
  out=$(view '.homes | map("\(.id):\(.version):\(.ledger_enabled)") | join(" ")')
  assert_equals "main:same:true sm1:same:false far1:same:false" "$out" \
    "every home must report its version and whether its ledger is open"
  assert_contains "$(t status)" "home far1：相同" "status must list each home's version"

  printf 'deadbeef\n' > "$REMOTE_SM/commit"
  assert_equals "different" "$(view '.homes[] | select(.id == "far1") | .version')" "another commit must read as different"
  assert_equals 1 "$(view '[.agents[] | select(.home == "far1")] | length')" "a home on another commit is still used"
  rm "$REMOTE_SM/commit"
  printf '99\n' > "$REMOTE_SM/schema"
  assert_equals "incompatible" "$(view '.homes[] | select(.id == "far1") | .version')" "another schema must read as incompatible"
  assert_equals 0 "$(view '[.agents[] | select(.home == "far1")] | length')" "an incompatible home's output must not be used"
  rm "$REMOTE_SM/schema"
  : > "$REMOTE_SM/not-on-fork"
  assert_equals "not-on-fork" "$(view '.homes[] | select(.id == "far1") | .version')" "a home without the script must read as not on the fork"
  assert_equals 0 "$(view '[.agents[] | select(.home == "far1")] | length')" "a home not on the fork shows no agents"
  assert_contains "$(t status)" "home far1：還沒換到 fork" "status must say which home is not on the fork"
  rm "$REMOTE_SM/not-on-fork"
  assert_equals "same" "$(view '.homes[] | select(.id == "far1") | .version')" "the home must recover once it answers again"

  : > "$REMOTE_SM/unreachable"
  view >/dev/null
  sleep 5
  out=$(tb_op "$MAIN" dump | jq -r '"\(.homes[] | select(.id == "far1") | .stale)|\(.agents[] | select(.home == "far1") | "\(.light):\(.stale)")|\(.homes[] | select(.id == "main") | .stale)"')
  assert_equals "true|unknown:true|false" "$out" \
    "a home not read for longer than the stale limit turns its agents unknown; other homes are unaffected"
  rm "$REMOTE_SM/unreachable"
  pass "each home shows its version, ledger flag, and staleness"
}

test_polling_follows_viewers() {
  local calls="$REMOTE_SM/fm-on.calls" before after
  tb_op "$MAIN" dump >/dev/null
  sleep 1
  before=$(wc -l < "$calls")
  tb_op "$MAIN" dump >/dev/null
  sleep 1
  after=$(wc -l < "$calls")
  [ "$after" -gt "$before" ] || fail "homes must be read on a schedule while someone is viewing"
  assert_contains "$(t status)" "輪詢：進行中" "status must report polling while someone is viewing"
  sleep 9
  before=$(wc -l < "$calls")
  sleep 5
  assert_equals "$before" "$(wc -l < "$calls")" "polling must stop once nobody has viewed for the idle limit"
  assert_contains "$(t status)" "輪詢：沒在跑" "status must report that polling stopped"
  # Upstream's snapshot fetches a remote home summary on its own; everything
  # else that reached the remote must be the board's one read command.
  grep -v '^fm-remote-file.sh get state/home-summary.json ' "$calls" |
    grep -vq '^fm-topic-board-read.sh [0-9]* [0-9a-f-]*$' && fail "the board ran something other than the read command remotely"
  pass "the board polls only while someone is viewing, and only with the read command"
}

test_summary_and_which() {
  local out
  out=$(printf 'PR 已就緒，等你看。\n' | t summary ship-a ready -)
  assert_equals "Login：" "$out" "summary must print the topic name as the reminder prefix"
  printf 'PR 已就緒，等你看。\n' | t summary ship-a ready - >/dev/null
  assert_equals 1 "$(wc -l < "$MAIN/data/topic-board/summaries.jsonl" | tr -d ' ')" "an identical summary must be stored once"
  printf '換了一個 PR。' | t summary ship-a ready - >/dev/null
  assert_equals 2 "$(wc -l < "$MAIN/data/topic-board/summaries.jsonl" | tr -d ' ')" "a different text is a new summary"
  assert_equals "ready|login|https://example.invalid/pull/7" \
    "$(view '.summaries[0] | "\(.kind)|\(.topic)|\(.pr)"')" "a ready summary must pick up the task's PR link"
  out=$(printf 'scout 的結論。' | t summary --home far1 far-work report -)
  assert_equals "Billing：" "$out" "summary --home must resolve a secondmate's task"
  assert_equals "null" "$(view '.summaries[] | select(.task == "far-work") | .pr')" "a report summary carries no PR link"
  assert_equals "未分類：" "$(printf 'x' | t summary ship-loose failed -)" "an untagged task must be reported as unsorted"
  assert_equals "未分類：" "$(t which ship-idea)" "a task of a proposed topic is unsorted"
  assert_equals "Login：" "$(t which ship-a)" "which must print the same prefix without storing"
  assert_equals "Login：" "$(t which --home sm1 sm-work)" "which --home must resolve a local secondmate's task"
  : > "$REMOTE_SM/unreachable"
  assert_equals "議題不明（never-seen）：" "$(t which --home far1 never-seen)" \
    "a home that cannot be read must give 'unknown', not 'unsorted'"
  rm "$REMOTE_SM/unreachable"
  assert_equals "未分類：" "$(t which --home far1 never-seen)" "once the home is readable an untagged task is unsorted"

  expect_code 1 "$(printf 'x' | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" summary --home nobody ship-a ready -)" "summary with an unregistered home"
  expect_code 1 "$(printf '   ' | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" summary ship-a ready -)" "an empty summary"
  expect_code 1 "$(printf 'x%.0s' $(seq 1 601) | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" summary ship-a ready -)" "a summary over 600 characters"
  expect_code 2 "$(printf 'x' | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" summary ship-a shipped -)" "an unknown summary kind"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" summary ship-a ready)" "summary without the stdin marker"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" which)" "which without a task"
  pass "summary stores once and both commands print the reminder prefix"
}

test_summary_on_a_cold_board_reads_the_main_home_first() {
  t stop >/dev/null
  assert_equals "Billing：" "$(printf '剛啟動就寫摘要。' | t summary --home far1 far-work landed -)" \
    "a board that has never polled must still know the secondmates"
  pass "summary --home works on a board that was just started"
}

test_dump_is_test_only() {
  t stop >/dev/null
  FM_TOPIC_BOARD_TEST=0 t open >/dev/null
  tb_op "$MAIN" dump >/dev/null 2>&1 && fail "dump must not exist outside test mode"
  t stop >/dev/null
  pass "the dump op is registered only in test mode"
}

test_which_follows_a_retag_nobody_is_watching() {
  t restart >/dev/null || fail "the board did not restart"
  assert_equals "Login：" "$(t which ship-a)" "the task starts in its first topic"
  t tag ship-a billing >/dev/null || fail "retagging failed"
  assert_equals "Billing：" "$(t which ship-a)" "which must follow a retag even when no page keeps the board polling"
  assert_equals "Billing：" "$(printf 'retagged' | t summary ship-a report -)" "summary must follow the retag too"
  pass "which and summary read the task's topic afresh"
}

test_a_wrong_summary_can_be_retracted() {
  local out
  printf '已落地。' | t summary ship-a landed - >/dev/null
  assert_equals 1 "$(view '[.summaries[] | select(.task == "ship-a" and .kind == "landed")] | length')" \
    "the summary to retract must be on the board first"
  out=$(printf '合併其實失敗了。' | t retract ship-a landed -) || fail "retract failed"
  assert_contains "$out" "已落地。" "retract must say which summary it removed"
  assert_equals 0 "$(view '[.summaries[] | select(.task == "ship-a" and .kind == "landed")] | length')" \
    "a retracted summary must leave the board"
  grep -q '合併其實失敗了' "$MAIN/data/topic-board/summaries.jsonl" || fail "the reason must be kept on file"
  expect_code 1 "$(printf 'again' | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" retract ship-a landed -)" "nothing left to retract"
  expect_code 1 "$(printf '  ' | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" retract ship-a ready -)" "a retraction without a reason"
  expect_code 2 "$(printf 'x' | tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" retract ship-a shipped -)" "an unknown kind to retract"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/fm-topic.sh" retract ship-a landed)" "retract without the stdin marker"
  printf '已落地。' | t summary ship-a landed - >/dev/null
  assert_equals 1 "$(view '[.summaries[] | select(.task == "ship-a" and .kind == "landed")] | length')" \
    "the same summary must be storable again once it is true"
  pass "a wrong summary can be retracted with a reason, and stated again later"
}

setup_fleet
last_topic() {  # <home> <task>: the topic the task is tagged with now
  tail -n 1 "$1/data/$2/topic" | cut -d' ' -f1
}

test_split_moves_the_named_tasks_to_a_new_topic() {
  local out rc
  t propose "Docs" --goal "all the docs" --id docs --queue high >/dev/null
  t confirm docs >/dev/null
  t tag sp-1 docs >/dev/null
  t tag sp-2 docs >/dev/null
  t --in-home sm1 tag sp-3 docs >/dev/null

  rc=0
  out=$(t split docs "Docs API" --goal "the API pages" --id docs-api sp-1 ship-b 2>&1) || rc=$?
  assert_equals 1 "$rc" "a task that is not in the source topic must stop the split"
  assert_contains "$out" "ship-b" "the refusal must name the task that is elsewhere"
  rc=0
  out=$(t split docs "Docs API" --goal "the API pages" --id docs-api far1/sp-9 2>&1) || rc=$?
  assert_equals 1 "$rc" "a remote secondmate's task must stop the split"
  assert_contains "$out" "遠端" "the refusal must say the task is in a remote home"
  rc=0
  out=$(t split docs "Docs API" --goal "the API pages" --id docs-api never-tagged 2>&1) || rc=$?
  assert_equals 1 "$rc" "an untagged task must stop the split"
  assert_equals "" "$(t list --all | grep '^docs-api' || true)" "a refused split must not create the topic"
  assert_equals docs "$(last_topic "$MAIN" sp-1)" "a refused split must not move any task"

  out=$(t split docs "Docs API" --goal "the API pages" --id docs-api sp-1) || fail "split failed: $out"
  assert_contains "$out" "ok docs-api 已從 docs 拆出，放進「高」" "split must report the new topic"
  assert_contains "$out" "ok sp-1 已標記為 docs-api" "split must report each task it moved"
  assert_equals "Docs API：" "$(t which sp-1)" "a moved task must belong to the new topic"
  assert_equals docs "$(last_topic "$MAIN" sp-2)" "a task that was not named must stay"
  assert_equals "login docs docs-api" "$(jq -r '.queues.high | join(" ")' "$MAIN/data/topics.json")" \
    "the new topic must sit right after its source"

  out=$(t split docs "Docs API" --goal "the API pages" sp-1 sp-2 sm1/sp-3) || fail "the second run failed: $out"
  assert_contains "$out" "ok docs-api 本來就已從 docs 拆出" "running the split again must reuse the topic"
  assert_equals "docs-api" "$(last_topic "$MAIN" sp-2)" "the second run must move the tasks the first did not"
  assert_equals "docs-api" "$(last_topic "$LOCAL_SM" sp-3)" "a local secondmate's task must be moved in its own home"
  assert_equals 2 "$(wc -l < "$MAIN/data/sp-1/topic" | tr -d ' ')" "a task already moved must not be tagged twice"
  assert_equals 1 "$(jq '[.history[] | select(.kind == "split")] | length' "$MAIN/data/topics.json")" \
    "the split must be recorded once"
  assert_contains "$(t find docs-api)" "從「Docs」（docs）拆出「Docs API」（docs-api）" "find must show where the topic came from"

  rc=0
  t split docs >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "split without a name is a usage error"
  rc=0
  out=$(FM_HOME="$LOCAL_SM" FM_ROOT_OVERRIDE="$CODE_ROOT" "$CODE_ROOT/bin/fm-topic.sh" split docs X --goal g 2>&1) || rc=$?
  assert_equals 1 "$rc" "split must be refused in a secondmate home"
  pass "split creates the topic once, moves the named tasks, and can be run again to finish"
}

# Runs last: it renames and merges topics the other tests rely on.
test_find_traces_renames_merges_and_tasks() {
  local out rc
  t propose "Reports" --goal "monthly numbers" --id reports >/dev/null
  t rename reports "Money reports" >/dev/null
  t merge reports billing >/dev/null
  out=$(t find reports) || fail "find failed: $out"
  assert_equals "billing　Billing（一般）" "$(printf '%s\n' "$out" | head -n 1)" "find must lead with where the old id is now"
  assert_contains "$out" "「Reports」改名為「Money reports」" "find must show the rename"
  assert_contains "$out" "「Money reports」（reports）併入「Billing」" "find must show the merge"
  assert_equals "$out" "$(t find 'money REP')" "an old name must find the same topic, ignoring case"
  assert_contains "$(t find ship-a)" "task main/ship-a：Billing（2026-07-01）→ Login（2026-07-02）→ Billing（" \
    "find must show every topic a task was tagged with, oldest first"
  assert_contains "$(t find sm-work)" "task sm1/sm-work：" "find must look for the task in secondmate homes too"
  assert_equals "找不到「nothing-here」。" "$(t find nothing-here)" "find must say when nothing matches"
  rc=0
  t find >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "find without a keyword is a usage error"
  t restart >/dev/null
  assert_equals "$out" "$(t find reports)" "the history must survive a restart"
  assert_contains "$(t find ship-a)" "task main/ship-a：Billing（" "find must read the home afresh on a cold board"
  assert_equals '["merged","renamed","split"]' "$(jq -c '[.history[].kind] | sort' "$MAIN/data/topics.json")" \
    "the history must be stored in the topic file"
  pass "find traces a topic through renames and merges, and a task through its tags"
}

fm_test_run test_agents_lights_and_placement test_holds_are_placed_and_ordered test_updates_and_topics \
  test_event_follows_the_tag_in_effect test_ledger_is_stored_once_and_survives_rewrites test_home_status \
  test_polling_follows_viewers test_summary_and_which test_summary_on_a_cold_board_reads_the_main_home_first \
  test_dump_is_test_only test_which_follows_a_retag_nobody_is_watching \
  test_a_wrong_summary_can_be_retracted test_split_moves_the_named_tasks_to_a_new_topic \
  test_find_traces_renames_merges_and_tasks
