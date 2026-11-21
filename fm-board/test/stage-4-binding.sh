#!/usr/bin/env bash
# AT4.6: Firstmate binds the board to its own two programs. A copy of this
# checkout made group-writable, the way a checkout under umask 002 is on this
# PC, is the code root; its bin/fm-board.sh is git-tracked and unchanged, so
# the board runs it without a confirmation even though its group may write
# it. fm-board.sh setup writes the binding; in a home set up before the board
# read one, the session-start hook writes it and replaces the running board,
# which then reads the home through fm-board.sh feed. Everything runs on a
# scratch home with its own port, in a clean environment.
# shellcheck disable=SC2016 # jq filters are literal text.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"
# shellcheck source=myshape/test/signal-lib.sh
. "$ROOT/myshape/test/signal-lib.sh"

for tool in jq node curl git tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
TMP_ROOT=$(fm_test_tmproot fm-board-s4b)
case "$TMP_ROOT" in /?*) ;; *) echo "not ok - no scratch root" >&2; exit 1 ;; esac
trap 'tb_stop_boards; sig_leftovers; fm_test_cleanup' EXIT
sig_init

BINDING='{"v":1,"name":"firstmate","feed":"bin/fm-board.sh","deliver":"bin/fm-board.sh"}'
CODE=$TMP_ROOT/checkout
mkdir -p "$CODE" "$TMP_ROOT/h" "$TMP_ROOT/tmp"
git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 tar -cf - --) | tar -xf - -C "$CODE"
chmod -R g+w "$CODE"
tb_commit_root "$CODE" "a group-writable checkout" >/dev/null
MAIN=$(tb_make_service_home main)
printf '## In flight\n\n## Queued\n\n## Done\n' > "$MAIN/data/backlog.md"
case "$(cat "$MAIN/config/myshape-port")" in 47819 | '') fail "the scratch home must have its own port" ;; esac
PATH_CLEAN=$(dirname "$(command -v node)"):$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/bin:/bin

# run <command> <arguments...>: one of the checkout's commands for the scratch
# home (RUN_HOME, else the main one), in a clean environment; the code root is
# the checkout's own location.
run() {
  local home=${RUN_HOME:-$MAIN}
  case "$1:${2:-}" in */myshape.sh:open | */myshape.sh:stop | */myshape.sh:restart) sig_product_target "$home" "$2" ;; esac
  env -i HOME="$TMP_ROOT/h" PATH="$PATH_CLEAN" LANG=C.UTF-8 TMPDIR="$TMP_ROOT/tmp" FM_HOME="$home" \
    MYSHAPE_TEST=1 MYSHAPE_READ_MS=600000 "$@"
}

aggregator() {  # <jq filter>: the running board's aggregator block
  run "$CODE/bin/myshape.sh" status >/dev/null || return 1
  curl -s -m 20 -H "Authorization: Bearer $(cat "$MAIN/state/myshape/token")" \
    "http://127.0.0.1:$(cat "$MAIN/config/myshape-port")/api/state" | jq -r ".aggregator | $1"
}

test_the_checkout_is_group_writable_and_clean() {
  assert_equals "-rwxrwxr-x" "$(tb_mode "$CODE/bin/fm-board.sh")" "the checkout's fm-board.sh must be group-writable"
  assert_equals "" "$(git -C "$CODE" status --porcelain)" "the checkout must equal its commit"
  pass "the code root is a group-writable checkout equal to its commit"
}

test_setup_writes_the_binding() {
  local home out
  home=$(tb_make_home setup-home)
  out=$(RUN_HOME="$home" run "$CODE/bin/fm-board.sh" setup)
  assert_equals "$BINDING" "$(cat "$home/config/myshape-aggregator.json")" "setup must write firstmate's binding"
  assert_contains "$out" "ok bind 看板的 aggregator 設定已寫：firstmate" "setup must say it wrote the binding"
  pass "fm-board.sh setup writes firstmate's binding"
}

