#!/usr/bin/env bash
# What the board sends out: the exact commands it runs, how each result is
# judged, retries, resend and ignore, recovery after a restart, and the notice
# that a topic became dispatchable. fm-inbox.sh, fm-send.sh, fm-captain-hold.sh
# and fm-on.sh are stand-ins that log their input and follow a per-test script.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot tb-s4)
trap 'tb_stop_boards; fm_test_cleanup' EXIT

export FM_TOPIC_BOARD_TEST=1 FM_TOPIC_BOARD_LOCAL_MS=60000 FM_TOPIC_BOARD_REMOTE_MS=60000
export FM_TOPIC_BOARD_RETRY_MS=200,200,200,200,200 FM_TOPIC_BOARD_NOTIFY_MS=1500
export FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z
export TB_LOG="$TMP_ROOT/calls.log" TB_PLAY="$TMP_ROOT/play" TB_REMOTES="$TMP_ROOT/remotes"
mkdir -p "$TB_PLAY" "$TB_REMOTES"
: > "$TB_LOG"

CODE_ROOT="$TMP_ROOT/root"
tb_make_fake_root "$CODE_ROOT"

MAIN=$(tb_make_service_home main)
LOCAL_SM=$(tb_make_secondmate_home sm sm1)
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

view() {
  t open >/dev/null || fail "the board did not start"
  tb_op "$MAIN" dump '{"refresh":true}' | jq -r "${1:-.}"
}

