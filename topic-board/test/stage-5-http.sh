#!/usr/bin/env bash
# The browser channel from the outside: the checks every request must pass, the
# two-step confirmation of actions that cannot be taken back, and the API
# routes, all exercised with curl against a running board.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=topic-board/test/helpers.sh
. "$ROOT/topic-board/test/helpers.sh"

for tool in jq node curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
TMP_ROOT=$(fm_test_tmproot tb-s5)
trap 'tb_stop_boards; fm_test_cleanup' EXIT

export FM_TOPIC_BOARD_TEST=1 FM_TOPIC_BOARD_LOCAL_MS=60000 FM_TOPIC_BOARD_REMOTE_MS=60000
export FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z
export TB_LOG="$TMP_ROOT/calls.log" TB_PLAY="$TMP_ROOT/play" TB_REMOTES="$TMP_ROOT/remotes"
mkdir -p "$TB_PLAY" "$TB_REMOTES"
: > "$TB_LOG"
CODE_ROOT="$TMP_ROOT/root"
tb_make_fake_root "$CODE_ROOT"
MAIN=$(tb_make_service_home main)

t() {
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$CODE_ROOT" "$CODE_ROOT/bin/fm-topic.sh" "$@"
}

t create "Billing" --goal "rework billing" --id billing >/dev/null
t create "Login" --goal "new login" --id login >/dev/null
t create "Idea" --goal "to merge" --id idea --queue later >/dev/null
cat > "$MAIN/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] call-1 - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)
  Captain hold set: 2026-07-24T00:00:00Z