test_the_hook_binds_and_replaces_a_running_board() {
  local old new out tries=0
  run "$CODE/bin/myshape.sh" open >/dev/null || fail "the board did not start"
  assert_absent "$MAIN/config/myshape-aggregator.json" "the home must start without a binding"
  assert_equals "false|沒有 config/myshape-aggregator.json" "$(aggregator '"\(.connected)|\(.unavailable)"')" \
    "a board started without the binding must reach nothing"
  old=$(tb_board_pid "$MAIN")
  sig_product_target "$MAIN" "the hook's open"
  out=$(run "$CODE/bin/fm-topic-session-start.sh")
  assert_equals "看板服務：已接上 firstmate，換上新的看板" "$out" "the hook must say it bound the board and replaced it"
  assert_equals "$BINDING" "$(cat "$MAIN/config/myshape-aggregator.json")" "the hook must write firstmate's binding"
  new=$(tb_board_pid "$MAIN")
  assert_not_equals "$old" "$new" "the hook must replace the board that started without the binding"
  assert_equals 1 "$(tb_board_count "$MAIN")" "exactly one board must serve the home"
  assert_equals "true|0" "$(aggregator '"\(.connected)|\(.confirm | length)"')" \
    "the group-writable, tracked bin/fm-board.sh must run with nothing to confirm"
  run "$CODE/bin/myshape.sh" find nothing-here >/dev/null
  until [ -f "$MAIN/data/myshape/aggregator.json" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "the board never read the home through fm-board.sh feed"
    sleep 0.15
  done
  assert_equals "first mate" "$(jq -r '.label' "$MAIN/data/myshape/aggregator.json")" \
    "the board must have read the home through firstmate's feed"
  pass "the hook writes the missing binding and replaces the running board, which runs the group-writable bin/fm-board.sh"
}

test_the_hook_leaves_a_bound_board_alone() {
  local pid
  pid=$(tb_board_pid "$MAIN")
  assert_equals "看板服務：在跑" "$(run "$CODE/bin/fm-topic-session-start.sh")" "a bound, running board must be reported as running"
  assert_equals "$pid" "$(tb_board_pid "$MAIN")" "the hook must leave a bound board alone"
  pass "with the binding in place the hook leaves the running board alone"
}

test_the_hook_starts_a_stopped_board_with_the_binding() {
  run "$CODE/bin/myshape.sh" stop >/dev/null
  rm "$MAIN/config/myshape-aggregator.json"
  assert_equals "看板服務：原本沒在跑，已啟動" "$(run "$CODE/bin/fm-topic-session-start.sh")" "a stopped board must be started"
  assert_equals "$BINDING" "$(cat "$MAIN/config/myshape-aggregator.json")" "the hook must write the missing binding first"
  assert_equals true "$(aggregator '.connected')" "the started board must be bound"
  run "$CODE/bin/myshape.sh" stop >/dev/null
  pass "the hook writes a missing binding before it starts a stopped board"
}

test_no_binding_in_a_home_without_a_board() {
  local home
  home=$(tb_make_service_home no-board)
  assert_equals "" "$(RUN_HOME="$home" run "$CODE/bin/fm-topic-session-start.sh")" "a home without a board must get no line"
  assert_absent "$home/config/myshape-aggregator.json" "a home that never ran the board must get no binding from the hook"
  pass "the hook binds only a home that uses the board"
}

test_nothing_is_left() {
  tb_stop_boards
  assert_equals 0 "$(tb_board_count "$MAIN")" "no board may be left running"
  pass "no board is left running"
}

fm_test_run test_the_checkout_is_group_writable_and_clean test_setup_writes_the_binding \
  test_the_hook_binds_and_replaces_a_running_board test_the_hook_leaves_a_bound_board_alone \
  test_the_hook_starts_a_stopped_board_with_the_binding test_no_binding_in_a_home_without_a_board \
  test_nothing_is_left