# write <kind> <key> <value>...: submit a write; prints its id, or fails the test.
write() {
  local kind=$1 args out
  shift
  args=$(jq -cn --arg kind "$kind" '$ARGS.positional as $p
    | reduce range(0; $p | length; 2) as $i ({kind: $kind}; .[$p[$i]] = $p[$i + 1])' --args "$@")
  out=$(tb_op "$MAIN" test-write "$args") || return 1
  printf '%s' "$out" | jq -r '.write_id'
}

# refused <kind> <key> <value>...: 0 when the board refuses the write.
refused() {
  ! write "$@" >/dev/null 2>&1
}

state_of() {
  tb_op "$MAIN" dump | jq -r --arg id "$1" '.writes[] | select(.id == $id) | .state'
}

# settle <write-id> <state>: wait until the write reaches <state>.
settle() {
  local tries=0
  while [ "$(state_of "$1")" != "$2" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 80 ] || fail "write $1 never became $2 (it is $(state_of "$1"))"
    sleep 0.15
  done
}

calls() {  # <play key>: how many times that stand-in was called
  grep -c "^cmd=$1	" "$TB_LOG" || true
}

last_call() {  # <play key>
  grep "^cmd=$1	" "$TB_LOG" | tail -n 1
}

play() {  # <play key> <step>...
  local key=$1
  shift
  printf '%b\n' "$@" > "$TB_PLAY/$key"
}

hold_backlog() {  # <home> <task>
  cat > "$1/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $2 - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)
  Captain hold set: 2026-07-24T00:00:00Z

## Done
EOF
}

setup_fleet() {
  t propose "Billing" --goal "rework billing" --id billing >/dev/null
  t propose "Login" --goal "new login" --id login >/dev/null
  t propose "Parked" --goal "later" --id parked --queue later >/dev/null
  t propose "Parked two" --goal "later too" --id parked2 --queue later >/dev/null
  for id in billing login parked parked2; do t confirm "$id" >/dev/null; done
  hold_backlog "$MAIN" call-main
  hold_backlog "$LOCAL_SM" call-sm
  hold_backlog "$REMOTE_SM" call-far
  mkdir -p "$MAIN/data/call-main"
  printf 'billing 2026-07-01T00:00:00Z\n' > "$MAIN/data/call-main/topic"
  view >/dev/null
}

test_message_to_firstmate() {
  local id call
  id=$(write message topic billing text "請先做帳務")
  settle "$id" delivered
  call=$(last_call fm-inbox.sh)
  assert_contains "$call" "argv=note|--request-id|tb-" "the note must use fm-inbox.sh note --request-id"
  assert_contains "$call" "|-|	home=$MAIN	" "the note body must come from stdin and FM_HOME must be the main home"
  assert_contains "$call" 'stdin=［議題：Billing（billing）］\n請先做帳務' "the note must name the topic before the text"

  play fm-inbox.sh '3\tsaved but not woken' '3' '0'
  id=$(write message topic billing text "再說一次")
  settle "$id" delivered
  assert_equals 1 "$(grep '^cmd=fm-inbox.sh' "$TB_LOG" | tail -n 3 | cut -f2 | sort -u | wc -l | tr -d ' ')" \
    "a note that was saved but did not wake firstmate must be replayed with the same request id"
  play fm-inbox.sh '1'
  id=$(write message topic billing text "會失敗")
  settle "$id" failed
  refused message topic nope text "x" || fail "a message for an unknown topic must be refused"
  refused message topic billing text "   " || fail "an empty message must be refused"
  pass "a message becomes one fm-inbox.sh note, replayed by request id until firstmate is woken"
}

test_direct_message() {
  local id before call
  id=$(write direct home main task ship-a text "看一下 CI")
  settle "$id" delivered
  assert_contains "$(last_call fm-send.sh)" "argv=ship-a|看一下 CI|	home=$MAIN	" \
    "a direct message to a main-home worker must be fm-send.sh <task> <text>"
  before=$(calls fm-send.sh)
  refused direct home main task ship-a text "/compact" || fail "text starting with / must be refused"
  refused direct home main task ship-a text "\$skill" || fail "text starting with \$ must be refused"
  refused direct home main task ship-a text "--key" || fail "text starting with - must be refused"
  refused direct home far1 task far-work text "/x" || fail "relayed text starting with / must be refused too"
  refused direct home nobody task x text "hi" || fail "an unknown home must be refused"
  assert_equals "$before" "$(calls fm-send.sh)" "a refused direct message must never reach fm-send.sh"

  play fm-send.sh '1'
  id=$(write direct home main task ship-a text "第一次失敗")
  settle "$id" failed
  assert_equals 1 "$(tb_op "$MAIN" dump | jq '[.writes[] | select(.state == "failed" or .state == "undelivered" or .state == "unknown")] | length - 1')" \
    "a failed write must count as needing attention"
  tb_op "$MAIN" test-resend "{\"write_id\":\"$id\"}" >/dev/null || fail "a failed write must be resendable"
  settle "$id" delivered

  id=$(write direct home far1 task far-work text "遠端的訊息")
  settle "$id" delivered
  call=$(last_call fm-send.sh)
  printf '%s' "$call" | grep -Eq 'argv=far1\|--fire-and-forget\|[a-f0-9]{16}\|轉給 far-work：遠端的訊息\|' ||
    fail "a relayed message must be fm-send.sh <secondmate> --fire-and-forget <id> 轉給 <worker>：<text>: $call"
  play fm-send.sh '3' '3' '0'
  id=$(write direct home far1 task far-work text "要重試")
  settle "$id" delivered
  assert_equals 1 "$(grep '^cmd=fm-send.sh' "$TB_LOG" | tail -n 3 | cut -f2 | sort -u | wc -l | tr -d ' ')" \
    "an unconfirmed remote relay must be retried with the same delivery id"
  play fm-send.sh '3'
  id=$(write direct home sm1 task sm-work text "同機不重試")
  settle "$id" failed
  pass "direct messages go to fm-send.sh, never as commands, and relays retry only when remote"
}

test_retries_run_out() {
  local id before
  play fm-inbox.sh '3' '3' '3' '3' '3' '3'
  before=$(calls fm-inbox.sh)
  id=$(write message topic billing text "一直叫不醒")
  settle "$id" undelivered
  assert_equals 6 "$(($(calls fm-inbox.sh) - before))" "a write must be tried once and retried five times"
  tb_op "$MAIN" test-ignore "{\"write_id\":\"$id\"}" >/dev/null || fail "an undelivered write must be ignorable"
  assert_equals ignored "$(state_of "$id")" "ignore must mark the write"
  tb_op "$MAIN" test-resend "{\"write_id\":\"$id\"}" >/dev/null 2>&1 && fail "an ignored write must not be resendable"
  pass "after five retries a write is undelivered, and can be ignored"
}

test_answers() {
  local id notes
  notes=$(calls fm-inbox.sh)
  id=$(write answer home main task call-main answer "合併" label "合併" mode release)
  settle "$id" delivered
  assert_contains "$(last_call fm-captain-hold.sh)" "argv=answers|--source|topic-board|	home=$MAIN	stdin=call-main	合併	合併	release" \
    "a main-home answer must be one tab-separated line on stdin of fm-captain-hold.sh answers"
  assert_contains "$(last_call fm-inbox.sh)" "argv=note|--request-id|tb-$id-note|-|" "the notice must derive its request id from the write"
  assert_contains "$(last_call fm-inbox.sh)" "已在看板回答 main/call-main：合併" "the notice must say what was answered"
  assert_equals $((notes + 1)) "$(calls fm-inbox.sh)" "an answer must notify firstmate exactly once"
  grep -q '"kind":"hold.answered"' "$MAIN/data/topic-board/events.jsonl" || fail "a delivered answer must leave a system record"

  notes=$(calls fm-inbox.sh)
  play fm-captain-hold.sh '1\tskipped: call-main (already closed)'
  id=$(write answer home main task call-main answer "先不要" label "先不要" mode "done")
  settle "$id" handled_elsewhere
  play fm-captain-hold.sh '1\trefused: call-main (away posture)'
  id=$(write answer home main task call-main answer "先不要" label "先不要" mode release)
  settle "$id" failed
  assert_equals "$notes" "$(calls fm-inbox.sh)" "an answer that did not land must not notify firstmate"

  id=$(write answer home sm1 task call-sm answer "好" label "文字作答" mode "done")
  settle "$id" delivered
  assert_contains "$(last_call fm-captain-hold.sh)" "home=$LOCAL_SM	stdin=call-sm	好	文字作答	done" \
    "a local secondmate's hold must be answered inside that home"
  play fm-on.sh.fm-captain-hold.sh '255' '0\tclosed: call-far'
  id=$(write answer home far1 task call-far answer "好" label "文字作答" mode "done")
  settle "$id" delivered
  assert_contains "$(last_call fm-on.sh.fm-captain-hold.sh)" "argv=far1|answers|--source|topic-board|	" \
    "a remote hold must be answered through fm-on.sh --stdin"
  assert_equals 2 "$(calls fm-on.sh.fm-captain-hold.sh)" "a transport failure must be retried by replaying the answer"

  refused answer home main task call-main answer "a	b" label x mode "done" || fail "an answer with a tab must be refused"
  refused answer home main task no-such-hold answer "x" label x mode "done" || fail "an answer to no hold must be refused"
  refused answer home main task call-main answer "x" label x mode maybe || fail "an unknown mode must be refused"
  pass "an answer is recorded on the hold first, then firstmate is told once"
}

test_tagging() {
  local id
  mkdir -p "$MAIN/projects/loose"
  id=$(write tag home main task loose-task topic login)
  settle "$id" delivered
  assert_equals login "$(cut -d' ' -f1 "$MAIN/data/loose-task/topic")" "a main-home tag must be written by fm-topic.sh tag"
  id=$(write tag home sm1 task sm-loose topic login)
  settle "$id" delivered
  assert_equals login "$(cut -d' ' -f1 "$LOCAL_SM/data/sm-loose/topic")" "a local secondmate tag must land in that home"
  grep -q '"kind":"agent.tagged"' "$MAIN/data/topic-board/events.jsonl" || fail "a delivered tag must leave a system record"
  refused tag home main task loose-task topic nope || fail "tagging with an unknown topic must be refused"

  # Transport fails, but the tag did land: the retry reads the home and stops.
  play fm-on.sh.fm-topic.sh '255'
  mkdir -p "$REMOTE_SM/data/far-a"
  id=$(write tag home far1 task far-a topic billing)
  printf 'billing 2026-07-02T00:00:00Z\n' > "$REMOTE_SM/data/far-a/topic"
  settle "$id" delivered
  assert_equals 1 "$(grep -c '|tag|far-a|' "$TB_LOG")" "a tag already in place must not be written again"

  # Transport fails and someone else tags the task with another topic meanwhile.
  play fm-on.sh.fm-topic.sh '255'
  id=$(write tag home far1 task far-b topic billing)
  mkdir -p "$REMOTE_SM/data/far-b"
  printf 'login 2026-07-02T00:00:00Z\n' > "$REMOTE_SM/data/far-b/topic"
  settle "$id" handled_elsewhere
  assert_equals login "$(tail -n 1 "$REMOTE_SM/data/far-b/topic" | cut -d' ' -f1)" "another topic's tag must not be overwritten"

  # Transport fails and nothing changed: the retry writes the tag.
  play fm-on.sh.fm-topic.sh '255'
  id=$(write tag home far1 task far-c topic billing)
  settle "$id" delivered
  assert_equals billing "$(cut -d' ' -f1 "$REMOTE_SM/data/far-c/topic")" "an unchanged home must get the tag on retry"
  pass "tags are reconciled against a fresh read before every retry"
}

test_same_home_writes_do_not_overlap() {
  local first second
  play fm-send.sh 'sleep1' 'sleep1'
  first=$(write direct home main task ship-a text "one")
  second=$(write direct home main task ship-a text "two")
  settle "$first" delivered
  settle "$second" delivered
  assert_equals "start end start end" "$(grep -E '^(start|end) fm-send.sh$' "$TB_LOG" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')" \
    "two writes to the same home must run one after the other"
  pass "writes to one home are serialized"
}

test_restart_resumes_or_settles() {
  local note send old pid before
  play fm-inbox.sh '3'
  play fm-send.sh 'sleep30'
  FM_TOPIC_BOARD_RETRY_MS=60000 t restart >/dev/null
  view >/dev/null
  note=$(write message topic billing text "重啟後接著送")
  send=$(write direct home main task ship-a text "送到一半")
  settle "$note" retrying
  pid=$(tb_board_pid "$MAIN")
  kill -KILL "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  pkill -f "sleep 30" 2>/dev/null || true
  t open >/dev/null
  settle "$note" delivered
  settle "$send" unknown
  tb_op "$MAIN" test-resend "{\"write_id\":\"$send\"}" >/dev/null 2>&1 && fail "resending an unknown outcome must need confirmation"
  tb_op "$MAIN" test-resend "{\"write_id\":\"$send\",\"confirmed\":true}" >/dev/null || fail "a confirmed resend must be accepted"
  settle "$send" delivered

  play fm-inbox.sh '3'
  FM_TOPIC_BOARD_RETRY_MS=60000 t restart >/dev/null
  view >/dev/null
  old=$(write message topic billing text "放太久")
  settle "$old" retrying
  pid=$(tb_board_pid "$MAIN")
  kill -KILL "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  sleep 1.2
  FM_TOPIC_BOARD_RESUME_MS=1000 t open >/dev/null
  before=$(calls fm-inbox.sh)
  settle "$old" undelivered
  assert_equals "$before" "$(calls fm-inbox.sh)" "an interrupted write older than the resume window must not be sent"
  t restart >/dev/null
  pass "after a restart, safe writes continue, stale ones stop, and uncertain ones are flagged"
}

test_answer_notice_survives_a_restart() {
  local id answers pid
  view >/dev/null
  answers=$(calls fm-captain-hold.sh)
  play fm-inbox.sh '3'
  FM_TOPIC_BOARD_RETRY_MS=60000 t restart >/dev/null
  view >/dev/null
  id=$(write answer home main task call-main answer "合併" label "合併" mode "done")
  settle "$id" retrying
  pid=$(tb_board_pid "$MAIN")
  kill -KILL "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  t open >/dev/null
  settle "$id" delivered
  assert_equals $((answers + 1)) "$(calls fm-captain-hold.sh)" "the answer itself must not be sent again after a restart"
  assert_equals 1 "$(grep "^cmd=fm-inbox.sh" "$TB_LOG" | grep "tb-$id-note" | cut -f2 | sort -u | wc -l | tr -d ' ')" \
    "the notice must be replayed under the same request id"
  pass "a restart between the answer and its notice finishes the notice only"
}

# page <op> <json>: a topic operation sent the way the board page sends it.
page() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $(cat "$MAIN/state/topic-board/token")" \
    -H "Origin: http://127.0.0.1:$(cat "$MAIN/state/topic-board/port")" \
    -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:$(cat "$MAIN/state/topic-board/port")/api/topics/$1"
}

