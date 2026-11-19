#!/usr/bin/env bash
# What the board sends out: the exact commands it runs, how each result is
# judged, retries, resend and ignore, recovery after a restart, and the notice
# that a topic became dispatchable. fm-inbox.sh, fm-send.sh, fm-captain-hold.sh
# and fm-on.sh are stand-ins that log their input and follow a per-test script.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"
# shellcheck source=myshape/test/signal-lib.sh
. "$ROOT/myshape/test/signal-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot tb-s4)
trap 'tb_stop_boards; fm_test_cleanup' EXIT
sig_init

export MYSHAPE_TEST=1 MYSHAPE_READ_MS=60000
export MYSHAPE_RETRY_MS=200,200,200,200,200 MYSHAPE_NOTIFY_MS=1500
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
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$CODE_ROOT" "$CODE_ROOT/bin/myshape.sh" "$@"
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

hold_backlog() {  # <home> <task> [close|release]: the outcome the hold records, none when omitted
  {
    printf '## In flight\n\n## Queued\n'
    printf -- '- [ ] %s - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)\n' "$2"
    printf '  Captain hold set: 2026-07-24T00:00:00Z\n'
    [ -z "${3:-}" ] || printf '  Captain hold on answer: %s\n' "$3"
    printf '\n## Done\n'
  } > "$1/data/backlog.md"
}

setup_fleet() {
  t open >/dev/null || fail "the board did not start"
  t create "Billing" --goal "rework billing" --id billing >/dev/null
  t create "Login" --goal "new login" --id login >/dev/null
  t create "Parked" --goal "later" --id parked --queue later >/dev/null
  t create "Parked two" --goal "later too" --id parked2 --queue later >/dev/null
  hold_backlog "$MAIN" call-main release
  hold_backlog "$LOCAL_SM" call-sm close
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
  assert_equals "call-far=release call-main=release call-sm=close" \
    "$(view '[.holds[] | select(.task | startswith("call-")) | "\(.task)=\(.on_answer)"] | sort | join(" ")')" \
    "the page must get each hold's outcome: recorded release, recorded close, and release for none"
  id=$(write answer home main task call-main answer "合併" label "合併" mode "done")
  settle "$id" delivered
  assert_contains "$(last_call fm-captain-hold.sh)" "argv=answers|--source|myshape|	home=$MAIN	stdin=call-main	合併	合併	release" \
    "a main-home answer must release as the hold recorded, whatever mode the request names"
  assert_contains "$(last_call fm-inbox.sh)" "argv=note|--request-id|tb-$id-note|-|" "the notice must derive its request id from the write"
  assert_contains "$(last_call fm-inbox.sh)" "已在看板回答 main/call-main：合併" "the notice must say what was answered"
  assert_equals $((notes + 1)) "$(calls fm-inbox.sh)" "an answer must notify firstmate exactly once"
  grep -q '"kind":"hold.answered"' "$MAIN/data/myshape/events.jsonl" || fail "a delivered answer must leave a system record"

  notes=$(calls fm-inbox.sh)
  play fm-captain-hold.sh '1\tskipped: call-main (already closed)'
  id=$(write answer home main task call-main answer "先不要" label "先不要")
  settle "$id" handled_elsewhere
  play fm-captain-hold.sh '1\trefused: call-main (away posture)'
  id=$(write answer home main task call-main answer "先不要" label "先不要")
  settle "$id" failed
  assert_equals "$notes" "$(calls fm-inbox.sh)" "an answer that did not land must not notify firstmate"

  id=$(write answer home sm1 task call-sm answer "好" label "文字作答")
  settle "$id" delivered
  assert_contains "$(last_call fm-captain-hold.sh)" "home=$LOCAL_SM	stdin=call-sm	好	文字作答	done" \
    "a local secondmate's hold must be answered inside that home, closed as it recorded"
  play fm-on.sh.fm-captain-hold.sh '255' '0\tclosed: call-far'
  id=$(write answer home far1 task call-far answer "好" label "文字作答")
  settle "$id" delivered
  assert_contains "$(last_call fm-on.sh.fm-captain-hold.sh)" "argv=far1|answers|--source|myshape|	" \
    "a remote hold must be answered through fm-on.sh --stdin"
  assert_contains "$(last_call fm-on.sh.fm-captain-hold.sh)" "stdin=call-far	好	文字作答	release" \
    "a remote hold that records no outcome must be released"
  assert_equals 2 "$(calls fm-on.sh.fm-captain-hold.sh)" "a transport failure must be retried by replaying the answer"

  refused answer home main task call-main answer "a	b" label x || fail "an answer with a tab must be refused"
  refused answer home main task no-such-hold answer "x" label x || fail "an answer to no hold must be refused"
  pass "an answer is recorded on the hold first, then firstmate is told once"
}

