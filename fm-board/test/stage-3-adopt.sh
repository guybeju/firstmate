#!/usr/bin/env bash
# AT4.3: the main home's hands-on holds from before the board kept hands-on
# items are adopted onto the board (fm-board.sh adopt, run by feed main on
# every read of the main home and by the session-start hook), shown once, and
# closed on the board close their hold with the line they always had. Runs a
# real board service from a private code root whose fm-inbox.sh and
# fm-captain-hold.sh are stand-ins (myshape/test/helpers.sh) and whose
# myshape.sh is the real one behind a front that logs each call.
# shellcheck disable=SC2016 # jq filters are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"
# shellcheck source=myshape/test/signal-lib.sh
. "$ROOT/myshape/test/signal-lib.sh"

for tool in jq node curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
TMP_ROOT=$(fm_test_tmproot fm-board-s3a)
case "$TMP_ROOT" in /?*) ;; *) echo "not ok - no scratch root" >&2; exit 1 ;; esac
trap 'tb_stop_boards; sig_leftovers; fm_test_cleanup' EXIT
sig_init

unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_TASK_INBOX
export MYSHAPE_TEST=1 MYSHAPE_READ_MS=600000 MYSHAPE_RETRY_MS=200,200,200
export FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z
export TB_LOG="$TMP_ROOT/calls.log" TB_PLAY="$TMP_ROOT/play" TB_REMOTES="$TMP_ROOT/remotes"
mkdir -p "$TB_PLAY" "$TB_REMOTES"
: > "$TB_LOG"
TOPIC_LOG=$TMP_ROOT/myshape.log
: > "$TOPIC_LOG"

FAKE=$TMP_ROOT/root
tb_make_fake_root "$FAKE"
rm "$FAKE/bin/myshape.sh"
cat > "$FAKE/bin/myshape.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TOPIC_LOG"
FM_ROOT_OVERRIDE=\${FM_ROOT_OVERRIDE:-$FAKE} exec "$ROOT/bin/myshape.sh" "\$@"
SH
chmod +x "$FAKE/bin/myshape.sh"
git -C "$FAKE" add -A >/dev/null
git -C "$FAKE" -c user.name=t -c user.email=t@example.invalid commit -qm "myshape.sh front" >/dev/null

MAIN=$(tb_make_service_home main)
tb_write_topics "$MAIN"

t() {
  case "${1:-}" in open | stop | restart) sig_product_target "$MAIN" "$1" ;; esac
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/myshape.sh" "$@"
}

b() {
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-board.sh" "$@"
}

read_main() {  # <reader arguments...>
  FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-topic-board-read.sh" "$@"
}

view() {  # [jq filter]: the board's state after a read of every home
  tb_op "$MAIN" dump '{"refresh":true}' | jq -c "${1:-.}"
}

item() {  # <id>: the board's stored item, or null
  jq -c --arg id "$1" '.items[$id]' "$MAIN/data/myshape/todos.json"
}

wait_for() {  # <description> <command...>: retry for up to 15 seconds
  local what=$1 tries=0
  shift
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "timed out waiting for $what"
    sleep 0.15
  done
}

hold_line() {  # <id> <title> <reason>: one captain hold of the backlog, its reason encoded
  printf -- '- [ ] %s - %s (repo: sample) (kind: captain) (hold: fm-hold-v1:%s) (hold-kind: captain)\n' \
    "$1" "$2" "$(printf '%s' "$3" | base64 | tr -d '\n')"
  printf '  Captain hold set: 2026-07-24T09:30:00Z\n'
}

LABELLED=$(printf '動手：開 NAS 的兩步驟驗證\n說明：只在你人在電腦前時做。\n指令：sudo nas-2fa --on\n續：  --now\n指令：echo done')
OLD=$(printf '動手：重啟 x\nsudo x --now "a b"\n\tps | grep x')

