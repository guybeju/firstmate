#!/usr/bin/env bash
# The stand-in bin/fm-topic.sh, the board's command under its name from before
# the rename: it runs nothing, writes nothing, exits 2, and names the command
# to use now plus what the user still has to run in this home.
set -u

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib.sh"
# shellcheck source=myshape/test/helpers.sh
. "$ROOT/myshape/test/helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-board-stage-8-old-name)
OLD="$ROOT/bin/fm-topic.sh"

# old_call <home> <arguments...>: the stand-in's stderr, after checking its exit
# code and that it printed nothing on stdout.
old_call() {
  local home=$1 rc=0 out err
  shift
  err=$TMP_ROOT/err.$$
  out=$(tb_run "$home" "$OLD" "$@" 2>"$err" </dev/null) || rc=$?
  assert_equals 2 "$rc" "fm-topic.sh $* must exit 2"
  assert_equals "" "$out" "fm-topic.sh $* must print nothing on stdout"
  cat "$err"
  rm -f "$err"
}

# A home moved to the new names whose rules file is current: the session that
# called the old name loaded its rules before the move.
moved_home() {
  local home
  home=$(tb_make_home "$1")
  tb_board_has_run "$home"
  tb_run "$home" "$BOARD" install-rules >/dev/null 2>&1 || fail "install-rules failed in $home"
  printf '%s\n' "$home"
}

test_names_the_command_that_has_each_call_now() {
  local home
  home=$(moved_home names)
  assert_equals "改名了：tag 改用 bin/fm-board.sh tag <task-id> <議題 id>" "$(old_call "$home" tag t1 billing | head -n 1)" "tag"
  assert_equals "改名了：--in-home 改用 bin/fm-board.sh --in-home <id> <tag|answers|setup> …" \
    "$(old_call "$home" --in-home sm1 setup | head -n 1)" "--in-home"
  assert_equals "改名了：setup 改用 bin/fm-board.sh setup" "$(old_call "$home" setup | head -n 1)" "setup"
  assert_equals "改名了：install-rules 改用 bin/fm-board.sh install-rules" "$(old_call "$home" install-rules | head -n 1)" "install-rules"
  assert_equals "改名了：order 改用 bin/fm-dispatch-plan.sh order" "$(old_call "$home" order | head -n 1)" "order"
  assert_equals "改名了：要一起搬 task 的 split 改用 bin/fm-board.sh split <議題 id> <新名稱> --goal <一行> <task…>" \
    "$(old_call "$home" split billing 新的 --goal 一行 t1 | head -n 1)" "split with tasks"
  assert_equals "改名了：改用 bin/myshape.sh <同樣的參數>" "$(old_call "$home" split billing 新的 --goal 一行 | head -n 1)" \
    "split without tasks"
  assert_equals "改名了：改用 bin/myshape.sh <同樣的參數>" "$(old_call "$home" todo "done" t1 | head -n 1)" "todo done"
  assert_equals "改名了：改用 bin/myshape.sh <同樣的參數>" "$(old_call "$home" list | head -n 1)" "list"
  assert_equals "改名了：改用 bin/myshape.sh <同樣的參數>" "$(old_call "$home" | head -n 1)" "no arguments"
  pass "each old call names the command that has it now"
}

test_says_what_the_user_has_to_run() {
  local home before
  home=$(tb_make_home unmoved)
  mkdir -p "$home/state/topic-board"
  assert_equals "這個 home 還沒搬：請使用者跑 bin/fm-board.sh migrate-myshape" "$(old_call "$home" list | tail -n 1)" \
    "an unmoved home must name the move"
  home=$(tb_make_home unmoved-port)
  printf '47999\n' > "$home/config/topic-board-port"
  assert_equals "這個 home 還沒搬：請使用者跑 bin/fm-board.sh migrate-myshape" "$(old_call "$home" list | tail -n 1)" \
    "an unmoved port file must name the move"
  home=$(tb_make_home old-rules)
  tb_board_has_run "$home"
  printf '%s\n' '<!-- topic-board:begin v9 -->' '- 規則' '<!-- topic-board:end -->' > "$home/data/captain.md"
  assert_equals "規則還是舊的：請使用者重跑 bin/fm-board.sh install-rules，再重開 session" "$(old_call "$home" list | tail -n 1)" \
    "a home whose rules file has the old marker must name install-rules"
  home=$(moved_home current)
  assert_equals "這個 session 載入的規則還是舊的：請使用者重開 session" "$(old_call "$home" list | tail -n 1)" \
    "a moved home with current rules must name the session restart"
  assert_equals 2 "$(old_call "$home" list | wc -l | tr -d ' ')" "the answer must be exactly two lines"
  before=$(cd "$home" && find . | LC_ALL=C sort)
  old_call "$home" create x --goal y >/dev/null
  old_call "$home" install-rules >/dev/null
  assert_equals "$before" "$(cd "$home" && find . | LC_ALL=C sort)" "the stand-in must write nothing"
  pass "a second line says what the user has to run in this home, and nothing is written"
}

fm_test_run test_names_the_command_that_has_each_call_now test_says_what_the_user_has_to_run