test_tagging() {
  local id
  mkdir -p "$MAIN/projects/loose"
  id=$(write tag home main task loose-task topic login)
  settle "$id" delivered
  assert_equals login "$(cut -d' ' -f1 "$MAIN/data/loose-task/topic")" "a main-home tag must be written by fm-board.sh tag"
  id=$(write tag home sm1 task sm-loose topic login)
  settle "$id" delivered
  assert_equals login "$(cut -d' ' -f1 "$LOCAL_SM/data/sm-loose/topic")" "a local secondmate tag must land in that home"
  grep -q '"kind":"agent.tagged"' "$MAIN/data/myshape/events.jsonl" || fail "a delivered tag must leave a system record"
  refused tag home main task loose-task topic nope || fail "tagging with an unknown topic must be refused"

  # Transport fails, but the tag did land: the retry reads the home and stops.
  play fm-on.sh.fm-board.sh '255'
  mkdir -p "$REMOTE_SM/data/far-a"
  id=$(write tag home far1 task far-a topic billing)
  printf 'billing 2026-07-02T00:00:00Z\n' > "$REMOTE_SM/data/far-a/topic"
  settle "$id" delivered
  assert_equals 1 "$(grep -c '|tag|far-a|' "$TB_LOG")" "a tag already in place must not be written again"

  # Transport fails and someone else tags the task with another topic meanwhile.
  play fm-on.sh.fm-board.sh '255'
  id=$(write tag home far1 task far-b topic billing)
  mkdir -p "$REMOTE_SM/data/far-b"
  printf 'login 2026-07-02T00:00:00Z\n' > "$REMOTE_SM/data/far-b/topic"
  settle "$id" handled_elsewhere
  assert_equals login "$(tail -n 1 "$REMOTE_SM/data/far-b/topic" | cut -d' ' -f1)" "another topic's tag must not be overwritten"

  # Transport fails and nothing changed: the retry writes the tag.
  play fm-on.sh.fm-board.sh '255'
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

# child_board: stop MAIN's board and start it again as this script's own
# background child, with retries an hour apart, so a test can crash it.
child_board() {
  local i=0
  t stop >/dev/null
  MYSHAPE_RETRY_MS=60000 node "$CODE_ROOT/myshape/dist/board-server.js" --home "$MAIN" --root "$CODE_ROOT" \
    --commit "$(git -C "$CODE_ROOT" rev-parse HEAD)" --state "$MAIN/state" --data "$MAIN/data" \
    --port "$(cat "$MAIN/config/myshape-port")" >> "$MAIN/state/myshape/service.log" 2>&1 &
  CHILD=$!
  while [ "$(tb_board_pid "$MAIN")" != "$CHILD" ] || [ ! -S "$MAIN/state/myshape/board.sock" ]; do
    [ "$i" -lt 100 ] || fail "the board started as this script's child did not come up"
    sleep 0.1
    i=$((i + 1))
  done
}

# crash_child: end that board at once, as a crash would. A signal dry run sends
# nothing and stops it through its socket instead.
crash_child() {
  kill_own_child "$CHILD"
  ! signal_dry_run || tb_socket_stop "$MAIN/state/myshape/board.sock"
  wait "$CHILD" 2>/dev/null || true
}

test_restart_resumes_or_settles() {
  local note send old pid before
  play fm-inbox.sh '3'
  play fm-send.sh 'sleep3'
  child_board
  view >/dev/null
  note=$(write message topic billing text "重啟後接著送")
  send=$(write direct home main task ship-a text "送到一半")
  settle "$note" retrying
  crash_child
  # The direct message's stand-in ends by itself within three seconds.
  sleep 3
  t open >/dev/null
  settle "$note" delivered
  settle "$send" unknown
  tb_op "$MAIN" test-resend "{\"write_id\":\"$send\"}" >/dev/null 2>&1 && fail "resending an unknown outcome must need confirmation"
  tb_op "$MAIN" test-resend "{\"write_id\":\"$send\",\"confirmed\":true}" >/dev/null || fail "a confirmed resend must be accepted"
  settle "$send" delivered

  play fm-inbox.sh '3'
  child_board
  view >/dev/null
  old=$(write message topic billing text "放太久")
  settle "$old" retrying
  crash_child
  sleep 1.2
  MYSHAPE_RESUME_MS=1000 t open >/dev/null
  before=$(calls fm-inbox.sh)
  settle "$old" undelivered
  assert_equals "$before" "$(calls fm-inbox.sh)" "an interrupted write older than the resume window must not be sent"
  t restart >/dev/null
  pass "after a restart, safe writes continue, stale ones stop, and uncertain ones are flagged"
}

test_answer_notice_survives_a_restart() {
  local id answers
  view >/dev/null
  answers=$(calls fm-captain-hold.sh)
  play fm-inbox.sh '3'
  child_board
  view >/dev/null
  id=$(write answer home main task call-main answer "合併" label "合併")
  settle "$id" retrying
  crash_child
  t open >/dev/null
  settle "$id" delivered
  assert_equals $((answers + 2)) "$(calls fm-captain-hold.sh)" \
    "the identical answer line must be replayed once after a restart, which the hold tool answers closed again"
  assert_equals 1 "$(grep "^cmd=fm-captain-hold.sh" "$TB_LOG" | tail -n 2 | cut -f2- | sort -u | wc -l | tr -d ' ')" \
    "the replayed answer must be the identical line"
  assert_equals 1 "$(grep "^cmd=fm-inbox.sh" "$TB_LOG" | grep "tb-$id-note" | cut -f2 | sort -u | wc -l | tr -d ' ')" \
    "the notice must be replayed under the same request id"
  pass "a restart between the answer and its notice replays the same answer, then finishes the notice"
}

# page <op> <json>: a topic operation sent the way the board page sends it.
page() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $(cat "$MAIN/state/myshape/token")" \
    -H "Origin: http://127.0.0.1:$(cat "$MAIN/state/myshape/port")" \
    -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:$(cat "$MAIN/state/myshape/port")/api/topics/$1"
}