# backlog <hold id>...: the main home's backlog with those hands-on holds, an
# ordinary decision and an ordinary queued task.
backlog() {
  local id
  {
    printf '## In flight\n\n## Queued\n'
    printf -- '- [ ] call-main - A call (repo: sample) (kind: captain) (hold: 要合併嗎？ 選項：合併 | 先不要) (hold-kind: captain)\n'
    for id in "$@"; do
      case "$id" in
        nas-2fa) hold_line nas-2fa "Turn on 2FA" "$LABELLED" ;;
        old-restart) hold_line old-restart "Restart x" "$OLD" ;;
        *) hold_line "$id" "Item $id" "動手：做 $id" ;;
      esac
    done
    printf -- '- [ ] work-1 - Ordinary work (repo: sample) (kind: ship)\n'
    printf '\n## Done\n'
  } > "$MAIN/data/backlog.md"
}

# Before the board runs B3 code: two holds, the labelled one tagged, the old one
# untagged and claimed through topics.json's marks.
backlog nas-2fa old-restart
mkdir -p "$MAIN/data/nas-2fa"
printf 'old-billing 2026-07-24T00:00:00Z\n' > "$MAIN/data/nas-2fa/topic"
jq '.todos = {"old-restart": {state: "claimed", at: "2026-07-24T10:00:00Z"}, "gone-hold": {state: "rejected", at: "t", reason: "r"}}' \
  "$MAIN/data/topics.json" > "$MAIN/data/topics.json.new"
mv "$MAIN/data/topics.json.new" "$MAIN/data/topics.json"

test_a_read_of_the_main_home_adopts_the_old_items() {
  local events
  t open >/dev/null || fail "the board did not start"
  assert_equals '{"old-restart":{"state":"claimed","at":"2026-07-24T10:00:00Z"},"gone-hold":{"state":"rejected","at":"t","reason":"r"}}' \
    "$(jq -c '.marks' "$MAIN/data/myshape/todos.json")" "the first start must keep topics.json's marks as waiting marks"
  view >/dev/null
  assert_equals null "$(item nas-2fa)" "the first read, before the board knows this side's name, must adopt nothing"
  view >/dev/null
  assert_equals '{"title":"Turn on 2FA","topic":"billing","action":"開 NAS 的兩步驟驗證","guidance":"只在你人在電腦前時做。","commands":["sudo nas-2fa --on\n  --now","echo done"],"state":"open","reason":null,"by":"firstmate","ref":"hold","captain_closes":true,"adopted":true,"created_at":"2026-07-24T09:30:00Z"}' \
    "$(item nas-2fa | jq -c 'del(.at)')" "a labelled hold must become an item with its action, guidance and each command, under its tag's topic"
  assert_equals "$(jq -cn --arg cmd "$(printf 'sudo x --now "a b"\n\tps | grep x')" \
    '{title: "Restart x", topic: null, action: "重啟 x", guidance: "", commands: [$cmd], state: "claimed", ref: "hold"}')" \
    "$(item old-restart | jq -c '{title, topic, action, guidance, commands, state, ref}')" \
    "an untagged hold from before the labels must keep its mark, have no topic and keep its rest as one command"
  assert_equals '{}' "$(jq -c '.marks' "$MAIN/data/myshape/todos.json")" "the pass must take up and clear every waiting mark"
  assert_equals '["call-main"]' "$(view '[.holds[].task]')" "the page must show the old holds only as items"
  assert_equals '["nas-2fa","old-restart"]' "$(view '[.todos[].task]')" "each old item must show once"
  assert_equals '["call-main"]' "$(read_main 0 - | jq -c '[.holds[].id]')" "the reader must leave hands-on holds out of holds[]"
  assert_equals '["call-main","work-1"]' "$(read_main 0 - | jq -c '[.queued[].id]')" "the reader must leave hands-on holds out of queued[]"
  events=$(jq -c -s '[.[] | select(.kind == "todo.adopted") | {item, by, label, task, topic}]' "$MAIN/data/myshape/events.jsonl")
  assert_equals '[{"item":"nas-2fa","by":"aggregator","label":"first mate","task":null,"topic":"billing"},{"item":"old-restart","by":"aggregator","label":"first mate","task":null,"topic":null}]' \
    "$events" "each adoption must be recorded with who made it"
  assert_contains "$(view '[.updates[].text]')" "要你動手「Turn on 2FA」從 backlog 搬上看板（原本 " "the adoption must show in the topic's updates"
  pass "a read of the main home adopts each old hands-on hold once, with its mark, and hides the hold"
}