## Done
EOF
mkdir -p "$MAIN/data/call-1"
printf 'billing 2026-07-01T00:00:00Z\n' > "$MAIN/data/call-1/topic"
URL=$(t open)
PORT=$(cat "$MAIN/config/topic-board-port")
TOKEN=${URL##*#t=}
BASE="http://127.0.0.1:$PORT"
ORIGIN="Origin: $BASE"
AUTH="Authorization: Bearer $TOKEN"
JSON="Content-Type: application/json"

# status <curl args...>: the HTTP status of one request.
status() {
  curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"
}

# api <route> <json body>: POST as the page would; prints the response body.
api() {
  curl -s -m 20 -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d "$2" "$BASE/api/$1"
}

state() {
  curl -s -m 20 -H "$AUTH" "$BASE/api/state" | jq -r "$1"
}

test_request_checks() {
  local big icon
  assert_equals 200 "$(status "$BASE/")" "the page itself needs no token"
  assert_equals 200 "$(status -H "Host: localhost:$PORT" "$BASE/")" "localhost with the right port is this board"
  assert_equals 403 "$(status -H 'Host: evil.example' "$BASE/")" "a foreign Host must be refused (DNS rebinding)"
  assert_equals 403 "$(status -H 'Host: 127.0.0.1:1' "$BASE/")" "the right address with the wrong port must be refused"
  assert_equals 401 "$(status "$BASE/api/state")" "reading the board needs the token"
  assert_equals 401 "$(status -H 'Authorization: Bearer wrong' "$BASE/api/state")" "a wrong token must be refused"
  assert_equals 401 "$(status "$BASE/api/state?token=$TOKEN")" "the token is accepted only in the header"
  assert_equals 200 "$(status -H "$AUTH" "$BASE/api/state")" "the right token reads the board"
  assert_equals 403 "$(status -H "$AUTH" -H "$JSON" -d '{}' "$BASE/api/refresh")" "a change without Origin must be refused"
  assert_equals 403 "$(status -H "$AUTH" -H "$JSON" -H 'Origin: null' -d '{}' "$BASE/api/refresh")" "Origin: null must be refused"
  assert_equals 403 "$(status -H "$AUTH" -H "$JSON" -H 'Origin: http://evil.example' -d '{}' "$BASE/api/refresh")" "a foreign Origin must be refused (CSRF)"
  assert_equals 403 "$(status -H "$AUTH" -H "$JSON" -H "Origin: http://127.0.0.1:1" -d '{}' "$BASE/api/refresh")" "our address on another port is a foreign Origin"
  assert_equals 415 "$(status -H "$AUTH" -H "$ORIGIN" -H 'Content-Type: text/plain' -d '{}' "$BASE/api/refresh")" "only application/json may change anything"
  assert_equals 415 "$(status -H "$AUTH" -H "$ORIGIN" -d 'a=b' "$BASE/api/refresh")" "a form post must be refused"
  assert_equals 400 "$(status -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d '{' "$BASE/api/refresh")" "malformed JSON must be refused"
  assert_equals 400 "$(status -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d '[1]' "$BASE/api/refresh")" "a JSON body that is not an object must be refused"
  big=$(head -c 70000 /dev/zero | tr '\0' 'x')
  assert_equals 413 "$(printf '{"text":"%s"}' "$big" | status -H "$AUTH" -H "$ORIGIN" -H "$JSON" --data-binary @- "$BASE/api/messages")" \
    "a body over 64 KiB must be refused"
  assert_equals 405 "$(status -X OPTIONS -H 'Origin: http://evil.example' -H 'Access-Control-Request-Method: POST' "$BASE/api/refresh")" \
    "a preflight must not be answered"
  assert_equals 405 "$(status -X DELETE -H "$AUTH" -H "$ORIGIN" "$BASE/api/state")" "other methods must be refused"
  assert_equals 400 "$(status -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Key: x' -H 'Sec-WebSocket-Version: 13' "$BASE/")" \
    "a WebSocket upgrade must be refused"
  assert_equals 404 "$(status "$BASE/assets/..%2f..%2fstate%2ftopic-board%2ftoken")" "an encoded path must not escape the assets"
  assert_equals 404 "$(status --path-as-is "$BASE/assets/../../state/topic-board/token")" "a dotted path must not escape the assets"
  assert_equals 404 "$(status "$BASE/assets/board-server.js")" "server code must not be served"
  icon=$(curl -s -m 5 "$BASE/" | sed -n 's/.*<link rel="icon"[^>]* href="\([^"]*\)".*/\1/p')
  assert_equals "/assets/icon.svg" "$icon" "the page must name its own icon, so the browser does not ask for /favicon.ico"
  assert_equals "200 image/svg+xml" "$(curl -s -m 5 -o /dev/null -w '%{http_code} %{content_type}' "$BASE$icon")" \
    "the icon the page names must be served"
  assert_equals 404 "$(status -H "$AUTH" "$BASE/api/nope")" "an unknown API route is 404"
  printf 'GET / HTTP/1.1\r\nHost: \xff\xfe\x00bad\r\n\r\n' | curl -s -m 5 "telnet://127.0.0.1:$PORT" >/dev/null 2>&1 || true
  printf 'NOT HTTP AT ALL\r\n\r\n' | curl -s -m 5 "telnet://127.0.0.1:$PORT" >/dev/null 2>&1 || true
  assert_equals 200 "$(status -H "$AUTH" "$BASE/api/state")" "the board must survive garbage on the wire"
  pass "every request passes the Host, token, Origin, content-type, and size checks"
}

test_response_headers_and_exposure() {
  local headers audit="$MAIN/state/topic-board/audit.jsonl"
  for path in / /assets/board.js /api/state /api/nope; do
    headers=$(curl -s -D - -o /dev/null -H "$AUTH" "$BASE$path")
    printf '%s' "$headers" | grep -qi "^content-security-policy: default-src 'self'; frame-ancestors 'none'" ||
      fail "$path must carry the content security policy"
    printf '%s' "$headers" | grep -qi '^x-frame-options: DENY' || fail "$path must forbid framing"
    printf '%s' "$headers" | grep -qi '^access-control-' && fail "$path must not send any CORS header"
  done
  assert_equals "127.0.0.1:$PORT" "$(tb_listeners "$PORT")" "the board must listen on 127.0.0.1 and nowhere else"
  curl -s "$BASE/" | grep -q "$TOKEN" && fail "the page must not embed the token"
  curl -s "$BASE/" | grep -q "Billing" && fail "the page must not embed any board data"
  grep -q '"rejected":"origin is not this board"' "$audit" || fail "a rejected request must be recorded"
  grep -q '"rejected":"missing or wrong token"' "$audit" || fail "a request with a bad token must be recorded"
  grep -q "$TOKEN" "$audit" && fail "the audit log must never contain the token"
  assert_equals "-rw-------" "$(tb_mode "$audit")" "the audit log must stay 0600"
  pass "responses carry the security headers and nothing leaks into the page or the log"
}

test_topic_routes() {
  local version
  api refresh '{}' >/dev/null
  assert_equals "billing login" "$(state '.queues.normal | join(" ")')" "the state must carry the queues"
  version=$(state '"\(.boot_id):\(.version)"')
  assert_equals false "$(curl -s -H "$AUTH" "$BASE/api/state?v=$version" | jq -r '.changed')" "an unchanged board answers changed: false"
  api topics/move '{"id":"login","queue":"high"}' >/dev/null
  assert_equals "login|billing" "$(state '"\(.queues.high | join(","))|\(.queues.normal | join(","))"')" "move must change the queue"
  assert_equals true "$(curl -s -H "$AUTH" "$BASE/api/state?v=$version" | jq -r '.changed')" "a change must show up for a poller"
  api topics/move '{"id":"billing","queue":"high","before":"login"}' >/dev/null
  assert_equals "billing login" "$(state '.queues.high | join(" ")')" "move with before must insert ahead of it"
  api topics/move '{"id":"billing","queue":"high"}' >/dev/null
  assert_equals "login billing" "$(state '.queues.high | join(" ")')" "a drop with no before lands at the end"
  api topics/rename '{"id":"billing","value":"Billing 2"}' >/dev/null
  api topics/goal '{"id":"billing","value":"a new goal"}' >/dev/null
  assert_equals "Billing 2|a new goal" "$(state '.topics.billing | "\(.name)|\(.goal)"')" "rename and goal must change the topic"
  t close-propose billing --reason "done" >/dev/null
  assert_equals "done" "$(state '.topics.billing.close_reason')" "a close proposal must reach the page"
  api topics/keep '{"id":"billing"}' >/dev/null
  assert_equals "null" "$(state '.topics.billing.close_reason')" "keep must clear the close proposal"
  api topics/archive '{"id":"login"}' >/dev/null
  assert_equals "archived" "$(state '.topics.login.status')" "archive must archive"
  api topics/reopen '{"id":"login"}' >/dev/null
  assert_equals "normal" "$(state '.topics.login.queue')" "reopen must queue the topic again"
  assert_equals "refused" "$(api topics/rename '{"id":"nope","value":"x"}' | jq -r '.error')" "a refused operation reports why"
  assert_equals 409 "$(status -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d '{"id":"nope","value":"x"}' "$BASE/api/topics/rename")" "a refused operation is 409"
  assert_equals 400 "$(status -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d '{}' "$BASE/api/topics/move")" "a malformed operation is 400"
  assert_equals 404 "$(status -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d '{"name":"x","goal":"y"}' "$BASE/api/topics/create")" \
    "creating topics is not offered to the browser"
  assert_equals 404 "$(status -H "$AUTH" -H "$ORIGIN" -H "$JSON" -d '{"id":"billing"}' "$BASE/api/topics/confirm")" \
    "the browser has nothing to confirm: every topic is confirmed when it is made"
  pass "the topic routes do what the same fm-topic.sh subcommands do"
}

test_merge_takes_two_steps() {
  local code
  code=$(api topics/merge '{"from":"idea","into":"billing"}' | jq -r '.confirm')
  [ "${#code}" -eq 32 ] || fail "the first merge request must return a confirmation code"
  assert_equals "confirmed" "$(state '.topics.idea.status')" "the first request must not merge"
  got=$(api topics/merge "{\"from\":\"idea\",\"into\":\"login\",\"confirm\":\"$code\"}" | jq -r '.error')
  assert_equals "confirm" "$got" \
    "a code must not work for another target"
  got=$(api topics/merge "{\"from\":\"idea\",\"into\":\"billing\",\"confirm\":\"$code\"}" | jq -r '.error')
  assert_equals "confirm" "$got" \
    "a code is void once it has been presented, even wrongly"
  code=$(api topics/merge '{"from":"idea","into":"billing"}' | jq -r '.confirm')
  got=$(api topics/merge "{\"from\":\"idea\",\"into\":\"billing\",\"confirm\":\"$code\"}" | jq -r '.ok')
  assert_equals true "$got" \
    "the second request with the code must merge"
  assert_equals "null" "$(state '.topics.idea')" "the merged topic must be gone"
  pass "merging topics needs a code bound to exactly that merge"
}

answer_step1() {
  api holds/answer '{"home":"main","task":"call-1","answer":"合併","label":"合併"}' | jq -r '.confirm'
}

test_answer_takes_two_steps() {
  local code before
  api refresh '{}' >/dev/null
  assert_equals "合併|先不要" "$(state '.holds[] | select(.task == "call-1") | .options | join("|")')" "the hold must be on the board"
  before=$(grep -c '^cmd=fm-captain-hold.sh' "$TB_LOG" || true)
  assert_equals "release false" "$(state '.holds[] | select(.task == "call-1") | "\(.on_answer) \(.on_answer_recorded)"')" \
    "a hold that records no outcome must be shown as released, and as not recorded"
  assert_equals "confirm" "$(api holds/answer '{"home":"main","task":"call-1","answer":"合併","label":"合併","confirm":"00000000000000000000000000000000"}' | jq -r '.error')" \
    "an invented code must not answer"
  code=$(answer_step1)
  got=$(api holds/answer "{\"home\":\"main\",\"task\":\"call-1\",\"answer\":\"先不要\",\"label\":\"x\",\"confirm\":\"$code\"}" | jq -r '.error')
  assert_equals "confirm" "$got" \
    "a code must not work for another answer"
  code=$(answer_step1)
  sed -i.bak 's/要合併嗎？/要現在合併嗎？/' "$MAIN/data/backlog.md"
  api refresh '{}' >/dev/null
  got=$(api holds/answer "{\"home\":\"main\",\"task\":\"call-1\",\"answer\":\"合併\",\"label\":\"合併\",\"confirm\":\"$code\"}" | jq -r '.error')
  assert_equals "confirm" "$got" \
    "a code must not work once the question changed"
  code=$(answer_step1)
  awk '{ print } /^  Captain hold set: / && held { print "  Captain hold on answer: close" } { held = /^- \[ \] call-1 / }' \
    "$MAIN/data/backlog.md" > "$MAIN/data/backlog.md.new" && mv "$MAIN/data/backlog.md.new" "$MAIN/data/backlog.md"
  api refresh '{}' >/dev/null
  assert_equals "close true" "$(state '.holds[] | select(.task == "call-1") | "\(.on_answer) \(.on_answer_recorded)"')" \
    "a recorded close must reach the page"
  got=$(api holds/answer "{\"home\":\"main\",\"task\":\"call-1\",\"answer\":\"合併\",\"label\":\"合併\",\"confirm\":\"$code\"}" | jq -r '.error')
  assert_equals "confirm" "$got" \
    "a code must not work once what answering does changed"
  code=$(answer_step1)
  t restart >/dev/null
  api refresh '{}' >/dev/null
  got=$(api holds/answer "{\"home\":\"main\",\"task\":\"call-1\",\"answer\":\"合併\",\"label\":\"合併\",\"confirm\":\"$code\"}" | jq -r '.error')
  assert_equals "confirm" "$got" \
    "a restart must void outstanding codes"
  assert_equals "$before" "$(grep -c '^cmd=fm-captain-hold.sh' "$TB_LOG" || true)" "nothing may reach the hold before a valid second step"

  code=$(answer_step1)
  got=$(api holds/answer "{\"home\":\"main\",\"task\":\"call-1\",\"answer\":\"合併\",\"label\":\"合併\",\"confirm\":\"$code\",\"mode\":\"release\"}" | jq -r '.ok')
  assert_equals true "$got" \
    "the second step with the code must answer"
  sleep 1
  grep '^cmd=fm-captain-hold.sh' "$TB_LOG" | tail -n 1 | grep -q 'stdin=call-1	合併	合併	done' ||
    fail "the answer must close as the hold recorded, whatever mode the request names"
  assert_equals "refused" "$(api holds/answer '{"home":"main","task":"nope","answer":"x","label":"x"}' | jq -r '.error')" \
    "answering a hold that is not there is refused"
  pass "answering a hold needs a code bound to the hold, its question, and the answer"
}

test_messages_and_writes() {
  local id
  id=$(api messages '{"topic":"billing","text":"先做這個"}' | jq -r '.write_id')
  sleep 1
  got=$(state ".writes[] | select(.id == \"$id\") | .state")
  also=$(grep "\"write_id\":\"$id\"" "$MAIN/state/topic-board/audit.jsonl" | head -n 1 | jq -r '.sending.channel')
  assert_equals "delivered|browser" "$got|$also" \
    "a message from the page is delivered and recorded as coming from the browser"
  assert_equals "refused" "$(api direct '{"home":"main","task":"ship-a","text":"/compact"}' | jq -r '.error')" \
    "a direct message that looks like a command is refused"
  printf '1\n' > "$TB_PLAY/fm-send.sh"
  id=$(api direct '{"home":"main","task":"ship-a","text":"看一下"}' | jq -r '.write_id')
  sleep 1
  got=$(state ".writes[] | select(.id == \"$id\") | .state")
  assert_equals "failed" "$got" "a failed direct message shows as failed"
  got=$(api writes/resend "{\"write_id\":\"$id\"}" | jq -r '.ok')
  assert_equals true "$got" "a failed write can be resent in one step"
  sleep 1
  got=$(state ".writes[] | select(.id == \"$id\") | .state")
  assert_equals "delivered" "$got" "the resend delivers it"
  printf '1\n' > "$TB_PLAY/fm-send.sh"
  id=$(api direct '{"home":"main","task":"ship-a","text":"不管了"}' | jq -r '.write_id')
  sleep 1
  got=$(api writes/ignore "{\"write_id\":\"$id\"}" | jq -r '.ok')
  assert_equals true "$got" "a failed write can be ignored"
  got=$(state ".writes[] | select(.id == \"$id\") | .state")
  assert_equals "ignored" "$got" "ignore marks the write"
  mkdir -p "$MAIN/data"
  id=$(api agents/tag '{"home":"main","task":"loose","topic":"login"}' | jq -r '.write_id')
  sleep 1
  assert_equals login "$(cut -d' ' -f1 "$MAIN/data/loose/topic")" "tagging an agent from the page writes the tag"
  pass "messages, direct messages, tags, resend, and ignore work through the API"
}

test_quiet_polling_is_not_a_change() {
  local version
  t stop >/dev/null
  FM_TOPIC_BOARD_LOCAL_MS=300 FM_TOPIC_BOARD_STALE_MS=4000 FM_TOPIC_BOARD_IDLE_MS=2000 t open >/dev/null
  AUTH="Authorization: Bearer $(cat "$MAIN/state/topic-board/token")"
  curl -s -H "$AUTH" "$BASE/api/state" >/dev/null
  sleep 2
  version=$(state '"\(.boot_id):\(.version)"')
  sleep 1.5
  assert_equals false "$(curl -s -H "$AUTH" "$BASE/api/state?v=$version" | jq -r '.changed')" \
    "polls that find nothing new must not make the page redraw"
  : > "$MAIN/config/fleet-ledger"
  sleep 1.5
  assert_equals true "$(curl -s -H "$AUTH" "$BASE/api/state?v=$version" | jq -r '.changed')" \
    "a poll that finds something new must reach the page"
  version=$(state '"\(.boot_id):\(.version)"')
  # Nobody asks for long enough that polling stops and the home goes stale.
  sleep 6.5
  assert_equals "true|true" "$(curl -s -H "$AUTH" "$BASE/api/state?v=$version" | jq -r '"\(.changed)|\(.homes[0].stale)"')" \
    "a home going stale must reach the page even though no read reported it"
  t stop >/dev/null
  t open >/dev/null
  pass "the page is told about changes, including staleness, and nothing else"
}

test_reset_token() {
  t reset-token >/dev/null
  assert_equals 401 "$(status -H "$AUTH" "$BASE/api/state")" "the old token must stop working after a reset"
  assert_equals 200 "$(status -H "Authorization: Bearer $(cat "$MAIN/state/topic-board/token")" "$BASE/api/state")" "the new token must work"
  pass "reset-token invalidates the old token at once"
}

fm_test_run test_request_checks test_response_headers_and_exposure test_topic_routes test_merge_takes_two_steps \
  test_answer_takes_two_steps test_messages_and_writes test_quiet_polling_is_not_a_change test_reset_token
t stop >/dev/null