page_body() {  # <op> <json>: the same request, printing the answer
  curl -s -X POST \
    -H "Authorization: Bearer $(cat "$MAIN/state/myshape/token")" \
    -H "Origin: http://127.0.0.1:$(cat "$MAIN/state/myshape/port")" \
    -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:$(cat "$MAIN/state/myshape/port")/api/topics/$1"
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
  t create "By hand" --goal "g" --id byhand >/dev/null
  t create "Fresh idea" --goal "g" --id fresh >/dev/null
  assert_equals 404 "$(page confirm '{"id":"fresh","queue":"high"}')" "the page must have nothing left to confirm"
  assert_equals 200 "$(page rename '{"id":"fresh","value":"Fresh name"}')" "renaming on the page failed"
  t close-propose fresh --reason "all done" >/dev/null
  sleep 1
  assert_equals "$before" "$(calls fm-inbox.sh)" \
    "firstmate's own creates and close proposal, and a rename on the page, send nothing"
  assert_equals 200 "$(page keep '{"id":"fresh"}')" "keeping the topic open failed"
  wait_calls fm-inbox.sh $((before + 1))
  assert_contains "$(last_call fm-inbox.sh)" "stdin=使用者在看板上：議題「Fresh name」先不關（id：fresh）" \
    "turning down a close proposal must reach firstmate"
  code=$(page_body merge '{"from":"byhand","into":"fresh"}' | jq -r '.confirm')
  assert_equals $((before + 1)) "$(calls fm-inbox.sh)" "asking to merge, before confirming it, sends nothing"
  got=$(page merge "{\"from\":\"byhand\",\"into\":\"fresh\",\"confirm\":\"$code\"}")
  assert_equals 200 "$got" "merging on the page failed"
  wait_calls fm-inbox.sh $((before + 2))
  assert_contains "$(last_call fm-inbox.sh)" "議題「By hand」已併入「Fresh name」（id：fresh）" "a merge made on the page must reach firstmate"
  assert_equals page "$(jq -r '[.history[] | select(.kind == "merged" and .from == "byhand")][0].by' "$MAIN/data/topics.json")" \
    "a merge made on the page must be recorded as made there"
  assert_equals 200 "$(page archive '{"id":"fresh"}')" "archiving on the page failed"
  wait_calls fm-inbox.sh $((before + 3))
  assert_contains "$(last_call fm-inbox.sh)" "議題「Fresh name」已封存（id：fresh）" "archiving on the page must reach firstmate"
  assert_contains "$(t find fresh)" "封存（在頁面上）" "find must say the archive was done on the page"
  pass "keep, merge, and archive done on the page are sent to firstmate; its own commands are not"
}

# api <path> <json>: a request sent the way the board page sends it; prints the HTTP status.
api() {
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $(cat "$MAIN/state/myshape/token")" \
    -H "Origin: http://127.0.0.1:$(cat "$MAIN/state/myshape/port")" \
    -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:$(cat "$MAIN/state/myshape/port")/api/$1"
}

# shellcheck disable=SC2016  # the commands are literal text, never expanded here
TODO_TEXT=$(printf '動手：重啟 x（卡住）\nsudo x --now "a b" && echo $HOME `date`\n\tps | grep x')

# todo_backlog <task>...: the main home's backlog with call-main and one hands-on hold per task.
todo_backlog() {
  local task reason
  reason="fm-hold-v1:$(printf '%s' "$TODO_TEXT" | base64 | tr -d '\n')"
  {
    printf '## In flight\n\n## Queued\n'
    printf -- '- [ ] call-main - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)\n'
    printf '  Captain hold set: 2026-07-24T00:00:00Z\n'
    for task in "$@"; do
      printf -- '- [ ] %s - Restart x (repo: sample) (kind: captain) (hold: %s) (hold-kind: captain)\n' "$task" "$reason"
      printf '  Captain hold set: 2026-07-24T00:00:00Z\n'
    done
    printf -- '- [ ] work-1 - Ordinary work (repo: sample) (kind: ship)\n'
    printf '\n## Done\n'
  } > "$MAIN/data/backlog.md"
}