test_a_second_pass_calls_the_board_only_when_needed() {
  local before out
  before=$(cat "$MAIN/data/myshape/todos.json")
  : > "$TOPIC_LOG"
  out=$(b adopt) || fail "adopt failed: $out"
  assert_equals "ok adopt 放上 0 個舊項目，還開著的舊 hold 2 個" "$out" "a second pass must find nothing to adopt"
  view >/dev/null
  assert_equals "" "$(cat "$TOPIC_LOG")" "a pass with nothing to do must not call the board"
  assert_equals "$before" "$(cat "$MAIN/data/myshape/todos.json")" "a second pass must change nothing"
  pass "a second pass changes nothing and calls the board only when something is left"
}

test_closing_an_item_closes_its_hold() {
  local holds
  holds=$(grep -c 'cmd=fm-captain-hold.sh' "$TB_LOG" || true)
  t todo 'done' old-restart >/dev/null || fail "todo done failed"
  wait_for "the hold to be closed" grep -qF "$(printf 'stdin=old-restart\t做完了\tfirst mate 已驗證\tdone')" "$TB_LOG"
  # An adoption pass before the hold is really closed must not put the item back.
  view >/dev/null
  assert_equals null "$(item old-restart)" "an item closed on the board must stay off it while its hold is still open"
  backlog nas-2fa
  t todo obsolete nas-2fa --reason "改用別的方法" >/dev/null || fail "todo obsolete failed"
  assert_equals '"obsolete"' "$(item nas-2fa | jq -c '.state')" "an adopted item no longer needed must wait for the captain"
  sleep 1
  assert_equals "$((holds + 1))" "$(grep -c 'cmd=fm-captain-hold.sh' "$TB_LOG")" "waiting for the captain must not touch the hold"
  local base code
  base="http://127.0.0.1:$(cat "$MAIN/state/myshape/port")"
  code=$(curl -s -H "Authorization: Bearer $(cat "$MAIN/state/myshape/token")" -H "Origin: $base" \
    -H 'Content-Type: application/json' -d '{"task":"nas-2fa"}' "$base/api/todos/takedown" | jq -r '.confirm')
  curl -s -o /dev/null -H "Authorization: Bearer $(cat "$MAIN/state/myshape/token")" -H "Origin: $base" \
    -H 'Content-Type: application/json' -d "{\"task\":\"nas-2fa\",\"confirm\":\"$code\"}" "$base/api/todos/takedown"
  wait_for "the captain's words to close the hold" grep -qF "$(printf 'stdin=nas-2fa\t撤下\t撤下\tdone')" "$TB_LOG"
  wait_for "the note" grep -qF 'stdin=使用者在看板上：「Turn on 2FA」撤下（nas-2fa）' "$TB_LOG"
  # Until the holds close here, a pass must not ask the board about the two
  # items again: a board command would also start a board that was stopped.
  backlog nas-2fa old-restart
  : > "$TOPIC_LOG"
  b adopt >/dev/null || fail "adopt failed while the closed items' holds are open"
  assert_equals "" "$(cat "$TOPIC_LOG")" "a pass must not call the board for items closed on it whose holds are still open"
  assert_equals "todo.taken_down/captain/taken_down/billing" \
    "$(jq -r -s '[.[] | select(.item == "nas-2fa")] | last | "\(.kind)/\(.by)/\(.outcome)/\(.topic)"' "$MAIN/data/myshape/events.jsonl")" \
    "the captain's takedown must be recorded as the captain's"
  backlog
  view >/dev/null
  assert_equals '{}' "$(jq -c '.closed' "$MAIN/data/myshape/todos.json")" "once the holds are closed the board forgets them"
  pass "closing an adopted item closes its hold with todo done's line or the captain's words"
}