page_body() {  # <op> <json>: the same request, printing the answer
  curl -s -X POST \
    -H "Authorization: Bearer $(cat "$MAIN/state/topic-board/token")" \
    -H "Origin: http://127.0.0.1:$(cat "$MAIN/state/topic-board/port")" \
    -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:$(cat "$MAIN/state/topic-board/port")/api/topics/$1"
}

# wait_calls <play key> <count>: wait until that stand-in was called <count> times.
wait_calls() {
  local tries=0
  while [ "$(calls "$1")" -lt "$2" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 40 ] || fail "$1 was called $(calls "$1") times, expected $2"
    sleep 0.15
  done
}

test_decisions_made_on_the_page_reach_firstmate() {
  local before code
  before=$(calls fm-inbox.sh)
  t propose "By hand" --goal "g" --id byhand >/dev/null
  t confirm byhand >/dev/null
  t propose "Fresh idea" --goal "g" --id fresh >/dev/null
  sleep 1
  assert_equals "$before" "$(calls fm-inbox.sh)" "what firstmate does itself must not come back as a notice"
  assert_equals 200 "$(page confirm '{"id":"fresh","queue":"high"}')" "confirming on the page failed"
  wait_calls fm-inbox.sh $((before + 1))
  assert_contains "$(last_call fm-inbox.sh)" "stdin=使用者在看板上：議題「Fresh idea」已確認，放進「高」（id：fresh）" \
    "a confirmation made on the page must tell firstmate the topic and its id"
  assert_equals 200 "$(page confirm '{"id":"fresh"}')" "confirming again failed"
  assert_equals 200 "$(page rename '{"id":"fresh","value":"Fresh name"}')" "renaming on the page failed"
  t close-propose fresh --reason "all done" >/dev/null
  sleep 1
  assert_equals $((before + 1)) "$(calls fm-inbox.sh)" "a repeated confirmation, a rename, and firstmate's own proposal send nothing"
  assert_equals 200 "$(page keep '{"id":"fresh"}')" "keeping the topic open failed"
  wait_calls fm-inbox.sh $((before + 2))
  assert_contains "$(last_call fm-inbox.sh)" "stdin=使用者在看板上：議題「Fresh name」先不關（id：fresh）" \
    "turning down a close proposal must reach firstmate"
  code=$(page_body merge '{"from":"byhand","into":"fresh"}' | jq -r '.confirm')
  assert_equals $((before + 2)) "$(calls fm-inbox.sh)" "asking to merge, before confirming it, sends nothing"
  assert_equals 200 "$(page merge "{\"from\":\"byhand\",\"into\":\"fresh\",\"confirm\":\"$code\"}")" "merging on the page failed"
  wait_calls fm-inbox.sh $((before + 3))
  assert_contains "$(last_call fm-inbox.sh)" "議題「By hand」已併入「Fresh name」（id：fresh）" "a merge made on the page must reach firstmate"
  assert_equals 200 "$(page archive '{"id":"fresh"}')" "archiving on the page failed"
  wait_calls fm-inbox.sh $((before + 4))
  assert_contains "$(last_call fm-inbox.sh)" "議題「Fresh name」已封存（id：fresh）" "archiving on the page must reach firstmate"
  pass "confirm, keep, merge, and archive done on the page are sent to firstmate; its own commands are not"
}