todo_of() {  # <task>: the hands-on part of that hold, as the page gets it
  view ".holds[] | select(.task == \"$1\") | .todo | tojson"
}

test_hands_on_items() {
  local before out rc
  before=$(calls fm-inbox.sh)
  todo_backlog todo-a todo-b
  assert_equals "$(jq -cn --arg command "${TODO_TEXT#*$'\n'}" \
    '{what: "重啟 x（卡住）", guidance: "", commands: [$command], state: "open", reason: null}')" "$(todo_of todo-a)" \
    "a hold from before the labels must reach the page with the rest as one command, exactly as written"
  assert_equals "null" "$(todo_of call-main)" "an ordinary captain hold is not a hands-on item"
  assert_equals "[]" "$(view '.holds[] | select(.task == "todo-a") | .options | tojson')" \
    "a hands-on item has fixed buttons, whatever its text ends with"

  assert_equals 200 "$(api todos/claim '{"task":"todo-a"}')" "saying it is done on the page failed"
  wait_calls fm-inbox.sh $((before + 1))
  assert_contains "$(last_call fm-inbox.sh)" "stdin=使用者在看板上：「Restart x」做完了（todo-a）。驗證後跑 bin/myshape.sh todo done todo-a；沒成功就跑 bin/myshape.sh todo failed todo-a --reason <一行>" \
    "the claim must tell firstmate what to check and the two commands"
  assert_contains "$(todo_of todo-a)" '"state":"claimed"' "the item must show as waiting for firstmate"
  assert_equals 200 "$(api todos/claim '{"task":"todo-a"}')" "repeating the claim failed"
  assert_equals 409 "$(api todos/claim '{"task":"call-main"}')" "an ordinary decision cannot be claimed done"
  assert_equals 409 "$(api todos/claim '{"task":"work-1"}')" "ordinary work cannot be claimed done"
  assert_equals 409 "$(api todos/claim '{"task":"nope"}')" "a task with no hold cannot be claimed done"
  assert_equals 409 "$(api todos/claim '{}')" "a claim needs a task"

  out=$(t todo failed todo-a --reason "服務沒起來") || fail "todo failed was refused: $out"
  assert_equals "ok todo-a 已標成驗證沒過，回到要使用者動手" "$out" "todo failed printed the wrong line"
  assert_contains "$(todo_of todo-a)" '"state":"rejected","reason":"服務沒起來"' "the page must show why the check failed"
  out=$(t todo failed todo-a --reason "服務沒起來")
  assert_contains "$out" "本來就" "repeating the same verdict must say nothing changed"
  t todo obsolete todo-b --reason "改用別的做法" >/dev/null || fail "todo obsolete was refused"
  assert_equals 409 "$(api todos/claim '{"task":"todo-b"}')" "an item firstmate no longer needs cannot be claimed done"
  assert_contains "$(todo_of todo-b)" '"state":"obsolete","reason":"改用別的做法"' "the page must show the item is no longer needed"
  sleep 1
  assert_equals $((before + 1)) "$(calls fm-inbox.sh)" "a repeated claim, a refused claim, and firstmate's own verdicts send nothing"

  rc=0
  out=$(t todo failed call-main --reason x 2>&1) || rc=$?
  assert_equals 1 "$rc" "a verdict on an ordinary decision must be refused"
  assert_contains "$out" "call-main 不是主 home 裡還開著的「要你動手」項目" "the refusal must name the task"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo failed todo-a)" "todo failed without a reason"
  expect_code 1 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo obsolete todo-a --reason "$(printf 'a\nb')")" "a reason of two lines"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo nonsense todo-a)" "an unknown todo subcommand"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo)" "todo without a subcommand"

  # The home is read afresh for a verdict, and marks of holds that are gone are dropped.
  todo_backlog todo-a todo-c
  t todo obsolete todo-c --reason "剛建立就不用了" >/dev/null || fail "a verdict must see an item created a moment ago"
  assert_equals '["todo-a","todo-c"]' "$(jq -c '.todos | keys' "$MAIN/data/topics.json")" \
    "the mark of an item whose hold is gone must be dropped"

  # A repeated claim that also drops a stale mark changes the file, and must still not tell firstmate twice.
  before=$(calls fm-inbox.sh)
  todo_backlog todo-a todo-c
  view >/dev/null
  assert_equals 200 "$(api todos/claim '{"task":"todo-a"}')" "claiming again after a failed check failed"
  wait_calls fm-inbox.sh $((before + 1))
  todo_backlog todo-a
  view >/dev/null
  assert_equals 200 "$(api todos/claim '{"task":"todo-a"}')" "the repeated claim failed"
  assert_equals '["todo-a"]' "$(jq -c '.todos | keys' "$MAIN/data/topics.json")" "the repeated claim must drop the stale mark"
  sleep 1
  assert_equals $((before + 1)) "$(calls fm-inbox.sh)" "a repeated claim must not tell firstmate again"

  # Rewriting an item starts it over.
  t todo add todo-a "Restart x" --topic billing --do "重啟 x" --cmd "sudo x --again" >/dev/null ||
    fail "rewriting a claimed item failed"
  assert_equals '{}' "$(jq -c '.todos' "$MAIN/data/topics.json")" "rewriting an item must clear what was said about the old text"
  hold_backlog "$MAIN" call-main
  pass "hands-on items: the page claims, firstmate is told once, and its verdicts show on the page"
}