test_a_hold_closed_elsewhere_takes_its_item_off() {
  local calls
  backlog old-chat
  view >/dev/null
  [ "$(item old-chat)" != null ] || fail "the new old hold must be adopted"
  calls=$(grep -c '' "$TB_LOG")
  mv "$MAIN/data/backlog.md" "$TMP_ROOT/backlog.away"
  view >/dev/null
  [ "$(item old-chat)" != null ] || fail "a pass that cannot read the backlog must take nothing off"
  mv "$TMP_ROOT/backlog.away" "$MAIN/data/backlog.md"
  backlog
  view >/dev/null
  assert_equals null "$(item old-chat)" "an adopted item whose hold was closed elsewhere must leave the board"
  assert_equals "todo.taken_down/aggregator/elsewhere/要你動手「Item old-chat」已關：hold 已在別處關掉（first mate 用指令）" \
    "$(jq -r -s '[.[] | select(.item == "old-chat")] | last | "\(.kind)/\(.by)/\(.outcome)/\(.text)"' "$MAIN/data/myshape/events.jsonl")" \
    "it must leave a record naming that it was closed elsewhere"
  sleep 1
  assert_equals "$calls" "$(grep -c '' "$TB_LOG")" "a hold closed elsewhere needs no notice"
  pass "an adopted item whose hold is closed elsewhere leaves the board with a record, and only when the backlog was read"
}

test_the_session_start_hook_adopts_with_no_page_open() {
  local out
  backlog old-hook
  out=$(FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-topic-session-start.sh")
  assert_equals "看板服務：在跑" "$out" "the hook must still print its one line"
  [ "$(item old-hook)" != null ] || fail "the hook must adopt an old hold without a read of the page"
  pass "the session-start hook adopts old holds when no page is open"
}

test_a_secondmate_home_keeps_its_holds_as_decisions() {
  local mate rc=0
  mate=$(tb_make_secondmate_home sm sm1)
  printf '## In flight\n\n## Queued\n- [ ] mate-todo - X (repo: sample) (kind: captain) (hold: 動手：x) (hold-kind: captain)\n\n## Done\n' \
    > "$mate/data/backlog.md"
  assert_equals '["mate-todo"]' "$(FM_HOME="$mate" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-topic-board-read.sh" 0 - | jq -c '[.holds[].id]')" \
    "a secondmate's hold that starts with 動手： stays an ordinary decision"
  FM_HOME="$mate" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-board.sh" adopt >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "adopt must refuse in a secondmate home"
  pass "a secondmate home keeps its 動手： holds as decisions and does not adopt"
}

new_code() {  # <message>: a new commit of the private code root, as an update lands
  git -C "$FAKE" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "$1"
}

# A board still running older code when an update lands: the adoption's own
# todo add replaces it, from inside that board's read of the main home, or
# from the session-start hook.
test_an_adoption_replaces_a_board_on_older_code() {
  local pid
  t open >/dev/null
  pid=$(tb_board_pid "$MAIN")
  new_code "an update during a read"
  backlog old-upgrade
  sig_product_target "$MAIN" "a read whose adoption replaces the board"
  tb_op "$MAIN" dump '{"refresh":true}' >/dev/null 2>&1 || true
  wait_for "the item adopted by the new board" is_on_board old-upgrade
  wait_for "one board" one_board
  assert_not_equals "$pid" "$(tb_board_pid "$MAIN")" "the adoption must have replaced the board on older code"
  assert_contains "$(t status)" "程式版本：$(git -C "$FAKE" rev-parse HEAD)" "the board must now run the new commit"

  pid=$(tb_board_pid "$MAIN")
  new_code "an update before a session start"
  backlog old-upgrade old-hook2
  sig_product_target "$MAIN" "the hook's adoption on older code"
  assert_equals "看板服務：在跑" "$(FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-topic-session-start.sh")" \
    "the hook must print its one line"
  is_on_board old-hook2 || fail "the hook's adoption must put the item on the board"
  wait_for "one board" one_board
  assert_not_equals "$pid" "$(tb_board_pid "$MAIN")" "the hook's adoption must have replaced the board on older code"
  pass "an adoption replaces a board still on older code, from its own read or from the hook, and leaves one board"
}

is_on_board() {  # <id>
  [ "$(item "$1")" != null ]
}

one_board() {
  [ "$(tb_board_count "$MAIN")" = 1 ]
}

test_nothing_is_left() {
  t stop >/dev/null
  tb_stop_boards
  pass "no board is left running"
}

fm_test_run test_a_read_of_the_main_home_adopts_the_old_items test_a_second_pass_calls_the_board_only_when_needed \
  test_closing_an_item_closes_its_hold test_a_hold_closed_elsewhere_takes_its_item_off \
  test_the_session_start_hook_adopts_with_no_page_open test_a_secondmate_home_keeps_its_holds_as_decisions \
  test_an_adoption_replaces_a_board_on_older_code test_nothing_is_left