test_dispatchable_notice() {
  local before
  before=$(calls fm-inbox.sh)
  t move parked normal >/dev/null
  sleep 0.5
  t move parked later >/dev/null
  sleep 2
  assert_equals "$before" "$(calls fm-inbox.sh)" "moving a topic back to later before the delay must send nothing"
  t move billing normal --first >/dev/null
  sleep 2
  assert_equals "$before" "$(calls fm-inbox.sh)" "reordering within the dispatchable queues must send nothing"
  t move parked normal >/dev/null
  t move parked2 high >/dev/null
  sleep 2.5
  assert_equals $((before + 1)) "$(calls fm-inbox.sh)" "topics that become dispatchable together must share one notice"
  assert_contains "$(last_call fm-inbox.sh)" "stdin=議題「Parked」、「Parked two」已可派工，請跑 order 重新評估" \
    "the notice must name the topics and tell firstmate to run order"
  t archive parked >/dev/null
  t reopen parked >/dev/null
  sleep 2.5
  assert_equals $((before + 2)) "$(calls fm-inbox.sh)" "reopening an archived topic must send the notice"
  pass "firstmate is told once when topics leave later or are reopened and then stay put"
}

test_audit_log() {
  local audit="$MAIN/state/topic-board/audit.jsonl" id
  assert_equals "-rw-------" "$(tb_mode "$audit")" "the audit log must be 0600"
  id=$(write message topic billing text "稽核")
  settle "$id" delivered
  assert_equals "sending delivered" "$(grep "\"write_id\":\"$id\"" "$audit" | jq -r '.state' | tr '\n' ' ' | sed 's/ $//')" \
    "every state change must be exactly one audit line"
  grep "\"write_id\":\"$id\"" "$audit" | head -n 1 | jq -e '.sending.text == "稽核" and .sending.plan.requestId != null' >/dev/null ||
    fail "the first audit line must carry the full text and the dedupe key"
  grep -v '^cmd=\(fm-inbox.sh\|fm-send.sh\|fm-captain-hold.sh\|fm-on.sh.fm-captain-hold.sh\|fm-on.sh.fm-topic.sh\)	' "$TB_LOG" |
    grep -q '^cmd=' && fail "the board ran a stand-in outside the allow-list"
  t stop >/dev/null
  FM_TOPIC_BOARD_TEST=0 t open >/dev/null
  tb_op "$MAIN" test-write '{"kind":"message","topic":"billing","text":"x"}' >/dev/null 2>&1 &&
    fail "test-write must not exist outside test mode"
  t stop >/dev/null
  pass "the audit log is private, complete, and the test ops exist only in test mode"
}

setup_fleet
fm_test_run test_message_to_firstmate test_direct_message test_retries_run_out test_answers test_tagging \
  test_same_home_writes_do_not_overlap test_restart_resumes_or_settles test_answer_notice_survives_a_restart \
  test_dispatchable_notice test_decisions_made_on_the_page_reach_firstmate test_audit_log