# old_todo_backlog: the main home's backlog with the two shapes of hands-on
# hold written before the labels: an action and one line of guidance, and an
# action alone.
old_todo_backlog() {
  local note only
  note="fm-hold-v1:$(printf '動手：開 NAS 的兩步驟驗證\n只在你人在電腦前時做。' | base64 | tr -d '\n')"
  only="fm-hold-v1:$(printf '動手：查路由器的轉址' | base64 | tr -d '\n')"
  {
    printf '## In flight\n\n## Queued\n'
    printf -- '- [ ] old-note - Turn on 2FA (repo: sample) (kind: captain) (hold: %s) (hold-kind: captain)\n' "$note"
    printf '  Captain hold set: 2026-07-24T00:00:00Z\n'
    printf -- '- [ ] old-only - Check the router (repo: sample) (kind: captain) (hold: %s) (hold-kind: captain)\n' "$only"
    printf '  Captain hold set: 2026-07-24T00:00:00Z\n'
    printf '\n## Done\n'
  } > "$MAIN/data/backlog.md"
}

test_hands_on_old_records() {
  old_todo_backlog
  assert_equals '{"what":"開 NAS 的兩步驟驗證","guidance":"","commands":["只在你人在電腦前時做。"],"state":"open","reason":null}' \
    "$(todo_of old-note)" "an old item with a following line must show it as it always did, one block with one button"
  assert_equals '{"what":"查路由器的轉址","guidance":"","commands":[],"state":"open","reason":null}' \
    "$(todo_of old-only)" "an old item with only an action must show no command"
  t todo failed old-note --reason "還是沒開" >/dev/null || fail "a verdict on an old item was refused"
  t todo obsolete old-only --reason "不用查了" >/dev/null || fail "marking an old item no longer needed was refused"
  assert_contains "$(todo_of old-note)" '"commands":["只在你人在電腦前時做。"],"state":"rejected","reason":"還是沒開"' \
    "an old item must keep its mark"
  assert_contains "$(todo_of old-only)" '"state":"obsolete","reason":"不用查了"' "an old item must keep its mark"
  hold_backlog "$MAIN" call-main
  pass "hands-on items stored before the labels read as before and keep their marks"
}

test_todo_add_moves_a_running_board_to_new_code() {
  local pid
  todo_backlog todo-a
  view >/dev/null
  pid=$(tb_board_pid "$MAIN")
  git -C "$CODE_ROOT" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "new code"
  t todo add todo-fresh "Log in" --topic billing --do "登入" >/dev/null || fail "todo add failed"
  assert_not_equals "$pid" "$(tb_board_pid "$MAIN")" \
    "todo add must move a board still running older code onto this code, even for an item with no mark"
  t status | grep -q "$(git -C "$CODE_ROOT" rev-parse HEAD)" || fail "the board must now run the new commit"
  hold_backlog "$MAIN" call-main
  pass "todo add brings a running board onto the code that reads the labels"
}

# todo_add_refused <what> <expected text> <flag...>: todo add todo-x with those
# flags and --topic billing must be a usage error that says <expected text>.
todo_add_refused() {
  local what=$1 expected=$2 rc=0 out
  shift 2
  out=$(t todo add todo-x "T" --topic billing "$@" 2>&1 </dev/null) || rc=$?
  assert_equals 2 "$rc" "todo add with $what must be a usage error"
  assert_contains "$out" "$expected" "the refusal of $what must say what is wrong"
}

test_hands_on_commands() {
  local holds out rc id
  holds=$(calls fm-captain-hold.sh)
  todo_backlog todo-a
  out=$(t todo add todo-new "登入 App Store" --topic billing --do "登入 App Store（更新要用）" \
    --cmd 'open -a "App Store"') || fail "todo add failed: $out"
  assert_equals "ok todo-new 已放上看板的「要你動手」（議題 billing）" "$out" "todo add printed the wrong line"
  assert_equals $((holds + 1)) "$(calls fm-captain-hold.sh)" "todo add must hold the task once"
  grep -q "^cmd=fm-captain-hold.sh	argv=hold|todo-new|--title|登入 App Store|--reason|動手：登入 App Store（更新要用）$" "$TB_LOG" ||
    fail "todo add must hold the task with the marker and the action"
  grep -q '^指令：open -a "App Store"|--on-answer|close|' "$TB_LOG" ||
    fail "todo add must label the command, keep it exactly, and record that answering closes the item"
  assert_equals billing "$(cut -d' ' -f1 "$MAIN/data/todo-new/topic")" "todo add must tag the task with the topic"
  # todo add reads no stdin, so a caller's stdin that stays open must not reach the hold tool.
  SECONDS=0
  t todo add todo-new "登入 App Store" --topic billing --do "登入 App Store（更新要用）" < <(sleep 15) >/dev/null ||
    fail "todo add with an open stdin failed"
  [ "$SECONDS" -lt 10 ] || fail "todo add must not hand its stdin to the hold tool (took ${SECONDS}s)"

  holds=$(calls fm-captain-hold.sh)
  rc=0
  out=$(t todo add todo-x "T" --topic nope --do x 2>&1) || rc=$?
  assert_equals 1 "$rc" "an unknown topic must be refused"
  rc=0
  out=$(t todo add call-main "A call" --topic billing --do x 2>&1) || rc=$?
  assert_equals 1 "$rc" "an open decision must not be turned into a hands-on item"
  assert_contains "$out" "call-main 已經是等使用者決定的項目" "the refusal must say why"
  rc=0
  out=$(t todo add work-1 "Ordinary work" --topic billing --do x 2>&1) || rc=$?
  assert_equals 1 "$rc" "ordinary work must not be turned into a hands-on item"
  assert_contains "$out" "work-1 已經是一件工作" "the refusal must say why"
  todo_add_refused "the old stdin form" "不再從 stdin 讀內容" --do x -
  printf 'x\nsudo y\n' > "$TMP_ROOT/old-stdin"
  rc=0
  out=$(t todo add todo-x "T" --topic billing - < "$TMP_ROOT/old-stdin" 2>&1) || rc=$?
  assert_equals 2 "$rc" "the old stdin form alone must be a usage error"
  assert_contains "$out" "--do <要做什麼> [--note <說明>] [--cmd <指令>]" "the refusal must show the new form"
  todo_add_refused "no action" "--do <要做什麼>"
  todo_add_refused "only a command" "--do <要做什麼>" --cmd "sudo y"
  todo_add_refused "an empty action" "--do 後面要有內容" --do " "
  todo_add_refused "an action of two lines" "--do 只寫一行" --do "$(printf 'x\nsudo y')"
  todo_add_refused "two actions" "--do 只能有一個" --do x --do y
  todo_add_refused "two notes" "--note 只能有一個" --do x --note a --note b
  todo_add_refused "an empty note" "--note 後面要有內容" --do x --note ""
  todo_add_refused "an empty command" "--cmd 後面要有內容" --do x --cmd "$(printf '\n\n')"
  todo_add_refused "a flag without its value" "--cmd 後面要有值" --do x --cmd
  todo_add_refused "an unknown flag" "不認得 --command" --do x --command y
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo add todo-x "T" --do x)" "todo add without a topic"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo add "bad id" "T" --topic billing --do x)" "a malformed task id"
  expect_code 2 "$(tb_code "$MAIN" "$CODE_ROOT/bin/myshape.sh" todo add todo-x "T" extra --topic billing --do x)" "an extra word"
  assert_equals "$holds" "$(calls fm-captain-hold.sh)" "a refused todo add must not touch the backlog"

  out=$(t todo 'done' todo-a) || fail "todo done failed: $out"
  assert_equals "ok todo-a 已關（做完了，first mate 已驗證）" "$out" "todo done printed the wrong line"
  assert_contains "$(last_call fm-captain-hold.sh)" "argv=answers|--source|myshape|" "todo done must go through the answer intake"
  assert_contains "$(last_call fm-captain-hold.sh)" "$(printf 'stdin=todo-a\t做完了\tfirst mate 已驗證\tdone')" \
    "todo done must close the item with the captain's own word"
  holds=$(calls fm-captain-hold.sh)
  rc=0
  out=$(t todo 'done' call-main 2>&1) || rc=$?
  assert_equals 1 "$rc" "todo done must refuse an ordinary decision"
  assert_equals "$holds" "$(calls fm-captain-hold.sh)" "a refused todo done must not answer anything"
  for id in gone work-1; do
    rc=0
    out=$(t todo 'done' "$id" 2>&1) || rc=$?
    assert_equals 1 "$rc" "todo done must refuse $id, which is not an open hands-on item"
    assert_contains "$out" "$id 不是開著的「要你動手」項目" "the refusal must name the task"
  done
  assert_equals "$holds" "$(calls fm-captain-hold.sh)" "only an open hands-on item may reach the answer intake"
  play fm-captain-hold.sh '1\tskipped: todo-a (cannot record)'
  rc=0
  out=$(t todo 'done' todo-a 2>&1) || rc=$?
  assert_equals 1 "$rc" "todo done must fail when the intake skips the task"
  assert_contains "$out" "todo-a 沒有關：skipped: todo-a" "the failure must carry the intake's reason"
  hold_backlog "$MAIN" call-main
  pass "todo add holds and tags after checking; todo done closes only hands-on items"
}

# shellcheck disable=SC2016  # the commands are literal text, never expanded here
COMMAND_LINES=('sudo x --now "a b" && echo $HOME `date`' $'\tps | grep x')

# real_todo_shapes <home>: todo add each shape of item through the real hold
# tool, and check what the board shows for it.
real_todo_shapes() {
  local home=$1 heredoc
  heredoc=$(printf "sudo tee /etc/x.conf <<'EOF'\n\tkey = 1\n\n指令：not a new command\nEOF")
  tb_run "$home" "$TOPIC" todo add real-cmds "Install x" --topic t --do "裝新的設定" --note "$(printf '先關掉 VPN。\n  第二行')" \
    --cmd "$heredoc" --cmd "$(printf 'sudo systemctl restart x \\\n  --now')" --cmd "說明：只是指令" >/dev/null ||
    fail "todo add with guidance and several commands failed against the real hold tool"
  tb_run "$home" "$TOPIC" todo add real-note "Turn on 2FA" --topic t --do "開 NAS 的兩步驟驗證" --note "只在你人在電腦前時做。" >/dev/null ||
    fail "todo add with guidance only failed against the real hold tool"
  tb_run "$home" "$TOPIC" todo add real-only "Check the router" --topic t --do "查路由器的轉址" >/dev/null ||
    fail "todo add with an action only failed against the real hold tool"
  assert_equals "$(jq -cn --arg heredoc "$heredoc" '{what: "裝新的設定", guidance: "先關掉 VPN。\n  第二行",
      commands: [$heredoc, "sudo systemctl restart x \\\n  --now", "說明：只是指令"], state: "open", reason: null}')" \
    "$(tb_op "$home" dump '{"refresh":true}' | jq -c '.holds[] | select(.task == "real-cmds") | .todo')" \
    "the board must show the guidance apart and each command exactly, one by one"
  assert_equals '{"what":"開 NAS 的兩步驟驗證","guidance":"只在你人在電腦前時做。","commands":[],"state":"open","reason":null}' \
    "$(tb_op "$home" dump '{"refresh":true}' | jq -c '.holds[] | select(.task == "real-note") | .todo')" \
    "guidance must not be offered as a command"
  assert_equals '{"what":"查路由器的轉址","guidance":"","commands":[],"state":"open","reason":null}' \
    "$(tb_op "$home" dump '{"refresh":true}' | jq -c '.holds[] | select(.task == "real-only") | .todo')" \
    "an item with nothing to run must show no command"
}

test_hands_on_item_with_the_real_hold_tool() {
  local home out HOLD_TOOL="$ROOT/bin/fm-captain-hold.sh"
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return 0; }
  home=$(tb_make_service_home real-todo)
  tb_board_has_run "$home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s' '{"v":1,"next_seq":1,"queues":{"high":["t"],"normal":[],"later":[]},"topics":{"t":{"name":"T","goal":"g","status":"confirmed","created_at":""}},"merged":{}}' \
    > "$home/data/topics.json"
  real_todo_shapes "$home"
  out=$(tb_run "$home" "$TOPIC" todo add real-1 "Restart x" --topic t --do "重啟 x（卡住）" --cmd "${TODO_TEXT#*$'\n'}") ||
    fail "todo add failed against the real hold tool: $out"
  assert_equals "$(printf '動手：重啟 x（卡住）\n指令：%s\n續：%s' "${COMMAND_LINES[0]}" "${COMMAND_LINES[1]}")" \
    "$(tb_run "$home" "$ROOT/bin/fm-topic-board-read.sh" 0 - | jq -r '.holds[] | select(.id == "real-1") | .question')" \
    "the labelled text must survive the real hold tool and the reader unchanged"
  tb_run "$home" "$TOPIC" todo add real-1 "Restart x" --topic t --do "second wording" >/dev/null ||
    fail "repeating todo add with new text failed"
  assert_equals "動手：second wording" "$(tb_run "$home" "$ROOT/bin/fm-topic-board-read.sh" 0 - | jq -r '.holds[] | select(.id == "real-1") | .question')" \
    "repeating todo add must update the text"
  for id in real-cmds real-note real-only; do
    tb_run "$home" "$TOPIC" todo 'done' "$id" >/dev/null || fail "todo done $id failed against the real hold tool"
  done
  assert_equals close "$(tb_run "$home" "$ROOT/bin/fm-topic-board-read.sh" 0 - | jq -r '.holds[0].on_answer')" \
    "todo add must record, through the real hold tool, that answering the item closes it"
  tb_run "$home" "$TOPIC" todo 'done' real-1 >/dev/null || fail "todo done failed against the real hold tool"
  assert_equals 0 "$(tb_run "$home" "$ROOT/bin/fm-topic-board-read.sh" 0 - | jq '.holds | length')" "todo done must close the hold"
  tb_run "$home" "$HOLD_TOOL" hold real-merge --title "Merge x" --reason "可以合併嗎？" --on-answer release >/dev/null ||
    fail "the real hold tool refused --on-answer"
  tb_run "$home" "$HOLD_TOOL" hold real-merge --reason "現在可以合併嗎？" >/dev/null || fail "rewriting the reason failed"
  tb_run "$home" "$HOLD_TOOL" hold real-old --title "Old call" --reason "選哪個？" >/dev/null || fail "a hold without an outcome failed"
  assert_equals "real-merge=release real-old=null" \
    "$(tb_run "$home" "$ROOT/bin/fm-topic-board-read.sh" 0 - | jq -r '[.holds[] | "\(.id)=\(.on_answer)"] | sort | join(" ")')" \
    "the reader must report a recorded release that survived a rewritten reason, and null for no record"
  printf 'real-merge\t合併\t合併\trelease\n' | tb_run "$home" "$HOLD_TOOL" answers --source myshape >/dev/null ||
    fail "the board's release line was not accepted by the real hold tool"
  assert_equals "queued false" \
    "$(tb_run "$home" "$ROOT/bin/fm-topic-board-read.sh" 0 - | jq -r '.queued[] | select(.id == "real-merge") | "queued \(.captain)"')" \
    "a released item must go back to the queue, no longer held for the captain"
  expect_code 1 "$(tb_code "$home" "$TOPIC" todo 'done' real-1)" "todo done on an item that is already closed"
  expect_code 1 "$(tb_code "$home" "$TOPIC" todo 'done' never-existed)" "todo done on a task that never existed"
  pass "todo add and todo done work against the real hold tool"
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
  assert_equals $((before + 2)) "$(calls fm-inbox.sh)" "each topic that becomes dispatchable must get its own notice"
  assert_contains "$(grep '^cmd=fm-inbox.sh' "$TB_LOG" | tail -n 2)" "stdin=議題「Parked」離開「待辦」，排在「一般」最後" \
    "the notice must say where the topic now stands"
  assert_contains "$(grep '^cmd=fm-inbox.sh' "$TB_LOG" | tail -n 2)" "stdin=議題「Parked two」離開「待辦」，排在「高」最後" \
    "the notice must say where the topic now stands"
  assert_not_contains "$(grep '^cmd=fm-inbox.sh' "$TB_LOG" | tail -n 2)" "order" "the notice must not tell firstmate what to run"
  t archive parked >/dev/null
  t reopen parked >/dev/null
  sleep 2.5
  assert_equals $((before + 3)) "$(calls fm-inbox.sh)" "reopening an archived topic must send the notice"
  assert_contains "$(last_call fm-inbox.sh)" "stdin=議題「Parked」重開，排在「一般」最後" "the reopening notice must say so"
  pass "firstmate is told once per topic when topics leave later or are reopened and then stay put"
}

test_audit_log() {
  local audit="$MAIN/state/myshape/audit.jsonl" id
  assert_equals "-rw-------" "$(tb_mode "$audit")" "the audit log must be 0600"
  id=$(write message topic billing text "稽核")
  settle "$id" delivered
  got=$(grep "\"write_id\":\"$id\"" "$audit" | jq -r '.state' | tr '\n' ' ' | sed 's/ $//')
  assert_equals "sending delivered" "$got" \
    "every state change must be exactly one audit line"
  grep "\"write_id\":\"$id\"" "$audit" | head -n 1 | jq -e '.sending.text == "稽核" and .sending.action.kind == "message"' >/dev/null ||
    fail "the first audit line must carry the full text and the action"
  grep -v '^cmd=\(fm-inbox.sh\|fm-send.sh\|fm-captain-hold.sh\|fm-on.sh.fm-captain-hold.sh\|fm-on.sh.fm-board.sh\)	' "$TB_LOG" |
    grep -q '^cmd=' && fail "the board ran a stand-in outside the allow-list"
  t stop >/dev/null
  MYSHAPE_TEST=0 t open >/dev/null
  tb_op "$MAIN" test-write '{"kind":"message","topic":"billing","text":"x"}' >/dev/null 2>&1 &&
    fail "test-write must not exist outside test mode"
  t stop >/dev/null
  pass "the audit log is private, complete, and the test ops exist only in test mode"
}

setup_fleet
fm_test_run test_message_to_firstmate test_direct_message test_retries_run_out test_answers test_tagging \
  test_same_home_writes_do_not_overlap test_restart_resumes_or_settles test_answer_notice_survives_a_restart \
  test_dispatchable_notice test_decisions_made_on_the_page_reach_firstmate test_hands_on_items \
  test_hands_on_commands test_hands_on_old_records test_todo_add_moves_a_running_board_to_new_code \
  test_hands_on_item_with_the_real_hold_tool test_audit_log
